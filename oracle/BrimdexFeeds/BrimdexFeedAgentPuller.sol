// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAgentRequester, IJsonApiAgent, Request, Response, ResponseStatus} from "../interfaces/ISomniaAgents.sol";
import {BrimdexFeedAssets} from "./BrimdexFeedAssets.sol";
import {IBrimdexFeedsSet} from "./IBrimdexFeedsSet.sol";
import {IBrimdexLaunchVault} from "../../interfaces/IBrimdexLaunchVault.sol";
import {IBrimdexMarketSettlement} from "./IBrimdexMarketSettlement.sol";
import {IBrimdexFeedAgentPuller} from "./IBrimdexFeedAgentPuller.sol";

/// @title BrimdexFeedAgentPuller
/// @notice DIA agent on pull coordinator tick; `completeLaunch` on open coordinator tick; settlement → `resolve`.
contract BrimdexFeedAgentPuller is IBrimdexFeedAgentPuller {
    enum PullKind {
        None,
        Launch,
        Settlement
    }

    IAgentRequester private constant PLATFORM =
        IAgentRequester(0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776);

    uint256 private constant JSON_API_AGENT_ID = 13174292974160097713;

    /// @dev Somnia agent callback budget ≈ deposit / gasPrice (~37M gas @ 6 gwei). Was 0.12 STT (~20M); deploy needs >17M CREATE alone.
    uint256 public constant MIN_AGENT_NATIVE_WEI = 220_000_000_000_000_000;

    IBrimdexFeedsSet public immutable feeds;
    uint8 public immutable assetId;
    address public immutable trustedBinder;

    address public pullCoordinator;
    address public openCoordinator;
    uint256 private _pendingRequestId;
    PullKind private _pendingKind;
    address private _pendingTarget;
    mapping(address => uint256) private _launchRequestIdByVault;

    event CoordinatorsBound(address indexed pullCoordinator, address indexed openCoordinator);
    event AgentRequestCreated(uint64 indexed tick, uint256 indexed requestId, uint8 indexed assetId, PullKind kind, string diaKey);
    event AgentPriceReceived(uint256 indexed requestId, string diaKey, uint128 price, uint128 timestamp);
    event AgentRequestFailed(uint256 indexed requestId, string diaKey, ResponseStatus status);
    event AgentRequestSkipped(uint256 requiredWei, uint256 balance, uint8 reason);
    event VaultOpenedAfterPull(address indexed vault, uint256 indexed requestId);
    event MarketResolvedAfterPull(address indexed market, uint256 indexed requestId);

    error Unauthorized();
    error OnlyPlatform();
    error UnknownAgentRequest();
    error BadConfig();
    error NativeSendFailed();

    event NativeWithdrawn(address indexed to, uint256 amount);

    constructor(address feeds_, uint8 assetId_, address trustedBinder_) {
        if (feeds_ == address(0) || trustedBinder_ == address(0)) revert BadConfig();
        if (assetId_ >= BrimdexFeedAssets.ASSET_COUNT) revert BadConfig();
        feeds = IBrimdexFeedsSet(feeds_);
        assetId = assetId_;
        trustedBinder = trustedBinder_;
    }

    receive() external payable {}

    function bindCoordinators(address pullCoordinator_, address openCoordinator_) public {
        if (msg.sender != trustedBinder) revert Unauthorized();
        if (pullCoordinator_ == address(0) || openCoordinator_ == address(0)) revert BadConfig();
        if (pullCoordinator != address(0) || openCoordinator != address(0)) revert BadConfig();
        pullCoordinator = pullCoordinator_;
        openCoordinator = openCoordinator_;
        emit CoordinatorsBound(pullCoordinator_, openCoordinator_);
    }

    /// @dev Legacy single-coordinator bind (pull + open same address).
    function bindCoordinator(address coordinator_) external {
        bindCoordinators(coordinator_, coordinator_);
    }

    function pullForLaunch(address vault) external {
        if (msg.sender != pullCoordinator) revert Unauthorized();
        _startAgent(PullKind.Launch, vault, 0);
    }

    function pullForSettlement(uint64 tick, address market) external {
        if (msg.sender != pullCoordinator) revert Unauthorized();
        _startAgent(PullKind.Settlement, market, tick);
    }

    /// @inheritdoc IBrimdexFeedAgentPuller
    function completeLaunch(address vault) external {
        if (msg.sender != openCoordinator) revert Unauthorized();
        if (vault == address(0)) revert BadConfig();
        if (IBrimdexLaunchVault(vault).phase() != 1) return;

        uint256 requestId = _launchRequestIdByVault[vault];
        IBrimdexLaunchVault(vault).finishOpen();
        emit VaultOpenedAfterPull(vault, requestId);
        delete _launchRequestIdByVault[vault];
    }

    function _startAgent(PullKind kind, address target, uint64 tick) private {
        if (target == address(0)) revert BadConfig();

        uint256 per = singleRequestWei();
        uint256 bal = address(this).balance;
        if (bal < per) {
            emit AgentRequestSkipped(per, bal, 1);
            return;
        }
        if (_pendingRequestId != 0) {
            emit AgentRequestSkipped(per, bal, 2);
            return;
        }

        string memory url = BrimdexFeedAssets.feedUrl(assetId);
        bytes memory payload = abi.encodeWithSelector(
            IJsonApiAgent.fetchUint.selector,
            url,
            string("Price"),
            uint8(8)
        );

        uint256 requestId = PLATFORM.createRequest{value: per}(
            JSON_API_AGENT_ID,
            address(this),
            this.handleResponse.selector,
            payload
        );

        _pendingRequestId = requestId;
        _pendingKind = kind;
        _pendingTarget = target;
        emit AgentRequestCreated(tick, requestId, assetId, kind, BrimdexFeedAssets.diaKeyOf(assetId));
    }

    function handleResponse(
        uint256 requestId,
        Response[] memory responses,
        ResponseStatus status,
        Request memory /* details */
    ) external {
        if (msg.sender != address(PLATFORM)) revert OnlyPlatform();
        if (_pendingRequestId != requestId) revert UnknownAgentRequest();

        PullKind kind = _pendingKind;
        address target = _pendingTarget;
        _pendingRequestId = 0;
        _pendingKind = PullKind.None;
        _pendingTarget = address(0);

        string memory diaKey = BrimdexFeedAssets.diaKeyOf(assetId);

        if (status == ResponseStatus.Success && responses.length > 0) {
            uint256 p = abi.decode(responses[0].result, (uint256));
            if (p > type(uint128).max) {
                emit AgentRequestFailed(requestId, diaKey, ResponseStatus.Failed);
                return;
            }
            uint128 ts = uint128(block.timestamp);
            feeds.setFromPuller(diaKey, uint128(p), ts);
            emit AgentPriceReceived(requestId, diaKey, uint128(p), ts);

            if (kind == PullKind.Launch && target != address(0)) {
                _launchRequestIdByVault[target] = requestId;
            } else if (kind == PullKind.Settlement && target != address(0)) {
                (bool resolved, ) = target.call(
                    abi.encodeWithSelector(IBrimdexMarketSettlement.resolve.selector)
                );
                if (resolved) {
                    emit MarketResolvedAfterPull(target, requestId);
                }
            }
        } else {
            emit AgentRequestFailed(requestId, diaKey, status);
        }
    }

    function singleRequestWei() public view returns (uint256) {
        uint256 d = PLATFORM.getRequestDeposit();
        return d > MIN_AGENT_NATIVE_WEI ? d : MIN_AGENT_NATIVE_WEI;
    }

    function withdrawNative(address payable to, uint256 amount) external {
        if (msg.sender != trustedBinder) revert Unauthorized();
        _withdrawNative(to, amount);
    }

    function withdrawNativeAll(address payable to) external {
        if (msg.sender != trustedBinder) revert Unauthorized();
        _withdrawNative(to, address(this).balance);
    }

    function _withdrawNative(address payable to, uint256 amount) private {
        if (to == address(0)) revert BadConfig();
        if (amount > address(this).balance) revert BadConfig();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeSendFailed();
        emit NativeWithdrawn(to, amount);
    }
}
