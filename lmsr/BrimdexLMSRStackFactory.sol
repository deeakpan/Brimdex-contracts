// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BrimdexConditionalTokens} from "../ct/BrimdexConditionalTokens.sol";
import {LMSRMarketMaker} from "./LMSRMarketMaker.sol";
import {BrimdexLMSRRouter} from "./BrimdexLMSRRouter.sol";
import {Whitelist} from "./Whitelist.sol";
import {BrimdexAssetRegistry} from "../ct/BrimdexAssetRegistry.sol";
import {BrimdexStackLaunchVault} from "../raise/BrimdexStackLaunchVault.sol";
import {IBrimdexFeeConfig} from "./MarketMaker.sol";

/// @notice Optional hook on BDXStaking: factory registers each new LMSR so it may call `notifyRewardAmount`.
interface IBrimdexStakingRewards {
    function authorizeRewardNotifier(address market) external;
}

/// @title BrimdexLMSRStackFactory
/// @notice Deploys the CTF + LMSR router once; each `openMarket` registers metadata, deploys an LMSR, pulls `funding` from `msg.sender`, and bootstraps to Running.
/// @dev Collateral is fixed at construction (`collateralAsset`). assetKey is the condition identifier — no separate questionId.
contract BrimdexLMSRStackFactory is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Sentinel: `openMarket` caller did not record an adaptive launch (legacy / direct opens).
    uint8 public constant LAUNCH_SNAPSHOT_NONE = 255;

    IERC20 public immutable collateralAsset;

    BrimdexConditionalTokens public immutable ctf;
    BrimdexLMSRRouter public immutable lmsrRouter;
    BrimdexAssetRegistry public immutable assetRegistry;

    /// @notice Fee configuration contract shared across all markets.
    IBrimdexFeeConfig public feeConfig;

    event FeeConfigUpdated(address indexed feeConfig);

    event MarketOpened(
        address indexed marketOwner,
        address indexed market,
        bytes32 indexed assetKey,
        address payer,
        bytes32 conditionId,
        uint256 lowerBound,
        uint256 upperBound,
        uint256 expiryTimestamp,
        uint256 funding,
        uint256 launchOracleSpot6,
        uint16 launchBandBps,
        uint256 launchHorizonSeconds
    );

    event VaultCreated(address indexed vault, bytes32 indexed assetKey);

    /// @notice Only authorized vault contracts may call openMarket.
    mapping(address => bool) public authorizedVaults;

    /// @notice Operator address — can authorize vaults without multisig. Set by owner (multisig) only.
    address public operator;

    /// @notice Pull + settlement coordinator (`BrimdexReactivityCoordinator`).
    address public settlementCoordinator;
    /// @notice Open tick coordinator (`BrimdexLaunchOpenCoordinator`).
    address public launchOpenCoordinator;

    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event SettlementCoordinatorUpdated(address indexed coordinator);
    event LaunchOpenCoordinatorUpdated(address indexed openCoordinator);

    modifier onlyAuthorizedVault() {
        require(authorizedVaults[msg.sender], "BrimdexLMSRStackFactory: not authorized vault");
        _;
    }

    modifier onlyOperatorOrOwner() {
        require(msg.sender == operator || msg.sender == owner(), "BrimdexLMSRStackFactory: not operator or owner");
        _;
    }

    /// @param assetRegistry_ Pre-deployed registry (keeps factory initcode under chain limits).
    /// @param ctf_ Pre-deployed CTF; call `ctf.setAuthorizedPreparer(address(this))` after factory deploy.
    constructor(
        IERC20 collateralAsset_,
        address feeConfig_,
        BrimdexAssetRegistry assetRegistry_,
        BrimdexConditionalTokens ctf_,
        BrimdexLMSRRouter lmsrRouter_
    ) Ownable(msg.sender) {
        require(address(collateralAsset_) != address(0), "BrimdexLMSRStackFactory: asset");
        require(feeConfig_ != address(0), "BrimdexLMSRStackFactory: feeConfig");
        require(address(assetRegistry_) != address(0), "BrimdexLMSRStackFactory: registry");
        require(address(ctf_) != address(0), "BrimdexLMSRStackFactory: ctf");
        require(address(lmsrRouter_) != address(0), "BrimdexLMSRStackFactory: router");
        collateralAsset = collateralAsset_;
        feeConfig = IBrimdexFeeConfig(feeConfig_);
        assetRegistry = assetRegistry_;
        ctf = ctf_;
        lmsrRouter = lmsrRouter_;
    }

    /// @notice Owner-only (multisig): set the operator address.
    function setOperator(address op) external onlyOwner {
        emit OperatorUpdated(operator, op);
        operator = op;
    }

    /// @notice Owner: wire pull coordinator used by `createLaunchVault` (`reactivityCoordinator`).
    function setSettlementCoordinator(address coordinator_) external onlyOwner {
        settlementCoordinator = coordinator_;
        emit SettlementCoordinatorUpdated(coordinator_);
    }

    /// @notice Owner: wire open coordinator used by `createLaunchVault` (`launchOpenCoordinator`).
    function setLaunchOpenCoordinator(address openCoordinator_) external onlyOwner {
        launchOpenCoordinator = openCoordinator_;
        emit LaunchOpenCoordinatorUpdated(openCoordinator_);
    }

    /// @notice Deploy a stack launch vault (authorized) with factory `settlementCoordinator` + `assetId`.
    function createLaunchVault(
        address designatedOwner_,
        bytes32 assetKey_,
        uint16 bandBps_,
        uint256 horizonSeconds_,
        uint64 tradeFeeRate_,
        address tradeGuard_,
        uint256 requiredNotional_,
        uint256 commitmentDeadline_,
        uint8 assetId_
    ) external onlyOperatorOrOwner returns (BrimdexStackLaunchVault vault) {
        require(designatedOwner_ != address(0), "zero owner");
        require(assetKey_ != bytes32(0), "zero assetKey");
        require(requiredNotional_ > 0, "zero notional");
        require(commitmentDeadline_ > block.timestamp, "bad deadline");
        require(assetId_ < 16, "assetId");
        require(horizonSeconds_ >= 5 * 60, "horizon");

        assetRegistry.getFeedKey(assetKey_);

        vault = new BrimdexStackLaunchVault(
            this,
            designatedOwner_,
            assetKey_,
            bandBps_,
            horizonSeconds_,
            tradeFeeRate_,
            tradeGuard_,
            requiredNotional_,
            commitmentDeadline_,
            settlementCoordinator,
            launchOpenCoordinator,
            assetId_
        );

        authorizedVaults[address(vault)] = true;
        emit VaultCreated(address(vault), assetKey_);
    }

    /// @notice Operator or owner: authorize a deployed vault to open markets.
    function authorizeVault(address vault) external onlyOperatorOrOwner {
        require(vault != address(0), "zero vault");
        authorizedVaults[vault] = true;
        emit VaultCreated(vault, bytes32(0));
    }

    /// @notice Owner-only (multisig): deauthorize a vault.
    function deauthorizeVault(address vault) external onlyOwner {
        authorizedVaults[vault] = false;
    }

    /// @notice Governance / multisig: point new markets at an updated fee config contract.
    function setFeeConfig(IBrimdexFeeConfig feeConfig_) external onlyOwner {
        require(address(feeConfig_) != address(0), "BrimdexLMSRStackFactory: feeConfig");
        feeConfig = feeConfig_;
        emit FeeConfigUpdated(address(feeConfig_));
    }

    function openMarket(
        address marketOwner,
        bytes32 assetKey,
        uint256 lowerBound,
        uint256 upperBound,
        uint256 expiryTimestamp,
        Whitelist whitelist,
        uint256 funding,
        uint256 launchOracleSpot6,
        uint16 launchBandBps,
        uint256 launchHorizonSeconds
    ) external onlyAuthorizedVault returns (LMSRMarketMaker market) {
        require(marketOwner != address(0), "BrimdexLMSRStackFactory: owner");

        bytes32 conditionId = ctf.registerMarket(assetKey, lowerBound, upperBound, expiryTimestamp, msg.sender);
        bytes32[] memory cond = new bytes32[](1);
        cond[0] = conditionId;

        market = new LMSRMarketMaker(
            marketOwner, address(lmsrRouter), address(this), ctf, collateralAsset, cond, feeConfig, whitelist,
            assetKey, lowerBound, upperBound, expiryTimestamp, msg.sender
        );
        ctf.bindMarketMaker(conditionId, address(market));

        address sr = feeConfig.stakingRewards();
        if (sr != address(0)) {
            IBrimdexStakingRewards(sr).authorizeRewardNotifier(address(market));
        }

        collateralAsset.safeTransferFrom(msg.sender, address(market), funding);
        market.completeBootstrap(funding);

        emit MarketOpened(
            marketOwner,
            address(market),
            assetKey,
            msg.sender,
            conditionId,
            lowerBound,
            upperBound,
            expiryTimestamp,
            funding,
            launchOracleSpot6,
            launchBandBps,
            launchHorizonSeconds
        );
    }
}
