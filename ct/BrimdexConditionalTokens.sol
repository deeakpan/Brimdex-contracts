// SPDX-License-Identifier: LGPL-3.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CTHelpers} from "./CTHelpers.sol";
import {IDIAOracleV2} from "./IDIAOracleV2.sol";
import {BrimdexAssetRegistry} from "./BrimdexAssetRegistry.sol";

/// @title BrimdexConditionalTokens
/// @notice Gnosis Conditional Tokens fork: same split/merge/redeem; binary Brimdex markets use DIA Push Oracle via BrimdexAssetRegistry. assetKey is the condition identifier — no separate questionId.
/// @dev Outcome slot 0 = BREAK wins. Outcome slot 1 = BOUND wins. Oracle in condition id is `address(this)`. Use `registerMarket` then factory `openMarket` + `resolve`.
contract BrimdexConditionalTokens is ERC1155, ReentrancyGuard {
    /// @dev Emitted when a Brimdex binary condition is prepared (`oracle` in id is this contract).
    event ConditionPreparation(
        bytes32 indexed conditionId,
        bytes32 indexed questionId,
        uint256 outcomeSlotCount
    );

    event ConditionResolution(
        bytes32 indexed conditionId,
        address indexed oracle,
        bytes32 indexed questionId,
        uint256 outcomeSlotCount,
        uint256[] payoutNumerators
    );

    event PositionSplit(
        address indexed stakeholder,
        IERC20 collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 indexed conditionId,
        uint256[] partition,
        uint256 amount
    );

    event PositionsMerge(
        address indexed stakeholder,
        IERC20 collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 indexed conditionId,
        uint256[] partition,
        uint256 amount
    );

    event PayoutRedemption(
        address indexed redeemer,
        IERC20 indexed collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 conditionId,
        uint256[] indexSets,
        uint256 payout
    );

    /// @notice Binary market resolved via DIA Push Oracle.
    event BrimdexMarketResolved(
        bytes32 indexed conditionId,
        bytes32 indexed assetKey,
        string feedKey,
        uint128 oraclePrice,
        uint128 oracleTimestamp,
        uint256 normalizedPrice,
        bool boundWins,
        uint256[] payouts
    );

    /// @notice Binary market force-resolved by the LMSR owner (Gnosis Safe) after the oracle's
    ///         primary + grace windows both closed without a successful resolution. `priceProofHash`
    ///         is owner-supplied evidence (e.g. IPFS CID of a signed Pyth/Chainlink/CEX print).
    event BrimdexMarketEmergencyResolved(
        bytes32 indexed conditionId,
        bytes32 indexed assetKey,
        uint256 manualPrice,
        bool boundWins,
        uint256[] payouts,
        bytes32 priceProofHash
    );

    /// @notice Who may register a prepared binary market (typically your stack factory).
    address public authorizedPreparer;

    /// @notice DIA asset registry — maps assetKey → feedKey string + oracle address.
    BrimdexAssetRegistry public immutable assetRegistry;

    mapping(bytes32 => uint256[]) public payoutNumerators;
    mapping(bytes32 => uint256) public payoutDenominator;

    struct BrimdexMarketParams {
        uint256 lowerBound;
        uint256 upperBound;
        uint256 expiryTimestamp;
        bool resolved;
        uint256 resolvedPrice;
        bool boundWins;
        bytes32 assetKey;
        address vault;
        /// @notice Only this LMSR may call `resolve` for this condition (set once via `bindMarketMaker`).
        address marketMaker;
    }

    mapping(bytes32 => BrimdexMarketParams) public brimdexMarket;

    /// @notice Oracle must have updated within this many seconds of expiryTimestamp (primary window),
    ///         or within this many seconds of `block.timestamp` once the grace period opens
    ///         (block.timestamp >= expiry + ORACLE_WINDOW). One constant for both windows.
    uint256 public constant ORACLE_WINDOW = 360;
    /// @notice How long after expiry the owner-controlled `emergencyResolve` path opens. Long enough
    ///         that anyone with a working DIA feed can still settle through `resolve()` first, but
    ///         short enough that a stuck market doesn't lock LP capital for days.
    uint256 public constant EMERGENCY_DELAY = 12 hours;
    /// @notice Minimum spot price in 6-decimal USD ($0.001). Assets below this are rejected.
    uint256 public constant MIN_SPOT_6 = 1000;
    uint256 public constant TARGET_DECIMALS = 6;
    uint8  public constant DIA_DECIMALS = 8;

    error NotPreparer();
    error ConditionAlreadyPrepared();
    error ConditionNotPrepared();
    error AlreadyResolved();
    error NotYetExpired();
    error InvalidPrice();
    error InvalidBounds();
    error InvalidFeed();
    error TooManyOutcomeSlots();
    error UnknownAssetKey();
    error PriceTooOld();
    error NotMarketMaker();
    error MarketMakerAlreadyBound();
    error OracleStillLive();

    constructor(address preparer_, BrimdexAssetRegistry registry_, string memory uri_) ERC1155(uri_) {
        authorizedPreparer = preparer_;
        assetRegistry = registry_;
    }

    function setAuthorizedPreparer(address preparer_) external {
        require(msg.sender == authorizedPreparer, "only preparer");
        require(preparer_ != address(0), "zero");
        authorizedPreparer = preparer_;
    }

    /// @notice Returns a unique conditionId for a market. Pass the vault address that registered it.
    function getBrimdexConditionId(bytes32 assetKey, uint256 lowerBound, uint256 upperBound, uint256 expiryTimestamp, address vault) external view returns (bytes32) {
        bytes32 marketId = keccak256(abi.encodePacked(assetKey, lowerBound, upperBound, expiryTimestamp, vault));
        return CTHelpers.getConditionId(address(this), marketId, 2);
    }

    /// @notice Register a binary market. assetKey must be registered in BrimdexAssetRegistry.
    /// @dev conditionId is unique per (assetKey, lowerBound, upperBound, expiryTimestamp) — multiple concurrent markets on the same asset are supported.
    function registerMarket(
        bytes32 assetKey,
        uint256 lowerBound,
        uint256 upperBound,
        uint256 expiryTimestamp,
        address vault
    ) external returns (bytes32 conditionId) {
        if (msg.sender != authorizedPreparer) revert NotPreparer();
        if (assetKey == bytes32(0)) revert InvalidFeed();
        assetRegistry.getFeedKey(assetKey); // reverts if unknown
        if (lowerBound >= upperBound) revert InvalidBounds();
        if (expiryTimestamp <= block.timestamp) revert NotYetExpired();

        bytes32 marketId = keccak256(abi.encodePacked(assetKey, lowerBound, upperBound, expiryTimestamp, vault));
        conditionId = CTHelpers.getConditionId(address(this), marketId, 2);
        if (payoutNumerators[conditionId].length != 0) revert ConditionAlreadyPrepared();

        payoutNumerators[conditionId] = new uint256[](2);
        BrimdexMarketParams storage m = brimdexMarket[conditionId];
        m.lowerBound = lowerBound;
        m.upperBound = upperBound;
        m.expiryTimestamp = expiryTimestamp;
        m.resolved = false;
        m.resolvedPrice = 0;
        m.boundWins = false;
        m.assetKey = assetKey;
        m.vault = vault;

        emit ConditionPreparation(conditionId, marketId, 2);
    }

    /// @notice Links the deployed LMSR to this condition. Callable once by `authorizedPreparer` (the stack factory).
    /// @dev Must be called after `registerMarket` and before the LMSR may call `resolve`.
    function bindMarketMaker(bytes32 conditionId, address marketMaker_) external {
        if (msg.sender != authorizedPreparer) revert NotPreparer();
        if (payoutNumerators[conditionId].length != 2) revert ConditionNotPrepared();
        BrimdexMarketParams storage m = brimdexMarket[conditionId];
        if (m.marketMaker != address(0)) revert MarketMakerAlreadyBound();
        if (marketMaker_ == address(0)) revert InvalidFeed();
        m.marketMaker = marketMaker_;
    }

    /// @notice Band, expiry, asset key, and vault for this binary condition.
    function getBrimdexBinaryBand(bytes32 conditionId)
        external
        view
        returns (uint256 lowerBound, uint256 upperBound, uint256 expiryTimestamp, bytes32 assetKey, address vault)
    {
        BrimdexMarketParams storage m = brimdexMarket[conditionId];
        return (m.lowerBound, m.upperBound, m.expiryTimestamp, m.assetKey, m.vault);
    }

    /// @notice LMSR authorized to call `resolve` for this condition (zero until `bindMarketMaker`).
    function getBrimdexMarketMaker(bytes32 conditionId) external view returns (address) {
        return brimdexMarket[conditionId].marketMaker;
    }

    /// @notice Resolution after expiry using DIA Oracle V2 (`getValue`). Only the bound LMSR may call.
    /// @dev Oracle must have updated within ORACLE_WINDOW seconds of expiryTimestamp (primary),
    ///      or within ORACLE_WINDOW seconds of block.timestamp after the grace period (fallback).
    ///      Resolver incentive (if any) is paid by `LMSRMarketMaker.resolve`, not here.
    /// @param assetKey        Must match registerMarket.
    /// @param lowerBound      Must match registerMarket.
    /// @param upperBound      Must match registerMarket.
    /// @param expiryTimestamp Must match registerMarket.
    /// @param vault           The vault address that registered this market.
    function resolve(bytes32 assetKey, uint256 lowerBound, uint256 upperBound, uint256 expiryTimestamp, address vault) external nonReentrant {
        bytes32 marketId = keccak256(abi.encodePacked(assetKey, lowerBound, upperBound, expiryTimestamp, vault));
        bytes32 conditionId = CTHelpers.getConditionId(address(this), marketId, 2);
        BrimdexMarketParams storage m = brimdexMarket[conditionId];
        if (payoutNumerators[conditionId].length != 2) revert ConditionNotPrepared();
        if (m.resolved) revert AlreadyResolved();
        if (block.timestamp < m.expiryTimestamp) revert NotYetExpired();
        if (payoutDenominator[conditionId] != 0) revert AlreadyResolved();
        if (m.marketMaker == address(0)) revert NotMarketMaker();
        if (msg.sender != m.marketMaker) revert NotMarketMaker();

        string memory feedKey = assetRegistry.getFeedKey(assetKey);
        address oracle = assetRegistry.diaOracle();
        if (oracle == address(0)) revert InvalidFeed();

        (uint128 oraclePrice, uint128 oracleTs) = IDIAOracleV2(oracle).getValue(feedKey);
        if (oraclePrice == 0) revert InvalidPrice();
        if (oracleTs == 0) revert InvalidPrice();
        if (block.timestamp < uint256(oracleTs)) revert InvalidPrice();

        // Primary window: oracle updated within ORACLE_WINDOW seconds of expiry.
        // Grace window: if primary was missed, oracle must be fresh within ORACLE_WINDOW of now,
        //               but only callable after expiry + ORACLE_WINDOW (grace period opens).
        uint256 windowStart = m.expiryTimestamp >= ORACLE_WINDOW ? m.expiryTimestamp - ORACLE_WINDOW : 0;
        bool primaryOk = (uint256(oracleTs) >= windowStart &&
                          uint256(oracleTs) <= m.expiryTimestamp + ORACLE_WINDOW);
        bool graceOk   = (!primaryOk &&
                          block.timestamp >= m.expiryTimestamp + ORACLE_WINDOW &&
                          block.timestamp - uint256(oracleTs) <= ORACLE_WINDOW);
        if (!primaryOk && !graceOk) revert PriceTooOld();

        uint256 finalPrice = _normalizeToTargetDecimals(oraclePrice);
        if (finalPrice == 0) revert InvalidPrice();
        if (finalPrice < MIN_SPOT_6) revert InvalidPrice();

        _resolveApply(conditionId, assetKey, m, feedKey, oraclePrice, oracleTs, finalPrice);
    }

    /// @notice Owner-driven emergency resolution. Callable only by the bound LMSR (which itself
    ///         requires owner / Gnosis Safe) after BOTH oracle windows have closed and the DIA
    ///         feed is verifiably dead. Intentionally NOT routed through governance to avoid
    ///         whale self-resolution attacks: a single multisig is faster and accountable on-chain.
    /// @dev    Refuses to run while the normal `resolve()` path is still viable — `primaryAlive`
    ///         (oracleTs ∈ [expiry-WINDOW, expiry+WINDOW]) and `graceAlive` (oracleTs within the
    ///         last WINDOW) are both re-checked here so the owner cannot override a working oracle.
    /// @param  manualPrice6    Final settlement price in 6-decimal USD (must be >= MIN_SPOT_6).
    /// @param  priceProofHash  Owner-supplied evidence anchor (e.g. signed off-chain price). Pass
    ///                         `bytes32(0)` if none.
    function emergencyResolve(
        bytes32 assetKey,
        uint256 lowerBound,
        uint256 upperBound,
        uint256 expiryTimestamp,
        address vault,
        uint256 manualPrice6,
        bytes32 priceProofHash
    ) external nonReentrant {
        bytes32 marketId = keccak256(abi.encodePacked(assetKey, lowerBound, upperBound, expiryTimestamp, vault));
        bytes32 conditionId = CTHelpers.getConditionId(address(this), marketId, 2);
        BrimdexMarketParams storage m = brimdexMarket[conditionId];
        if (payoutNumerators[conditionId].length != 2) revert ConditionNotPrepared();
        if (m.resolved) revert AlreadyResolved();
        if (payoutDenominator[conditionId] != 0) revert AlreadyResolved();
        if (m.marketMaker == address(0)) revert NotMarketMaker();
        if (msg.sender != m.marketMaker) revert NotMarketMaker();
        // Owner may only step in once the oracle had its full primary + grace shot.
        if (block.timestamp < m.expiryTimestamp + EMERGENCY_DELAY) revert NotYetExpired();
        if (manualPrice6 < MIN_SPOT_6) revert InvalidPrice();

        // Verify both oracle paths are dead so we never override a working feed.
        address oracle = assetRegistry.diaOracle();
        if (oracle != address(0)) {
            string memory feedKey = assetRegistry.getFeedKey(assetKey);
            (, uint128 oracleTs) = IDIAOracleV2(oracle).getValue(feedKey);
            uint256 windowStart = m.expiryTimestamp >= ORACLE_WINDOW ? m.expiryTimestamp - ORACLE_WINDOW : 0;
            bool primaryAlive = oracleTs != 0 &&
                uint256(oracleTs) >= windowStart &&
                uint256(oracleTs) <= m.expiryTimestamp + ORACLE_WINDOW;
            bool graceAlive = oracleTs != 0 &&
                uint256(oracleTs) <= block.timestamp &&
                block.timestamp - uint256(oracleTs) <= ORACLE_WINDOW;
            if (primaryAlive || graceAlive) revert OracleStillLive();
        }

        bool boundWins = (manualPrice6 >= m.lowerBound && manualPrice6 <= m.upperBound);
        uint256[] memory payouts = new uint256[](2);
        if (boundWins) {
            payouts[0] = 0;
            payouts[1] = 1;
        } else {
            payouts[0] = 1;
            payouts[1] = 0;
        }

        _setPayouts(conditionId, assetKey, payouts);

        m.resolved = true;
        m.resolvedPrice = manualPrice6;
        m.boundWins = boundWins;

        emit BrimdexMarketEmergencyResolved(conditionId, assetKey, manualPrice6, boundWins, payouts, priceProofHash);
    }

    function _resolveApply(
        bytes32 conditionId,
        bytes32 assetKey,
        BrimdexMarketParams storage m,
        string memory feedKey,
        uint128 oraclePrice,
        uint128 oracleTs,
        uint256 finalPrice
    ) private {
        bool boundWins = (finalPrice >= m.lowerBound && finalPrice <= m.upperBound);
        uint256[] memory payouts = new uint256[](2);
        if (boundWins) {
            payouts[0] = 0;
            payouts[1] = 1;
        } else {
            payouts[0] = 1;
            payouts[1] = 0;
        }

        _setPayouts(conditionId, assetKey, payouts);

        m.resolved = true;
        m.resolvedPrice = finalPrice;
        m.boundWins = boundWins;

        emit BrimdexMarketResolved(conditionId, assetKey, feedKey, oraclePrice, oracleTs, finalPrice, boundWins, payouts);
    }

    /// @dev DIA always returns 8 decimals. Normalize to TARGET_DECIMALS (6).
    function _normalizeToTargetDecimals(uint128 price) internal pure returns (uint256) {
        // DIA_DECIMALS (8) >= TARGET_DECIMALS (6), so always divide
        return uint256(price) / (10 ** (DIA_DECIMALS - TARGET_DECIMALS));
    }

    function _setPayouts(bytes32 conditionId, bytes32 assetKey, uint256[] memory payouts) internal {
        uint256 outcomeSlotCount = payouts.length;
        if (outcomeSlotCount <= 1) revert TooManyOutcomeSlots();

        uint256 den = 0;
        for (uint256 i = 0; i < outcomeSlotCount; i++) {
            uint256 num = payouts[i];
            den += num;
            if (payoutNumerators[conditionId][i] != 0) revert AlreadyResolved();
            payoutNumerators[conditionId][i] = num;
        }
        if (den == 0) revert InvalidPrice();
        payoutDenominator[conditionId] = den;
        emit ConditionResolution(conditionId, address(this), assetKey, outcomeSlotCount, payoutNumerators[conditionId]);
    }

    // --- Gnosis ConditionalTokens core (ported) ---

    function splitPosition(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] memory partition,
        uint256 amount
    ) public {
        if (partition.length <= 1) revert InvalidBounds();
        uint256 outcomeSlotCount = payoutNumerators[conditionId].length;
        if (outcomeSlotCount == 0) revert ConditionNotPrepared();

        uint256 fullIndexSet = (1 << outcomeSlotCount) - 1;
        uint256 freeIndexSet = fullIndexSet;
        uint256[] memory positionIds = new uint256[](partition.length);
        uint256[] memory amounts = new uint256[](partition.length);
        for (uint256 i = 0; i < partition.length; i++) {
            uint256 indexSet = partition[i];
            if (indexSet == 0 || indexSet >= fullIndexSet) revert InvalidBounds();
            if ((indexSet & freeIndexSet) != indexSet) revert InvalidBounds();
            freeIndexSet ^= indexSet;
            positionIds[i] = CTHelpers.getPositionId(
                collateralToken,
                CTHelpers.getCollectionId(parentCollectionId, conditionId, indexSet)
            );
            amounts[i] = amount;
        }

        if (freeIndexSet == 0) {
            if (parentCollectionId == bytes32(0)) {
                require(collateralToken.transferFrom(msg.sender, address(this), amount), "could not receive collateral tokens");
            } else {
                _burn(msg.sender, CTHelpers.getPositionId(collateralToken, parentCollectionId), amount);
            }
        } else {
            _burn(
                msg.sender,
                CTHelpers.getPositionId(
                    collateralToken,
                    CTHelpers.getCollectionId(parentCollectionId, conditionId, fullIndexSet ^ freeIndexSet)
                ),
                amount
            );
        }

        _mintBatch(msg.sender, positionIds, amounts, "");
        emit PositionSplit(msg.sender, collateralToken, parentCollectionId, conditionId, partition, amount);
    }

    function mergePositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] memory partition,
        uint256 amount
    ) public {
        if (partition.length <= 1) revert InvalidBounds();
        uint256 outcomeSlotCount = payoutNumerators[conditionId].length;
        if (outcomeSlotCount == 0) revert ConditionNotPrepared();

        uint256 fullIndexSet = (1 << outcomeSlotCount) - 1;
        uint256 freeIndexSet = fullIndexSet;
        uint256[] memory positionIds = new uint256[](partition.length);
        uint256[] memory amounts = new uint256[](partition.length);
        for (uint256 i = 0; i < partition.length; i++) {
            uint256 indexSet = partition[i];
            if (indexSet == 0 || indexSet >= fullIndexSet) revert InvalidBounds();
            if ((indexSet & freeIndexSet) != indexSet) revert InvalidBounds();
            freeIndexSet ^= indexSet;
            positionIds[i] = CTHelpers.getPositionId(
                collateralToken,
                CTHelpers.getCollectionId(parentCollectionId, conditionId, indexSet)
            );
            amounts[i] = amount;
        }
        _burnBatch(msg.sender, positionIds, amounts);

        if (freeIndexSet == 0) {
            if (parentCollectionId == bytes32(0)) {
                require(collateralToken.transfer(msg.sender, amount), "could not send collateral tokens");
            } else {
                _mint(msg.sender, CTHelpers.getPositionId(collateralToken, parentCollectionId), amount, "");
            }
        } else {
            _mint(
                msg.sender,
                CTHelpers.getPositionId(
                    collateralToken,
                    CTHelpers.getCollectionId(parentCollectionId, conditionId, fullIndexSet ^ freeIndexSet)
                ),
                amount,
                ""
            );
        }

        emit PositionsMerge(msg.sender, collateralToken, parentCollectionId, conditionId, partition, amount);
    }

    function redeemPositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external {
        uint256 den = payoutDenominator[conditionId];
        if (den == 0) revert ConditionNotPrepared();
        uint256 outcomeSlotCount = payoutNumerators[conditionId].length;
        if (outcomeSlotCount == 0) revert ConditionNotPrepared();

        uint256 totalPayout = 0;
        uint256 fullIndexSet = (1 << outcomeSlotCount) - 1;
        for (uint256 i = 0; i < indexSets.length; i++) {
            uint256 indexSet = indexSets[i];
            if (indexSet == 0 || indexSet >= fullIndexSet) revert InvalidBounds();
            uint256 positionId = CTHelpers.getPositionId(
                collateralToken,
                CTHelpers.getCollectionId(parentCollectionId, conditionId, indexSet)
            );

            uint256 payoutNumerator = 0;
            for (uint256 j = 0; j < outcomeSlotCount; j++) {
                if ((indexSet & (1 << j)) != 0) {
                    payoutNumerator += payoutNumerators[conditionId][j];
                }
            }

            uint256 payoutStake = balanceOf(msg.sender, positionId);
            if (payoutStake > 0) {
                totalPayout += (payoutStake * payoutNumerator) / den;
                _burn(msg.sender, positionId, payoutStake);
            }
        }

        if (totalPayout > 0) {
            if (parentCollectionId == bytes32(0)) {
                require(collateralToken.transfer(msg.sender, totalPayout), "could not transfer payout to message sender");
            } else {
                _mint(msg.sender, CTHelpers.getPositionId(collateralToken, parentCollectionId), totalPayout, "");
            }
        }
        emit PayoutRedemption(msg.sender, collateralToken, parentCollectionId, conditionId, indexSets, totalPayout);
    }

    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256) {
        return payoutNumerators[conditionId].length;
    }

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external pure returns (bytes32) {
        return CTHelpers.getConditionId(oracle, questionId, outcomeSlotCount);
    }

    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet) external view returns (bytes32) {
        return CTHelpers.getCollectionId(parentCollectionId, conditionId, indexSet);
    }

    function getPositionId(IERC20 collateralToken, bytes32 collectionId) external pure returns (uint256) {
        return CTHelpers.getPositionId(collateralToken, collectionId);
    }
}
