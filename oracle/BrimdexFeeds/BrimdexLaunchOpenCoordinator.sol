// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SomniaEventHandler} from "@somnia-chain/reactivity-contracts/contracts/SomniaEventHandler.sol";
import {SomniaExtensions} from "@somnia-chain/reactivity-contracts/contracts/interfaces/SomniaExtensions.sol";
import {ISomniaReactivityPrecompile} from "@somnia-chain/reactivity-contracts/contracts/interfaces/ISomniaReactivityPrecompile.sol";

import {BrimdexFeedAssets} from "./BrimdexFeedAssets.sol";
import {IBrimdexFeedAgentPuller} from "./IBrimdexFeedAgentPuller.sol";
import {IBrimdexLaunchVault} from "../../interfaces/IBrimdexLaunchVault.sol";

/// @title BrimdexLaunchOpenCoordinator
/// @notice Dedicated Somnia handler for the +30s `finishOpen` tick (separate contract from pull coordinator).
contract BrimdexLaunchOpenCoordinator is SomniaEventHandler {
    struct LaunchJob {
        address vault;
        uint8 assetId;
        bool triggered;
    }

    uint64 internal constant LAUNCH_COMPLETION_GAS_LIMIT = 60_000_000;
    uint256 private constant SCHEDULE_JITTER_MOD = 997;
    uint256 private constant COMPLETION_MILLIS_OFFSET = 500;
    uint256 private constant LAUNCH_COMPLETION_DELAY_SEC = 30;

    address public immutable trustedBinder;
    address public immutable launchPullCoordinator;

    address[16] private _pullers;
    bool public pullersRegistered;

    mapping(uint256 => LaunchJob) public launchJobsByScheduleMillis;
    mapping(address => uint256) public scheduleMillisByVault;

    event PullersRegistered(address[16] pullers);
    event LaunchCompletionScheduled(
        address indexed vault,
        uint8 assetId,
        uint256 scheduleMillis,
        uint256 subscriptionId
    );
    event LaunchTickFired(uint256 indexed scheduleMillis, address indexed vault, uint8 assetId);
    event LaunchCompletionSkipped(uint256 indexed scheduleMillis, address indexed vault, uint8 reason);
    event LaunchCompletionForced(address indexed vault, uint8 assetId);

    error Unauthorized();
    error BadConfig();
    error PullersAlreadyRegistered();
    error AlreadyScheduled();
    error NativeSendFailed();

    event NativeWithdrawn(address indexed to, uint256 amount);

    constructor(address trustedBinder_, address launchPullCoordinator_) payable {
        if (trustedBinder_ == address(0) || launchPullCoordinator_ == address(0)) revert BadConfig();
        trustedBinder = trustedBinder_;
        launchPullCoordinator = launchPullCoordinator_;
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

    /// @notice Called by the pull coordinator at notional (separate handler address for Somnia Schedule).
    function scheduleLaunchAtNotional(address vault, uint8 assetId) external {
        if (!pullersRegistered) revert BadConfig();
        if (msg.sender != launchPullCoordinator) revert Unauthorized();
        if (vault == address(0)) revert BadConfig();
        if (assetId >= BrimdexFeedAssets.ASSET_COUNT) revert BadConfig();
        if (IBrimdexLaunchVault(vault).launchOpenCoordinator() != address(this)) revert Unauthorized();
        if (IBrimdexLaunchVault(vault).assetId() != assetId) revert Unauthorized();
        if (scheduleMillisByVault[vault] != 0) return;

        _scheduleLaunchCompletion(vault, assetId);
    }

    /// @notice Puller recovery — schedules open tick if not already scheduled at notional.
    function scheduleLaunchCompletion(address vault) external {
        if (!pullersRegistered) revert BadConfig();
        if (vault == address(0)) revert BadConfig();
        if (IBrimdexLaunchVault(vault).launchOpenCoordinator() != address(this)) revert Unauthorized();

        uint8 assetId = IBrimdexLaunchVault(vault).assetId();
        if (assetId >= BrimdexFeedAssets.ASSET_COUNT) revert BadConfig();
        if (msg.sender != _pullers[assetId]) revert Unauthorized();
        if (scheduleMillisByVault[vault] != 0) revert AlreadyScheduled();

        _scheduleLaunchCompletion(vault, assetId);
    }

    function _scheduleLaunchCompletion(address vault, uint8 assetId) private {
        uint256 openMillis = _uniqueAmong(_launchCompletionMillisKey(vault));

        launchJobsByScheduleMillis[openMillis] = LaunchJob({
            vault: vault,
            assetId: assetId,
            triggered: false
        });
        scheduleMillisByVault[vault] = openMillis;

        SomniaExtensions.SubscriptionOptions memory opts = SomniaExtensions.SubscriptionOptions({
            priorityFeePerGas: SomniaExtensions.DEFAULT_PRIORITY_FEE_PER_GAS,
            maxFeePerGas: SomniaExtensions.DEFAULT_MAX_FEE_PER_GAS,
            gasLimit: LAUNCH_COMPLETION_GAS_LIMIT
        });

        uint256 subId = SomniaExtensions.scheduleSubscriptionAtTimestamp(address(this), openMillis, opts);

        emit LaunchCompletionScheduled(vault, assetId, openMillis, subId);
    }

    function _onEvent(address emitter, bytes32[] calldata eventTopics, bytes calldata data) internal override {
        emitter;
        data;
        if (eventTopics.length < 2) return;
        if (eventTopics[0] != ISomniaReactivityPrecompile.Schedule.selector) return;

        uint256 tsMillis = uint256(eventTopics[1]);

        (address launchVault, uint8 launchAssetId, uint256 launchKey) = _lookupLaunchCompletion(tsMillis);
        if (launchVault == address(0)) return;

        LaunchJob storage launchJob = launchJobsByScheduleMillis[launchKey];
        if (launchJob.triggered) return;

        launchJob.triggered = true;
        emit LaunchTickFired(tsMillis, launchVault, launchAssetId);

        address launchPuller = _pullers[launchAssetId];
        if (launchPuller == address(0)) {
            emit LaunchCompletionSkipped(tsMillis, launchVault, 1);
            return;
        }

        IBrimdexFeedAgentPuller(launchPuller).completeLaunch(launchVault);
    }

    function _launchCompletionMillisKey(address vault) private view returns (uint256) {
        return (uint256(block.timestamp) + LAUNCH_COMPLETION_DELAY_SEC) * 1000
            + (uint256(uint160(vault)) % SCHEDULE_JITTER_MOD) + COMPLETION_MILLIS_OFFSET;
    }

    function _uniqueAmong(uint256 baseMillis) private view returns (uint256 millis) {
        millis = baseMillis;
        uint256 minAllowed = (uint256(block.timestamp) + 1) * 1000 + 1;
        if (millis < minAllowed) {
            millis = minAllowed;
        }
        while (launchJobsByScheduleMillis[millis].vault != address(0)) {
            unchecked {
                ++millis;
            }
        }
    }

    function _lookupLaunchCompletion(uint256 tsMillis)
        private
        view
        returns (address vault, uint8 assetId, uint256 mapKey)
    {
        LaunchJob storage direct = launchJobsByScheduleMillis[tsMillis];
        if (direct.vault != address(0)) {
            return (direct.vault, direct.assetId, tsMillis);
        }
        uint256 centerSec = tsMillis / 1000;
        uint256 startSec = centerSec > 2 ? centerSec - 2 : 0;
        uint256 endSec = centerSec + 2;
        for (uint256 fs = startSec; fs <= endSec; ++fs) {
            uint256 base = fs * 1000;
            for (uint256 j = 0; j < SCHEDULE_JITTER_MOD; ++j) {
                uint256 key = base + j + COMPLETION_MILLIS_OFFSET;
                LaunchJob storage job = launchJobsByScheduleMillis[key];
                if (job.vault != address(0)) {
                    return (job.vault, job.assetId, key);
                }
            }
        }
        return (address(0), 0, 0);
    }

    function forceCompleteLaunch(address vault) external {
        if (msg.sender != trustedBinder) revert Unauthorized();
        if (vault == address(0)) revert BadConfig();
        if (!pullersRegistered) revert BadConfig();
        if (IBrimdexLaunchVault(vault).launchOpenCoordinator() != address(this)) revert Unauthorized();

        uint8 assetId = IBrimdexLaunchVault(vault).assetId();
        if (assetId >= BrimdexFeedAssets.ASSET_COUNT) revert BadConfig();

        address launchPuller = _pullers[assetId];
        if (launchPuller == address(0)) revert BadConfig();

        IBrimdexFeedAgentPuller(launchPuller).completeLaunch(vault);
        emit LaunchCompletionForced(vault, assetId);
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
