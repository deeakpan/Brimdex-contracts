// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SomniaEventHandler} from "@somnia-chain/reactivity-contracts/contracts/SomniaEventHandler.sol";
import {SomniaExtensions} from "@somnia-chain/reactivity-contracts/contracts/interfaces/SomniaExtensions.sol";
import {ISomniaReactivityPrecompile} from "@somnia-chain/reactivity-contracts/contracts/interfaces/ISomniaReactivityPrecompile.sol";

import {BrimdexFeedAssets} from "./BrimdexFeedAssets.sol";
import {IBrimdexLaunchOpenCoordinator} from "./IBrimdexLaunchOpenCoordinator.sol";
import {IBrimdexFeedAgentPuller} from "./IBrimdexFeedAgentPuller.sol";
import {IBrimdexLaunchVault} from "../../interfaces/IBrimdexLaunchVault.sol";
import {IBrimdexMarketSettlement} from "./IBrimdexMarketSettlement.sol";
import {IBrimdexSettlementCoordinator} from "../../interfaces/IBrimdexSettlementCoordinator.sol";

/// @title BrimdexReactivityCoordinator
/// @notice Pull coordinator: launch pull tick → DIA agent; delegates open tick to `BrimdexLaunchOpenCoordinator`.
///         After open: vault → expiry tick → puller → `resolve`.
contract BrimdexReactivityCoordinator is SomniaEventHandler, IBrimdexSettlementCoordinator {
    struct SettlementJob {
        address market;
        uint8 assetId;
        bool triggered;
    }

    struct LaunchPullJob {
        address vault;
        uint8 assetId;
        bool triggered;
    }

    /// @dev Somnia agent `createRequest` needs ~37M gas; cannot run inside `commit` (~800k forwarded).
    uint64 internal constant LAUNCH_PULL_GAS_LIMIT = 40_000_000;
    /// @dev Per Playscript: distinct Schedule topics + fuzzy callback lookup when nodes round millis.
    uint256 private constant SCHEDULE_JITTER_MOD = 997;
    uint256 private constant COMPLETION_MILLIS_OFFSET = 500;

    address public immutable trustedBinder;

    address[16] private _pullers;
    bool public pullersRegistered;

    address public launchOpenCoordinator;

    mapping(uint256 => SettlementJob) public jobsByScheduleMillis;
    mapping(address => uint256) public scheduleMillisByMarket;

    mapping(uint256 => LaunchPullJob) public launchPullJobsByScheduleMillis;
    mapping(address => uint256) public launchPullScheduleMillisByVault;

    event PullersRegistered(address[16] pullers);
    event LaunchOpenCoordinatorSet(address indexed openCoordinator);
    event MarketLaunchRequested(address indexed vault, uint8 assetId, address indexed puller);
    event MarketLaunchPullSkipped(address indexed vault, uint8 assetId, uint8 reason);
    event LaunchPullScheduled(
        address indexed vault,
        uint8 assetId,
        uint256 scheduleMillis,
        uint256 subscriptionId
    );
    event LaunchPullTickFired(uint256 indexed scheduleMillis, address indexed vault, uint8 assetId);
    event LaunchPullSkipped(uint256 indexed scheduleMillis, address indexed vault, uint8 reason);
    event MarketSettlementScheduled(
        address indexed market,
        address indexed vault,
        uint8 assetId,
        uint256 expiryTimestamp,
        uint256 scheduleMillis,
        uint256 subscriptionId
    );
    event SettlementTickFired(uint256 indexed scheduleMillis, address indexed market, uint8 assetId);
    event SettlementPullSkipped(uint256 indexed scheduleMillis, address indexed market, uint8 reason);

    error Unauthorized();
    error BadConfig();
    error PullersAlreadyRegistered();
    error AlreadyScheduled();
    error InvalidExpiry();
    error NativeSendFailed();

    event NativeWithdrawn(address indexed to, uint256 amount);

    constructor(address trustedBinder_) payable {
        if (trustedBinder_ == address(0)) revert BadConfig();
        trustedBinder = trustedBinder_;
    }

    receive() external payable {}

    function puller(uint8 assetId) external view returns (address) {
        if (assetId >= BrimdexFeedAssets.ASSET_COUNT) revert BrimdexFeedAssets.BadAsset();
        return _pullers[assetId];
    }

    function registerPullers(address[16] calldata pullers_) external {
        if (msg.sender != trustedBinder) revert Unauthorized();
        if (pullersRegistered) revert PullersAlreadyRegistered();
        for (uint8 i = 0; i < BrimdexFeedAssets.ASSET_COUNT; ++i) {
            if (pullers_[i] == address(0)) revert BadConfig();
            _pullers[i] = pullers_[i];
        }
        pullersRegistered = true;
        emit PullersRegistered(pullers_);
    }

    /// @notice Binder: wire the open coordinator deployed with `launchPullCoordinator = address(this)`.
    function setLaunchOpenCoordinator(address openCoordinator_) external {
        if (msg.sender != trustedBinder) revert Unauthorized();
        if (openCoordinator_ == address(0)) revert BadConfig();
        if (launchOpenCoordinator != address(0)) revert BadConfig();
        if (IBrimdexLaunchOpenCoordinator(openCoordinator_).launchPullCoordinator() != address(this)) {
            revert BadConfig();
        }
        launchOpenCoordinator = openCoordinator_;
        emit LaunchOpenCoordinatorSet(openCoordinator_);
    }

    /// @inheritdoc IBrimdexSettlementCoordinator
    /// @dev Schedules pull (~2s) on this handler; open (+30s) on `launchOpenCoordinator`.
    function requestMarketLaunch(address vault, uint8 assetId) external {
        if (!pullersRegistered) revert BadConfig();
        if (launchOpenCoordinator == address(0)) revert BadConfig();
        if (vault == address(0)) revert BadConfig();
        if (assetId >= BrimdexFeedAssets.ASSET_COUNT) revert BadConfig();
        if (IBrimdexLaunchVault(vault).reactivityCoordinator() != address(this)) revert Unauthorized();
        if (IBrimdexLaunchVault(vault).assetId() != assetId) revert Unauthorized();

        address pullerAddr = _pullers[assetId];
        if (pullerAddr == address(0)) {
            emit MarketLaunchPullSkipped(vault, assetId, 1);
            return;
        }

        emit MarketLaunchRequested(vault, assetId, pullerAddr);

        if (launchPullScheduleMillisByVault[vault] != 0) return;

        uint256 pullMillis = _uniqueAmong(_launchPullMillisKey(vault));

        launchPullJobsByScheduleMillis[pullMillis] = LaunchPullJob({
            vault: vault,
            assetId: assetId,
            triggered: false
        });
        launchPullScheduleMillisByVault[vault] = pullMillis;

        SomniaExtensions.SubscriptionOptions memory pullOpts = SomniaExtensions.SubscriptionOptions({
            priorityFeePerGas: SomniaExtensions.DEFAULT_PRIORITY_FEE_PER_GAS,
            maxFeePerGas: SomniaExtensions.DEFAULT_MAX_FEE_PER_GAS,
            gasLimit: LAUNCH_PULL_GAS_LIMIT
        });

        uint256 pullSubId =
            SomniaExtensions.scheduleSubscriptionAtTimestamp(address(this), pullMillis, pullOpts);

        emit LaunchPullScheduled(vault, assetId, pullMillis, pullSubId);

        IBrimdexLaunchOpenCoordinator(launchOpenCoordinator).scheduleLaunchAtNotional(vault, assetId);
    }

    /// @inheritdoc IBrimdexSettlementCoordinator
    function scheduleLaunchCompletion(address vault) external {
        if (!pullersRegistered) revert BadConfig();
        if (launchOpenCoordinator == address(0)) revert BadConfig();
        if (vault == address(0)) revert BadConfig();
        if (IBrimdexLaunchVault(vault).reactivityCoordinator() != address(this)) revert Unauthorized();

        uint8 assetId = IBrimdexLaunchVault(vault).assetId();
        if (assetId >= BrimdexFeedAssets.ASSET_COUNT) revert BadConfig();
        if (msg.sender != _pullers[assetId]) revert Unauthorized();

        IBrimdexLaunchOpenCoordinator(launchOpenCoordinator).scheduleLaunchCompletion(vault);
    }

    /// @inheritdoc IBrimdexSettlementCoordinator
    function scheduleMarketSettlement(address market, uint8 assetId, uint256 expiryTimestamp) external {
        if (!pullersRegistered) revert BadConfig();
        if (market == address(0)) revert BadConfig();
        if (assetId >= BrimdexFeedAssets.ASSET_COUNT) revert BadConfig();
        if (expiryTimestamp <= block.timestamp) revert InvalidExpiry();
        if (scheduleMillisByMarket[market] != 0) revert AlreadyScheduled();
        if (IBrimdexMarketSettlement(market).vault() != msg.sender) revert Unauthorized();

        uint256 scheduleMillis = _uniqueAmong(_settlementMillisKey(market, expiryTimestamp));

        jobsByScheduleMillis[scheduleMillis] = SettlementJob({
            market: market,
            assetId: assetId,
            triggered: false
        });
        scheduleMillisByMarket[market] = scheduleMillis;

        SomniaExtensions.SubscriptionOptions memory opts = SomniaExtensions.SubscriptionOptions({
            priorityFeePerGas: SomniaExtensions.DEFAULT_PRIORITY_FEE_PER_GAS,
            maxFeePerGas: SomniaExtensions.DEFAULT_MAX_FEE_PER_GAS,
            gasLimit: 30_000_000
        });

        uint256 subId = SomniaExtensions.scheduleSubscriptionAtTimestamp(address(this), scheduleMillis, opts);

        emit MarketSettlementScheduled(
            market,
            msg.sender,
            assetId,
            expiryTimestamp,
            scheduleMillis,
            subId
        );
    }

    function _onEvent(address emitter, bytes32[] calldata eventTopics, bytes calldata data) internal override {
        emitter;
        data;
        if (eventTopics.length < 2) return;
        if (eventTopics[0] != ISomniaReactivityPrecompile.Schedule.selector) return;

        uint256 tsMillis = uint256(eventTopics[1]);

        (address pullVault, uint8 pullAssetId, uint256 pullKey) = _lookupLaunchPull(tsMillis);
        if (pullVault != address(0)) {
            LaunchPullJob storage pullJob = launchPullJobsByScheduleMillis[pullKey];
            if (pullJob.triggered) return;
            pullJob.triggered = true;
            emit LaunchPullTickFired(tsMillis, pullVault, pullAssetId);

            address launchPuller = _pullers[pullAssetId];
            if (launchPuller == address(0)) {
                emit LaunchPullSkipped(tsMillis, pullVault, 1);
                return;
            }

            IBrimdexFeedAgentPuller(launchPuller).pullForLaunch(pullVault);
            return;
        }

        (address market, uint8 settleAssetId, uint256 settleKey) = _lookupSettlement(tsMillis);
        if (market == address(0)) return;

        SettlementJob storage job = jobsByScheduleMillis[settleKey];
        if (job.triggered) return;

        job.triggered = true;
        emit SettlementTickFired(tsMillis, market, settleAssetId);

        address pullerAddr = _pullers[settleAssetId];
        if (pullerAddr == address(0)) {
            emit SettlementPullSkipped(tsMillis, market, 1);
            return;
        }

        IBrimdexFeedAgentPuller(pullerAddr).pullForSettlement(uint64(tsMillis / 1000), market);
    }

    function _launchPullMillisKey(address vault) private view returns (uint256) {
        return (uint256(block.timestamp) + 2) * 1000 + (uint256(uint160(vault)) % SCHEDULE_JITTER_MOD);
    }

    function _settlementMillisKey(address market, uint256 expiryTimestamp)
        private
        pure
        returns (uint256)
    {
        return expiryTimestamp * 1000
            + (uint256(uint160(market)) % SCHEDULE_JITTER_MOD) + COMPLETION_MILLIS_OFFSET;
    }

    function _uniqueAmong(uint256 baseMillis) private view returns (uint256 millis) {
        millis = baseMillis;
        uint256 minAllowed = (uint256(block.timestamp) + 1) * 1000 + 1;
        if (millis < minAllowed) {
            millis = minAllowed;
        }
        while (launchPullJobsByScheduleMillis[millis].vault != address(0) || jobsByScheduleMillis[millis].market != address(0)) {
            unchecked {
                ++millis;
            }
        }
    }

    function _lookupLaunchPull(uint256 tsMillis)
        private
        view
        returns (address vault, uint8 assetId, uint256 mapKey)
    {
        LaunchPullJob storage direct = launchPullJobsByScheduleMillis[tsMillis];
        if (direct.vault != address(0)) {
            return (direct.vault, direct.assetId, tsMillis);
        }
        uint256 centerSec = tsMillis / 1000;
        uint256 startSec = centerSec > 2 ? centerSec - 2 : 0;
        uint256 endSec = centerSec + 2;
        for (uint256 fs = startSec; fs <= endSec; ++fs) {
            uint256 base = fs * 1000;
            for (uint256 j = 0; j < SCHEDULE_JITTER_MOD; ++j) {
                uint256 key = base + j;
                LaunchPullJob storage job = launchPullJobsByScheduleMillis[key];
                if (job.vault != address(0)) {
                    return (job.vault, job.assetId, key);
                }
            }
        }
        return (address(0), 0, 0);
    }

    function _lookupSettlement(uint256 tsMillis)
        private
        view
        returns (address market, uint8 assetId, uint256 mapKey)
    {
        SettlementJob storage direct = jobsByScheduleMillis[tsMillis];
        if (direct.market != address(0)) {
            return (direct.market, direct.assetId, tsMillis);
        }
        uint256 centerSec = tsMillis / 1000;
        uint256 startSec = centerSec > 2 ? centerSec - 2 : 0;
        uint256 endSec = centerSec + 2;
        for (uint256 fs = startSec; fs <= endSec; ++fs) {
            uint256 base = fs * 1000;
            for (uint256 j = 0; j < SCHEDULE_JITTER_MOD; ++j) {
                uint256 key = base + j + COMPLETION_MILLIS_OFFSET;
                SettlementJob storage job = jobsByScheduleMillis[key];
                if (job.market != address(0)) {
                    return (job.market, job.assetId, key);
                }
            }
        }
        return (address(0), 0, 0);
    }

    function withdrawNative(address payable to, uint256 amount) external {
        if (msg.sender != trustedBinder) revert Unauthorized();
        if (to == address(0)) revert BadConfig();
        if (amount > address(this).balance) revert BadConfig();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeSendFailed();
        emit NativeWithdrawn(to, amount);
    }

    function withdrawNativeAll(address payable to) external {
        if (msg.sender != trustedBinder) revert Unauthorized();
        uint256 amount = address(this).balance;
        if (to == address(0)) revert BadConfig();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeSendFailed();
        emit NativeWithdrawn(to, amount);
    }
}
