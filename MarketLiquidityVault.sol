// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IMarketConfig {
    function marketConfig()
        external
        view
        returns (
            string memory name,
            string memory feedName,
            uint256 lowerBound,
            uint256 upperBound,
            uint256 expiryTimestamp,
            uint256 creationTimestamp,
            uint256 startPrice,
            bool initialized,
            bool settled
        );
}

/// @title MarketLiquidityVault
/// @notice Per-market LP vault. Open for deposits before AND during active epoch.
///         Uses NAV-based share pricing (vault USDC + deployed principal).
///         Correctly harvests pending fees on re-deposit (fixes lost-fee bug).
///         Single exit() after settlement pays accumulated fees + pro-rata principal.
contract MarketLiquidityVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = 1e18;

    IERC20 public immutable collateralToken;
    address public immutable market;
    address public immutable factory;
    uint256 public immutable targetSeed;

    bool public seedFinalized;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    uint256 public accRewardPerShare;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public pendingFeeCredit;

    uint256 public principalBalance;
    uint256 public totalDeployed;

    // ── Custom errors ────────────────────────────────────────────────────────
    error Unauthorized();
    error ZeroAddress();
    error InvalidAmount();
    error NavZero();
    error ZeroShares();
    error AlreadyFinalized();
    error InsufficientBalance();
    error NoLPs();
    error NotLive();
    error NotSettled();
    error NoShares();

    event Deposited(address indexed user, uint256 usdcIn, uint256 sharesMinted);
    event SeedPulled(uint256 usdcToMarket, uint256 totalShares_);
    event SeedFeeReceived(uint256 amount);
    event PrincipalReceived(uint256 amount);
    event Exit(address indexed user, uint256 feesUsdc, uint256 principalUsdc, uint256 sharesBurned);

    constructor(address _market, address _collateralToken, address _factory, uint256 _targetSeed) {
        if (_market == address(0) || _collateralToken == address(0) || _factory == address(0)) revert ZeroAddress();
        if (_targetSeed == 0) revert InvalidAmount();
        market = _market;
        collateralToken = IERC20(_collateralToken);
        factory = _factory;
        targetSeed = _targetSeed;
    }

    function totalNAV() public view returns (uint256) {
        return collateralToken.balanceOf(address(this)) + totalDeployed;
    }

    function pendingFees(address user) public view returns (uint256) {
        uint256 s = sharesOf[user];
        uint256 live = 0;
        if (s > 0) {
            uint256 accumulated = (s * accRewardPerShare) / PRECISION;
            uint256 debt = rewardDebt[user];
            live = accumulated > debt ? accumulated - debt : 0;
        }
        return live + pendingFeeCredit[user];
    }

    function principalShareUsdc(address user) public view returns (uint256) {
        uint256 s = sharesOf[user];
        if (s == 0 || totalShares == 0) return 0;
        return (s * principalBalance) / totalShares;
    }

    function totalExitUsdc(address user) external view returns (uint256) {
        return pendingFees(user) + principalShareUsdc(user);
    }

    function deposit(uint256 usdcAmount) external nonReentrant {
        _depositFor(msg.sender, usdcAmount, msg.sender);
    }

    function depositFor(address recipient, uint256 usdcAmount, address usdcFrom) external nonReentrant {
        if (msg.sender != factory) revert Unauthorized();
        _depositFor(recipient, usdcAmount, usdcFrom);
    }

    function _depositFor(address recipient, uint256 usdcAmount, address usdcFrom) internal {
        if (usdcAmount == 0) revert InvalidAmount();

        uint256 s0 = sharesOf[recipient];
        if (s0 > 0) {
            uint256 accumulated = (s0 * accRewardPerShare) / PRECISION;
            uint256 debt = rewardDebt[recipient];
            if (accumulated > debt) {
                pendingFeeCredit[recipient] += accumulated - debt;
            }
        }

        uint256 nav = totalNAV();
        collateralToken.safeTransferFrom(usdcFrom, address(this), usdcAmount);

        uint256 mintShares;
        if (totalShares == 0) {
            mintShares = usdcAmount;
        } else {
            if (nav == 0) revert NavZero();
            mintShares = (usdcAmount * totalShares) / nav;
        }
        if (mintShares == 0) revert ZeroShares();

        sharesOf[recipient] += mintShares;
        totalShares += mintShares;
        rewardDebt[recipient] = (sharesOf[recipient] * accRewardPerShare) / PRECISION;

        emit Deposited(recipient, usdcAmount, mintShares);
    }

    function pullSeedToMarket() external nonReentrant {
        if (msg.sender != factory) revert Unauthorized();
        if (seedFinalized) revert AlreadyFinalized();
        if (collateralToken.balanceOf(address(this)) < targetSeed) revert InsufficientBalance();
        if (totalShares == 0) revert NoLPs();

        collateralToken.safeTransfer(market, targetSeed);
        totalDeployed = targetSeed;
        seedFinalized = true;

        emit SeedPulled(targetSeed, totalShares);
    }

    function onSeedFee(uint256 amount) external nonReentrant {
        if (msg.sender != market) revert Unauthorized();
        if (amount == 0) revert InvalidAmount();
        if (!seedFinalized) revert NotLive();
        if (totalShares == 0) return;
        accRewardPerShare += (amount * PRECISION) / totalShares;
        emit SeedFeeReceived(amount);
    }

    function onPrincipalReturned(uint256 amount) external nonReentrant {
        if (msg.sender != market) revert Unauthorized();
        if (amount == 0) revert InvalidAmount();
        principalBalance += amount;
        totalDeployed = totalDeployed >= amount ? totalDeployed - amount : 0;
        emit PrincipalReceived(amount);
    }

    function exit() external nonReentrant {
        (,,,,,,,, bool settled) = IMarketConfig(market).marketConfig();
        if (!settled) revert NotSettled();

        uint256 s = sharesOf[msg.sender];
        if (s == 0) revert NoShares();

        uint256 accumulated = (s * accRewardPerShare) / PRECISION;
        uint256 debt = rewardDebt[msg.sender];
        if (accumulated > debt) {
            pendingFeeCredit[msg.sender] += accumulated - debt;
        }

        uint256 feePay = pendingFeeCredit[msg.sender];
        uint256 principalPay = (s * principalBalance) / totalShares;
        uint256 payTotal = feePay + principalPay;

        if (collateralToken.balanceOf(address(this)) < payTotal) revert InsufficientBalance();

        principalBalance -= principalPay;
        totalShares -= s;
        sharesOf[msg.sender] = 0;
        rewardDebt[msg.sender] = 0;
        pendingFeeCredit[msg.sender] = 0;

        if (payTotal > 0) collateralToken.safeTransfer(msg.sender, payTotal);

        emit Exit(msg.sender, feePay, principalPay, s);
    }
}
