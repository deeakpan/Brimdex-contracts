// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BrimdexLMSRStackFactory} from "../lmsr/BrimdexLMSRStackFactory.sol";
import {LMSRMarketMaker} from "../lmsr/LMSRMarketMaker.sol";
import {Whitelist} from "../lmsr/Whitelist.sol";
import {BrimdexAssetRegistry} from "../ct/BrimdexAssetRegistry.sol";
import {IDIAOracleV2} from "../ct/IDIAOracleV2.sol";
import {IBrimdexSettlementCoordinator} from "../interfaces/IBrimdexSettlementCoordinator.sol";

/// @title BrimdexStackLaunchVault
/// @notice USDC commitments for a future LMSR. At notional: pull coordinator schedules agent; open coordinator schedules `finishOpen` on a separate Somnia handler.
/// @dev Manual `openCommittedMarket` remains if `reactivityCoordinator` is zero. Collateral is `stack.collateralAsset()`.
contract BrimdexStackLaunchVault is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Same as `BrimdexConditionalTokens.TARGET_DECIMALS` — bounds and spot must align for resolution.
    uint256 internal constant TARGET_DECIMALS = 6;
    uint256 internal constant MAX_ORACLE_STALENESS = 360;
    uint8   internal constant DIA_DECIMALS = 8;
    /// @notice Minimum band for any asset (0.5% = 50 bps).
    uint16 internal constant MIN_BAND_BPS = 50;
    uint16 internal constant BPS_DENOM = 10_000;

    enum Phase {
        Open,
        PendingLaunch,
        Launched,
        Aborted
    }

    /// @notice Market lifetime after open: `expiry = block.timestamp + horizonSeconds`.
    uint256 public constant MIN_HORIZON_SECONDS = 5 * 60;

    BrimdexLMSRStackFactory public immutable stack;
    IERC20 public immutable asset;

    /// @notice Pull + settlement scheduler (`BrimdexReactivityCoordinator`). `address(0)` skips scheduling (tests).
    address public immutable reactivityCoordinator;
    /// @notice Open tick scheduler (`BrimdexLaunchOpenCoordinator`). `address(0)` when pull coordinator is zero.
    address public immutable launchOpenCoordinator;
    uint8 public immutable assetId;

    address public immutable designatedOwner;
    bytes32 public immutable assetKey;
    uint16 public immutable bandBps;
    uint256 public immutable horizonSeconds;
    uint64 public immutable tradeFeeRate;
    address public immutable tradeGuard;
    uint256 public immutable requiredNotional;
    uint256 public immutable commitmentDeadline;

    Phase private _phase;
    uint256 public committed;
    LMSRMarketMaker public deployedMarket;

    /// @notice USDC received from market after resolution (residual + fees). Used for LP redemption.
    uint256 public lpPool;
    /// @notice Total commitment token supply at the time lpPool was received (for pro-rata calculation).
    uint256 public lpTotalSupply;

    /// @notice Returns the current phase, computing Aborted lazily.
    function phase() public view returns (Phase) {
        if (_phase != Phase.Open && _phase != Phase.PendingLaunch) return _phase;
        if (block.timestamp > commitmentDeadline && committed < requiredNotional) return Phase.Aborted;
        return _phase;
    }

    event CommitmentRecorded(address indexed account, uint256 requested, uint256 applied, uint256 surplusRequested);
    event NotionalReached(uint256 notional, uint256 when);
    event LaunchAborted(uint256 committed_, uint256 requiredNotional_, uint256 when);
    event StackLaunched(
        address indexed market,
        uint256 notional,
        uint256 launchSpotPrice6,
        uint256 lowerBound6,
        uint256 upperBound6,
        uint256 payoffExpiry,
        uint16 bandBps,
        uint256 horizonSeconds,
        uint128 diaPrice,
        uint128 diaTimestamp
    );
    event CommitmentRedeemed(address indexed account, uint256 amount);
    event LPRedeemed(address indexed account, uint256 commitmentBurned, uint256 usdcReceived);
    event LPPoolReceived(uint256 amount);

    error BadPhase();
    error BadAmount();
    error WindowClosed();
    error TargetMet();
    error UnderTarget();
    error TransfersFrozen();
    error ZeroAddress();
    error InvalidNotional();
    error InvalidSchedule();
    error InvalidBand();
    error InvalidHorizon();
    error UnknownFeed();
    error StaleOracle();
    error InvalidOraclePrice();
    error NotResolved();
    error InvalidAssetId();
    error UnauthorizedPuller();

    constructor(
        BrimdexLMSRStackFactory stack_,
        address designatedOwner_,
        bytes32 assetKey_,
        uint16 bandBps_,
        uint256 horizonSeconds_,
        uint64 tradeFeeRate_,
        address tradeGuard_,
        uint256 requiredNotional_,
        uint256 commitmentDeadline_,
        address reactivityCoordinator_,
        address launchOpenCoordinator_,
        uint8 assetId_
    ) ERC20("Brimdex Stack Commitment", "BRMDX-COMMIT") {
        if (address(stack_) == address(0) || designatedOwner_ == address(0)) revert ZeroAddress();
        if (assetKey_ == bytes32(0)) revert ZeroAddress();
        if (requiredNotional_ == 0) revert InvalidNotional();
        if (commitmentDeadline_ <= block.timestamp) revert InvalidSchedule();
        if (bandBps_ < MIN_BAND_BPS || bandBps_ >= BPS_DENOM) revert InvalidBand();
        if (horizonSeconds_ < MIN_HORIZON_SECONDS) revert InvalidHorizon();
        if (assetId_ >= 16) revert InvalidAssetId();

        // Validate asset is registered before anyone can commit
        stack_.assetRegistry().getFeedKey(assetKey_); // reverts if not registered

        stack = stack_;
        asset = stack_.collateralAsset();
        reactivityCoordinator = reactivityCoordinator_;
        launchOpenCoordinator = launchOpenCoordinator_;
        if (reactivityCoordinator_ != address(0) && launchOpenCoordinator_ == address(0)) {
            revert ZeroAddress();
        }
        assetId = assetId_;
        designatedOwner = designatedOwner_;
        assetKey = assetKey_;
        bandBps = bandBps_;
        horizonSeconds = horizonSeconds_;
        tradeFeeRate = tradeFeeRate_;
        tradeGuard = tradeGuard_;
        requiredNotional = requiredNotional_;
        commitmentDeadline = commitmentDeadline_;
    }

    function commit(uint256 requested) external nonReentrant {
        if (phase() != Phase.Open) revert BadPhase();
        if (block.timestamp > commitmentDeadline) revert WindowClosed();
        if (committed >= requiredNotional) revert TargetMet();
        if (requested == 0) revert BadAmount();

        uint256 remaining = requiredNotional - committed;
        uint256 applied = requested <= remaining ? requested : remaining;
        uint256 surplusRequested = requested - applied;

        asset.safeTransferFrom(msg.sender, address(this), applied);
        _mint(msg.sender, applied);
        committed += applied;

        emit CommitmentRecorded(msg.sender, requested, applied, surplusRequested);

        if (committed >= requiredNotional) {
            emit NotionalReached(committed, block.timestamp);
            if (reactivityCoordinator != address(0)) {
                _phase = Phase.PendingLaunch;
                IBrimdexSettlementCoordinator(reactivityCoordinator).requestMarketLaunch(
                    address(this),
                    assetId
                );
            }
        }
    }

    /// @notice Manual open when no coordinator is configured (tests / legacy).
    function openCommittedMarket() external nonReentrant {
        if (reactivityCoordinator != address(0)) revert BadPhase();
        if (phase() != Phase.Open) revert BadPhase();
        if (committed < requiredNotional) revert UnderTarget();
        _executeOpen();
    }

    /// @notice Called by the asset puller after the launch agent writes `BrimdexFeeds`.
    function finishOpen() external nonReentrant {
        if (reactivityCoordinator == address(0)) revert BadPhase();
        if (launchOpenCoordinator == address(0)) revert BadPhase();
        if (msg.sender != IBrimdexSettlementCoordinator(launchOpenCoordinator).puller(assetId)) {
            revert UnauthorizedPuller();
        }
        if (_phase != Phase.PendingLaunch) revert BadPhase();
        if (committed < requiredNotional) revert UnderTarget();
        _executeOpen();
    }

    function _executeOpen() private {
        uint256 notional = committed;
        (
            uint256 spot6,
            uint256 lower6,
            uint256 upper6,
            uint256 expiryTs,
            uint128 diaPrice,
            uint128 diaTs
        ) = _quoteLaunchParameters();

        asset.forceApprove(address(stack), notional);

        deployedMarket = stack.openMarket(
            designatedOwner,
            assetKey,
            lower6,
            upper6,
            expiryTs,
            Whitelist(tradeGuard),
            notional,
            spot6,
            bandBps,
            horizonSeconds
        );

        asset.forceApprove(address(stack), 0);

        _phase = Phase.Launched;
        emit StackLaunched(
            address(deployedMarket),
            notional,
            spot6,
            lower6,
            upper6,
            expiryTs,
            bandBps,
            horizonSeconds,
            diaPrice,
            diaTs
        );

        if (reactivityCoordinator != address(0)) {
            IBrimdexSettlementCoordinator(reactivityCoordinator).scheduleMarketSettlement(
                address(deployedMarket),
                assetId,
                expiryTs
            );
        }
    }

    function _quoteLaunchParameters()
        private
        view
        returns (
            uint256 spot6,
            uint256 lower6,
            uint256 upper6,
            uint256 expiryTs,
            uint128 diaPrice,
            uint128 diaTs
        )
    {
        BrimdexAssetRegistry reg = stack.assetRegistry();
        string memory feedKey = reg.getFeedKey(assetKey);
        address oracle = reg.diaOracle();
        if (oracle == address(0)) revert UnknownFeed();

        (diaPrice, diaTs) = IDIAOracleV2(oracle).getValue(feedKey);
        if (diaPrice == 0) revert InvalidOraclePrice();
        if (diaTs == 0) revert InvalidOraclePrice();
        if (block.timestamp < uint256(diaTs)) revert InvalidOraclePrice();
        if (block.timestamp - uint256(diaTs) > MAX_ORACLE_STALENESS) revert StaleOracle();

        spot6 = uint256(diaPrice) / (10 ** (DIA_DECIMALS - TARGET_DECIMALS));
        if (spot6 == 0) revert InvalidOraclePrice();
        // Reject assets priced below $0.001 (MIN_SPOT_6 = 1000 in 6-decimal units)
        if (spot6 < 1000) revert InvalidOraclePrice();

        lower6 = (spot6 * (BPS_DENOM - bandBps)) / BPS_DENOM;
        upper6 = (spot6 * (BPS_DENOM + bandBps) + BPS_DENOM - 1) / BPS_DENOM;
        if (lower6 == 0) revert InvalidBand();
        if (lower6 >= upper6) revert InvalidBand();

        expiryTs = block.timestamp + horizonSeconds;
    }

    /// @notice Called by the deployed market after resolution to deposit residual USDC + fees.
    /// @dev Only the deployed market may call this.
    function receiveLP(uint256 amount) external nonReentrant {
        require(msg.sender == address(deployedMarket), "only market");
        require(amount > 0, "zero");
        asset.safeTransferFrom(msg.sender, address(this), amount);
        if (lpTotalSupply == 0) {
            lpTotalSupply = totalSupply();
        }
        lpPool += amount;
        emit LPPoolReceived(amount);
    }

    /// @notice LP redemption — burn commitment tokens to claim proportional share of lpPool.
    /// @dev Available after market resolves and lpPool is funded.
    function redeemLP() external nonReentrant {
        if (lpPool == 0) revert NotResolved();
        if (lpTotalSupply == 0) revert NotResolved();

        uint256 bal = balanceOf(msg.sender);
        if (bal == 0) revert BadAmount();

        uint256 share = (bal * lpPool) / lpTotalSupply;

        _burn(msg.sender, bal);
        if (share > 0) {
            asset.safeTransfer(msg.sender, share);
        }
        emit LPRedeemed(msg.sender, bal, share);
    }

    function _syncAborted() private {
        if (_phase != Phase.Open) return;
        if (block.timestamp <= commitmentDeadline) return;
        if (committed >= requiredNotional) return;
        _phase = Phase.Aborted;
        emit LaunchAborted(committed, requiredNotional, block.timestamp);
    }

    function redeemCommitment() external nonReentrant {
        _syncAborted();
        if (phase() != Phase.Aborted) revert BadPhase();

        uint256 bal = balanceOf(msg.sender);
        if (bal == 0) revert BadAmount();

        _burn(msg.sender, bal);
        asset.safeTransfer(msg.sender, bal);
        emit CommitmentRedeemed(msg.sender, bal);
    }

    function syncAborted() external {
        _syncAborted();
    }

    function _update(address from, address to, uint256 value) internal override {
        Phase p = phase();
        if ((p == Phase.Open || p == Phase.PendingLaunch) && from != address(0) && to != address(0)) {
            revert TransfersFrozen();
        }
        super._update(from, to, value);
    }
}
