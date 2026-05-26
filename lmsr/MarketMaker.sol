// SPDX-License-Identifier: LGPL-3.0
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SignedSafeMath} from "./SignedSafeMath.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {CTHelpers} from "../ct/CTHelpers.sol";
import {BrimdexConditionalTokens} from "../ct/BrimdexConditionalTokens.sol";
import {Whitelist} from "./Whitelist.sol";

interface ILPVault {
    function receiveLP(uint256 amount) external;
}

interface IBrimdexFeeConfig {
    function getFeeRate(address user) external view returns (uint256);
    function splitFee(uint256 totalFee, bool stakingActive) external view returns (uint256 lpFee, uint256 stakerFee, uint256 protocolFee);
    function protocolWallet() external view returns (address);
    function stakingRewards() external view returns (address);
    function FEE_RANGE() external view returns (uint256);
}

interface IStakingRewards {
    function notifyRewardAmount(uint256 reward) external;
}

/// @title MarketMaker (Gnosis LMSR base, Solidity 0.8 + BrimdexConditionalTokens)
abstract contract MarketMaker is Ownable, ERC1155Holder, ReentrancyGuard {
    using SignedSafeMath for int256;
    using SafeERC20 for IERC20;

    event AMMCreated(uint256 initialFunding);
    event AMMPaused();
    event AMMResumed();
    event AMMClosed();
    event AMMFundingChanged(int256 fundingChange);
    event AMMFeeWithdrawal(uint256 fees);
    event AMMResidualSentToVault(uint256 residual, uint256 fees);
    /// @notice Owner-driven emergency resolution after the oracle's grace window closed.
    /// @param manualPrice6   Owner-supplied settlement price in 6-decimal USD.
    /// @param priceProofHash Owner-supplied proof anchor (e.g. IPFS CID of a signed off-chain price).
    event AMMEmergencyResolved(uint256 manualPrice6, bytes32 priceProofHash);
    event AMMOutcomeTokenTrade(
        address indexed transactor,
        int256[] outcomeTokenAmounts,
        int256 outcomeTokenNetCost,
        uint256 marketFees
    );

    BrimdexConditionalTokens public pmSystem;
    IERC20 public collateralToken;
    bytes32[] public conditionIds;
    uint256 public atomicOutcomeSlotCount;
    uint256 public funding;
    /// @notice Fee configuration contract — provides fee rates and split logic.
    IBrimdexFeeConfig public feeConfig;
    /// @notice Collateral accrued from trading fees — protocol cut (0.32%). Withdrawable permissionlessly to protocolWallet.
    uint256 public accruedProtocolFees;
    /// @notice Collateral accrued from trading fees — LP cut (0.48%). Sent to vault LP pool on resolve.
    uint256 public accruedLPFees;
    Stage public stage;
    Whitelist public whitelist;

    /// @notice Market parameters stored for permissionless resolution.
    bytes32 public assetKey;
    uint256 public lowerBound;
    uint256 public upperBound;
    uint256 public expiryTimestamp;
    address public vault; ///< The vault that opened this market (used for conditionId derivation)

    /// @notice Only this address may call `tradeFrom` (typically the trade router). address(0) disables `tradeFrom`.
    address public immutable tradeRouter;
    /// @notice Only this address may call `completeBootstrap` once (typically the stack factory). address(0) disables bootstrap.
    address public immutable bootstrapExecutor;

    bool private bootstrapComplete;

    uint256[] internal outcomeSlotCounts;
    bytes32[][] internal collectionIds;
    uint256[] internal positionIds;

    enum Stage {
        Running,
        Paused,
        Closed
    }

    modifier atStage(Stage _stage) {
        require(stage == _stage, "bad stage");
        _;
    }

    modifier onlyWhitelisted() {
        require(
            address(whitelist) == address(0) || whitelist.isWhitelisted(msg.sender),
            "only whitelisted users may call this function"
        );
        _;
    }

    function calcNetCost(int256[] memory outcomeTokenAmounts) public view virtual returns (int256 netCost);

    constructor(
        address initialOwner,
        address tradeRouter_,
        address bootstrapExecutor_,
        BrimdexConditionalTokens _pmSystem,
        IERC20 _collateralToken,
        bytes32[] memory _conditionIds,
        IBrimdexFeeConfig feeConfig_,
        Whitelist _whitelist,
        bytes32 _assetKey,
        uint256 _lowerBound,
        uint256 _upperBound,
        uint256 _expiryTimestamp,
        address _vault
    ) Ownable(initialOwner) {
        require(address(_pmSystem) != address(0), "bad args");
        require(address(feeConfig_) != address(0), "bad feeConfig");
        require(tradeRouter_ != address(0) && bootstrapExecutor_ != address(0), "routers");
        tradeRouter = tradeRouter_;
        bootstrapExecutor = bootstrapExecutor_;
        pmSystem = _pmSystem;
        collateralToken = _collateralToken;
        conditionIds = _conditionIds;
        feeConfig = feeConfig_;
        whitelist = _whitelist;
        assetKey = _assetKey;
        lowerBound = _lowerBound;
        upperBound = _upperBound;
        expiryTimestamp = _expiryTimestamp;
        vault = _vault;

        atomicOutcomeSlotCount = 1;
        outcomeSlotCounts = new uint256[](conditionIds.length);
        for (uint256 i = 0; i < conditionIds.length; i++) {
            uint256 outcomeSlotCount = pmSystem.getOutcomeSlotCount(conditionIds[i]);
            atomicOutcomeSlotCount *= outcomeSlotCount;
            outcomeSlotCounts[i] = outcomeSlotCount;
        }
        require(atomicOutcomeSlotCount > 1, "conditions must be valid");

        collectionIds = new bytes32[][](conditionIds.length);
        _recordCollectionIDsForAllConditions(conditionIds.length, bytes32(0));

        stage = Stage.Paused;
        emit AMMCreated(funding);
    }

    /// @notice One-shot: collateral must already be on this contract. Then splits, sets funding, resumes.
    function completeBootstrap(uint256 amount) external {
        require(msg.sender == bootstrapExecutor && bootstrapExecutor != address(0), "bootstrap");
        require(!bootstrapComplete, "booted");
        require(stage == Stage.Paused && funding == 0, "state");
        require(amount > 0, "amt");
        require(collateralToken.balanceOf(address(this)) >= amount, "collateral");

        bootstrapComplete = true;
        collateralToken.safeIncreaseAllowance(address(pmSystem), amount);
        splitPositionThroughAllConditions(amount);
        funding = amount;
        emit AMMFundingChanged(int256(uint256(amount)));
        stage = Stage.Running;
        emit AMMResumed();
    }

    function _recordCollectionIDsForAllConditions(uint256 conditionsLeft, bytes32 parentCollectionId) private {
        if (conditionsLeft == 0) {
            positionIds.push(CTHelpers.getPositionId(collateralToken, parentCollectionId));
            return;
        }
        conditionsLeft--;
        uint256 outcomeSlotCount = outcomeSlotCounts[conditionsLeft];
        collectionIds[conditionsLeft].push(parentCollectionId);
        for (uint256 i = 0; i < outcomeSlotCount; i++) {
            _recordCollectionIDsForAllConditions(
                conditionsLeft,
                CTHelpers.getCollectionId(parentCollectionId, conditionIds[conditionsLeft], uint256(1 << i))
            );
        }
    }

    function changeFunding(int256 fundingChange) public onlyOwner atStage(Stage.Paused) {
        require(fundingChange != 0, "funding change must be non-zero");
        if (fundingChange > 0) {
            uint256 u = uint256(fundingChange);
            collateralToken.safeTransferFrom(msg.sender, address(this), u);
            collateralToken.safeIncreaseAllowance(address(pmSystem), u);
            splitPositionThroughAllConditions(u);
            funding += u;
            emit AMMFundingChanged(fundingChange);
        }
        if (fundingChange < 0) {
            require(!bootstrapComplete, "cannot withdraw liquidity after bootstrap");
            uint256 u = uint256(-fundingChange);
            mergePositionsThroughAllConditions(u);
            funding -= u;
            collateralToken.safeTransfer(owner(), u);
            emit AMMFundingChanged(fundingChange);
        }
    }

    function pause() public onlyOwner atStage(Stage.Running) {
        stage = Stage.Paused;
        emit AMMPaused();
    }

    function resume() public onlyOwner atStage(Stage.Paused) {
        stage = Stage.Running;
        emit AMMResumed();
    }

    /// @notice Permissionless: sends accrued protocol fees to `feeConfig.protocolWallet()`.
    function withdrawFees() public returns (uint256 sent) {
        uint256 bal = accruedProtocolFees;
        if (bal == 0) revert("no fees");
        sent = bal;
        require(collateralToken.balanceOf(address(this)) >= sent, "insufficient collateral");
        accruedProtocolFees = 0;
        address pw = feeConfig.protocolWallet();
        collateralToken.safeTransfer(pw, sent);
        emit AMMFeeWithdrawal(sent);
    }

    /// @notice Permissionless resolution after expiry (also invoked by settlement pullers).
    ///         After resolution, redeems the market's own winning position tokens and sends
    ///         residual USDC + accrued LP fees to the vault LP pool for LP distribution.
    function resolve() external nonReentrant {
        pmSystem.resolve(assetKey, lowerBound, upperBound, expiryTimestamp, vault);

        _teardownAfterCTFResolved();
    }

    /// @notice Owner-only emergency settlement. Use ONLY when the oracle is permanently dead and
    ///         `resolve()` would revert forever. The owner (Gnosis Safe) supplies a settlement
    ///         price in 6-decimal USD. Intentionally not routed through governance to prevent
    ///         whales from voting markets to resolve in their own favor.
    ///
    ///         The CTF additionally re-checks that BOTH oracle paths are dead so the owner cannot
    ///         override a still-working DIA feed.
    ///
    /// @param manualPrice6   Settlement price in 6-decimal USD (must be >= CTF MIN_SPOT_6).
    /// @param priceProofHash Off-chain evidence anchor for the chosen price (IPFS CID, signed
    ///                       Pyth/Chainlink/CEX print, etc.). Pass `bytes32(0)` if none.
    function emergencyResolve(uint256 manualPrice6, bytes32 priceProofHash)
        external
        onlyOwner
        nonReentrant
    {
        pmSystem.emergencyResolve(
            assetKey,
            lowerBound,
            upperBound,
            expiryTimestamp,
            vault,
            manualPrice6,
            priceProofHash
        );

        emit AMMEmergencyResolved(manualPrice6, priceProofHash);

        _teardownAfterCTFResolved();
    }

    /// @dev Shared teardown for `resolve` and `emergencyResolve`: redeem the market's own
    ///      winning position tokens and forward residual + accrued LP fees to the LP vault.
    function _teardownAfterCTFResolved() private {
        uint256[] memory indexSets = new uint256[](atomicOutcomeSlotCount);
        for (uint256 i = 0; i < atomicOutcomeSlotCount; i++) {
            indexSets[i] = 1 << i;
        }
        uint256 balBefore = collateralToken.balanceOf(address(this));
        pmSystem.redeemPositions(collateralToken, bytes32(0), conditionIds[0], indexSets);
        uint256 residual = collateralToken.balanceOf(address(this)) - balBefore;

        uint256 toVault = residual + accruedLPFees;
        if (toVault > 0 && vault != address(0)) {
            uint256 lpFees = accruedLPFees;
            accruedLPFees = 0;
            collateralToken.safeIncreaseAllowance(vault, toVault);
            ILPVault(vault).receiveLP(toVault);
            emit AMMResidualSentToVault(residual, lpFees);
        }

        stage = Stage.Closed;
        emit AMMClosed();
    }

    function trade(int256[] memory outcomeTokenAmounts, int256 collateralLimit)
        public
        nonReentrant
        atStage(Stage.Running)
        onlyWhitelisted
        returns (int256 netCost)
    {
        return _trade(msg.sender, outcomeTokenAmounts, collateralLimit);
    }

    /// @notice Router-only: same as `trade` but collateral / outcome ERC1155 use `payer` (payer must have approved this market).
    function tradeFrom(address payer, int256[] memory outcomeTokenAmounts, int256 collateralLimit)
        external
        nonReentrant
        atStage(Stage.Running)
        returns (int256 netCost)
    {
        require(msg.sender == tradeRouter && tradeRouter != address(0), "trade router");
        require(address(whitelist) == address(0) || whitelist.isWhitelisted(payer), "wl payer");
        return _trade(payer, outcomeTokenAmounts, collateralLimit);
    }

    function _trade(address transactor, int256[] memory outcomeTokenAmounts, int256 collateralLimit)
        internal
        returns (int256 netCost)
    {
        require(outcomeTokenAmounts.length == atomicOutcomeSlotCount, "len");
        require(block.timestamp < expiryTimestamp, "expired");

        int256 outcomeTokenNetCost = calcNetCost(outcomeTokenAmounts);

        // Get fee rate for this trader (discounted if xBDX holder)
        uint256 feeRate = feeConfig.getFeeRate(transactor);
        uint256 totalFee = (uint256(outcomeTokenNetCost < 0 ? -outcomeTokenNetCost : outcomeTokenNetCost) * feeRate) / feeConfig.FEE_RANGE();

        address sr = feeConfig.stakingRewards();
        bool stakingActive = sr != address(0);
        (uint256 lpFee, uint256 stakerFee, uint256 protocolFee) = feeConfig.splitFee(totalFee, stakingActive);

        accruedLPFees += lpFee;
        accruedProtocolFees += protocolFee;

        netCost = outcomeTokenNetCost + int256(totalFee);

        require((collateralLimit != 0 && netCost <= collateralLimit) || collateralLimit == 0, "limit");

        if (outcomeTokenNetCost > 0) {
            collateralToken.safeTransferFrom(transactor, address(this), uint256(netCost));
            collateralToken.safeIncreaseAllowance(address(pmSystem), uint256(outcomeTokenNetCost));
            splitPositionThroughAllConditions(uint256(outcomeTokenNetCost));
        }

        bool touched = false;
        uint256[] memory transferAmounts = new uint256[](atomicOutcomeSlotCount);
        for (uint256 i = 0; i < atomicOutcomeSlotCount; i++) {
            if (outcomeTokenAmounts[i] < 0) {
                touched = true;
                transferAmounts[i] = uint256(-outcomeTokenAmounts[i]);
            }
        }
        if (touched) {
            pmSystem.safeBatchTransferFrom(transactor, address(this), positionIds, transferAmounts, "");
        }

        if (outcomeTokenNetCost < 0) {
            mergePositionsThroughAllConditions(uint256(-outcomeTokenNetCost));
        }

        emit AMMOutcomeTokenTrade(transactor, outcomeTokenAmounts, outcomeTokenNetCost, totalFee);

        touched = false;
        for (uint256 i = 0; i < atomicOutcomeSlotCount; i++) {
            if (outcomeTokenAmounts[i] > 0) {
                touched = true;
                transferAmounts[i] = uint256(outcomeTokenAmounts[i]);
            } else {
                transferAmounts[i] = 0;
            }
        }
        if (touched) {
            pmSystem.safeBatchTransferFrom(address(this), transactor, positionIds, transferAmounts, "");
        }

        if (netCost < 0) {
            collateralToken.safeTransfer(transactor, uint256(-netCost));
        }

        // Push staker fee LAST. By this point the market has received `totalFee` USDC
        // regardless of buy/sell direction (trader paid totalFee on buy; market retained
        // totalFee out of merge proceeds on sell), so `notifyRewardAmount` can safely pull
        // `stakerFee` without underflowing the market's USDC balance. Doing it first would
        // brick the very first trade after bootstrap because all bootstrap collateral has
        // been split into the CTF and the market holds 0 USDC.
        if (stakerFee > 0 && stakingActive) {
            collateralToken.safeIncreaseAllowance(sr, stakerFee);
            IStakingRewards(sr).notifyRewardAmount(stakerFee);
        }
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public virtual override returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function generateBasicPartition(uint256 outcomeSlotCount) private pure returns (uint256[] memory partition) {
        partition = new uint256[](outcomeSlotCount);
        for (uint256 i = 0; i < outcomeSlotCount; i++) {
            partition[i] = uint256(1 << i);
        }
    }

    function generateAtomicPositionId(uint256 i) internal view returns (uint256) {
        return positionIds[i];
    }

    function splitPositionThroughAllConditions(uint256 amount) private {
        for (uint256 i = conditionIds.length; i > 0; i--) {
            uint256 idx = i - 1;
            uint256[] memory partition = generateBasicPartition(outcomeSlotCounts[idx]);
            for (uint256 j = 0; j < collectionIds[idx].length; j++) {
                pmSystem.splitPosition(collateralToken, collectionIds[idx][j], conditionIds[idx], partition, amount);
            }
        }
    }

    function mergePositionsThroughAllConditions(uint256 amount) private {
        for (uint256 i = 0; i < conditionIds.length; i++) {
            uint256[] memory partition = generateBasicPartition(outcomeSlotCounts[i]);
            for (uint256 j = 0; j < collectionIds[i].length; j++) {
                pmSystem.mergePositions(collateralToken, collectionIds[i][j], conditionIds[i], partition, amount);
            }
        }
    }
}
