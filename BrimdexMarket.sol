// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./BrimdexParimutuelToken.sol";

/// @notice Oracle feed (BrimdexFeeds)
interface IBrimdexFeeds {
    struct PriceData {
        int256 price;
        uint64 timestamp;
        uint80 roundId;
        uint8 decimals;
    }

    function getFeedByName(string memory feedName) external view returns (PriceData memory);
}

interface ILiquidityVault {
    function onSeedFee(uint256 amount) external;
    function onPrincipalReturned(uint256 amount) external;
}

/// @title BrimdexMarket
/// @notice Parimutuel betting market for crypto price ranges
/// @dev Protocol fee: 2% per trade (180 bps treasury, 20 bps to per-market liquidity vault). No settlement skim on trader pool.
contract BrimdexMarket is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct MarketConfig {
        string name;
        string feedName;
        uint256 lowerBound;
        uint256 upperBound;
        uint256 expiryTimestamp;
        uint256 creationTimestamp;
        uint256 startPrice;
        bool initialized;
        bool settled;
    }

    MarketConfig public marketConfig;

    IERC20 public immutable collateralToken;
    BrimdexParimutuelToken public immutable boundToken;
    BrimdexParimutuelToken public immutable breakToken;
    address public immutable factory;
    IBrimdexFeeds public immutable feedsContract;
    address public immutable treasury;
    address public liquidityVault;
    bool public liquidityVaultSet;

    uint256 public seedPrincipal;
    uint256 public seedFeeAccrued;

    uint256 public boundPool;
    uint256 public breakPool;

    uint256 public redemptionRate;
    bool public boundWins;
    uint256 public resolvedPrice;
    uint256 public settlementTimestamp;

    uint256 public constant MAX_ORACLE_STALENESS = 300;
    uint256 public constant TRADE_FEE_BPS = 200;
    uint256 public constant TRADE_FEE_TREASURY_BPS = 180;
    uint256 public constant TRADE_FEE_SEED_BPS = 20;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant EMERGENCY_DELAY = 12 hours;

    // ── Custom errors ────────────────────────────────────────────────────────
    error Unauthorized();
    error ZeroAddress();
    error AlreadySet();
    error NotInitialized();
    error AlreadyInitialized();
    error AlreadySettled();
    error NotSettled();
    error NotExpired();
    error MarketExpired();
    error InvalidExpiry();
    error InvalidBand();
    error InvalidName();
    error InvalidFeed();
    error InvalidPrice();
    error InvalidBounds();
    error InvalidAmount();
    error ZeroTokens();
    error SlippageExceeded();
    error EmergencyDelayNotElapsed();
    error NoSupply();
    error NoTraderFunds();
    error ZeroRefund();
    error SeedExceedsPool();
    error NoRedemptionRate();
    error ZeroPayout();
    error WrongSide();
    error InsufficientBalance();
    error TradeTooSmall();
    error InsufficientSeedLiquidity(uint256 required, uint256 actual);

    event MarketInitialized(string name, uint256 lowerBound, uint256 upperBound, uint256 expiryTimestamp);
    event TradeFeesTaken(address indexed buyer, uint256 grossUsdc, uint256 netToPool, uint256 treasuryFee, uint256 seedFee);
    event BoundPurchased(address indexed buyer, address recipient, uint256 grossUsdc, uint256 tokens, uint256 price);
    event BreakPurchased(address indexed buyer, address recipient, uint256 grossUsdc, uint256 tokens, uint256 price);
    event MarketSettled(bool boundWins, uint256 totalPool, uint256 winnings, uint256 resolvedPrice);
    event TokensRedeemed(address indexed user, uint256 tokens, uint256 payout);
    event EmergencyWithdrawal(address indexed user, bool isBound, uint256 tokens, uint256 refund);
    event SeedPrincipalReturned(address indexed vault, uint256 amount);
    event SeedFeesSent(address indexed vault, uint256 amount);

    constructor(
        address _collateralToken,
        address _boundToken,
        address _breakToken,
        address _owner,
        address _factory,
        address _feedsContract,
        address _treasury
    ) Ownable(_owner) {
        if (_treasury == address(0)) revert ZeroAddress();
        collateralToken = IERC20(_collateralToken);
        boundToken = BrimdexParimutuelToken(_boundToken);
        breakToken = BrimdexParimutuelToken(_breakToken);
        factory = _factory;
        feedsContract = IBrimdexFeeds(_feedsContract);
        treasury = _treasury;
    }

    function setLiquidityVault(address _vault) external {
        if (msg.sender != factory) revert Unauthorized();
        if (liquidityVaultSet) revert AlreadySet();
        if (_vault == address(0)) revert ZeroAddress();
        liquidityVault = _vault;
        liquidityVaultSet = true;
    }

    function netUsdcToPool(uint256 grossUsdc) public pure returns (uint256) {
        uint256 tFee = (grossUsdc * TRADE_FEE_TREASURY_BPS) / BPS_DENOMINATOR;
        uint256 sFee = (grossUsdc * TRADE_FEE_SEED_BPS) / BPS_DENOMINATOR;
        return grossUsdc - tFee - sFee;
    }

    function _requireOraclePriceFresh(IBrimdexFeeds.PriceData memory priceData) internal view {
        if (priceData.price <= 0) revert InvalidPrice();
        if (priceData.timestamp == 0) revert InvalidPrice();
        uint256 ts = uint256(priceData.timestamp);
        if (block.timestamp < ts) revert InvalidPrice();
        if (block.timestamp - ts > MAX_ORACLE_STALENESS) revert InvalidPrice();
    }

    function initialize(
        string memory _name,
        string memory _feedName,
        uint256 _bandPercent,
        uint256 _expiryTimestamp,
        uint256 _seedPrincipal
    ) external {
        if (msg.sender != factory) revert Unauthorized();
        if (!liquidityVaultSet) revert AlreadySet();
        if (marketConfig.initialized) revert AlreadyInitialized();
        if (_expiryTimestamp <= block.timestamp) revert InvalidExpiry();
        if (_bandPercent == 0 || _bandPercent > 10000) revert InvalidBand();
        if (bytes(_name).length == 0 || bytes(_name).length > 8) revert InvalidName();
        if (bytes(_feedName).length == 0) revert InvalidFeed();

        IBrimdexFeeds.PriceData memory priceData = feedsContract.getFeedByName(_feedName);
        _requireOraclePriceFresh(priceData);

        uint256 _startPrice;
        if (priceData.decimals >= 6) {
            _startPrice = uint256(priceData.price) / (10 ** (priceData.decimals - 6));
        } else {
            _startPrice = uint256(priceData.price) * (10 ** (6 - priceData.decimals));
        }
        if (_startPrice == 0) revert InvalidPrice();

        uint256 delta = (_startPrice * _bandPercent) / 10000;
        uint256 _lowerBound = _startPrice - delta;
        uint256 _upperBound = _startPrice + delta;
        if (_lowerBound >= _upperBound) revert InvalidBounds();

        marketConfig = MarketConfig({
            name: _name,
            feedName: _feedName,
            lowerBound: _lowerBound,
            upperBound: _upperBound,
            expiryTimestamp: _expiryTimestamp,
            creationTimestamp: block.timestamp,
            startPrice: _startPrice,
            initialized: true,
            settled: false
        });

        if (_seedPrincipal == 0) revert InvalidAmount();
        seedPrincipal = _seedPrincipal;

        uint256 actual = collateralToken.balanceOf(address(this));
        if (actual < _seedPrincipal) revert InsufficientSeedLiquidity(_seedPrincipal, actual);

        boundPool = _seedPrincipal / 2;
        breakPool = _seedPrincipal / 2;

        emit MarketInitialized(_name, _lowerBound, _upperBound, _expiryTimestamp);
    }

    function _takeTradeFees(address buyer, uint256 grossUsdc) internal returns (uint256 netToPool) {
        uint256 tFee = (grossUsdc * TRADE_FEE_TREASURY_BPS) / BPS_DENOMINATOR;
        uint256 sFee = (grossUsdc * TRADE_FEE_SEED_BPS) / BPS_DENOMINATOR;
        netToPool = grossUsdc - tFee - sFee;
        if (netToPool == 0) revert TradeTooSmall();

        if (tFee > 0) collateralToken.safeTransfer(treasury, tFee);
        if (liquidityVault != address(0) && sFee > 0) {
            collateralToken.safeTransfer(liquidityVault, sFee);
            ILiquidityVault(liquidityVault).onSeedFee(sFee);
        } else if (sFee > 0) {
            seedFeeAccrued += sFee;
        }

        emit TradeFeesTaken(buyer, grossUsdc, netToPool, tFee, sFee);
    }

    function buyBound(uint256 amount, address recipient, uint256 minTokensOut) external nonReentrant {
        if (!marketConfig.initialized) revert NotInitialized();
        if (marketConfig.settled) revert AlreadySettled();
        if (block.timestamp >= marketConfig.expiryTimestamp) revert MarketExpired();
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert ZeroAddress();

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 netToPool = _takeTradeFees(msg.sender, amount);

        uint256 totalPool = boundPool + breakPool;
        uint256 price = (boundPool * 1e18) / totalPool;
        uint256 tokens = (netToPool * 1e18) / price;
        if (tokens == 0) revert ZeroTokens();
        if (tokens < minTokensOut) revert SlippageExceeded();

        boundToken.mint(recipient, tokens);
        boundPool += netToPool;

        emit BoundPurchased(msg.sender, recipient, amount, tokens, price);
    }

    function buyBreak(uint256 amount, address recipient, uint256 minTokensOut) external nonReentrant {
        if (!marketConfig.initialized) revert NotInitialized();
        if (marketConfig.settled) revert AlreadySettled();
        if (block.timestamp >= marketConfig.expiryTimestamp) revert MarketExpired();
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert ZeroAddress();

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 netToPool = _takeTradeFees(msg.sender, amount);

        uint256 totalPool = boundPool + breakPool;
        uint256 price = (breakPool * 1e18) / totalPool;
        uint256 tokens = (netToPool * 1e18) / price;
        if (tokens == 0) revert ZeroTokens();
        if (tokens < minTokensOut) revert SlippageExceeded();

        breakToken.mint(recipient, tokens);
        breakPool += netToPool;

        emit BreakPurchased(msg.sender, recipient, amount, tokens, price);
    }

    function settle() external nonReentrant {
        if (!marketConfig.initialized) revert NotInitialized();
        if (marketConfig.settled) revert AlreadySettled();
        if (block.timestamp < marketConfig.expiryTimestamp) revert NotExpired();

        IBrimdexFeeds.PriceData memory priceData = feedsContract.getFeedByName(marketConfig.feedName);
        _requireOraclePriceFresh(priceData);

        uint256 finalPrice;
        if (priceData.decimals >= 6) {
            finalPrice = uint256(priceData.price) / (10 ** (priceData.decimals - 6));
        } else {
            finalPrice = uint256(priceData.price) * (10 ** (6 - priceData.decimals));
        }
        if (finalPrice == 0) revert InvalidPrice();

        _settleMarket(finalPrice);
    }

    function emergencyWithdraw(bool isBound, uint256 amount) external nonReentrant {
        if (!marketConfig.initialized) revert NotInitialized();
        if (marketConfig.settled) revert AlreadySettled();
        if (block.timestamp <= marketConfig.expiryTimestamp + EMERGENCY_DELAY) revert EmergencyDelayNotElapsed();
        if (amount == 0) revert InvalidAmount();

        uint256 seedSide = seedPrincipal / 2;

        if (isBound) {
            uint256 pool = boundPool;
            uint256 supply = boundToken.totalSupply();
            if (supply == 0) revert NoSupply();
            if (pool <= seedSide) revert NoTraderFunds();
            uint256 traderPool = pool - seedSide;
            uint256 refund = (amount * traderPool) / supply;
            if (refund == 0) revert ZeroRefund();
            boundToken.burnFrom(msg.sender, amount);
            boundPool -= refund;
            collateralToken.safeTransfer(msg.sender, refund);
            emit EmergencyWithdrawal(msg.sender, true, amount, refund);
        } else {
            uint256 pool = breakPool;
            uint256 supply = breakToken.totalSupply();
            if (supply == 0) revert NoSupply();
            if (pool <= seedSide) revert NoTraderFunds();
            uint256 traderPool = pool - seedSide;
            uint256 refund = (amount * traderPool) / supply;
            if (refund == 0) revert ZeroRefund();
            breakToken.burnFrom(msg.sender, amount);
            breakPool -= refund;
            collateralToken.safeTransfer(msg.sender, refund);
            emit EmergencyWithdrawal(msg.sender, false, amount, refund);
        }
    }

    function _settleMarket(uint256 finalPrice) internal {
        resolvedPrice = finalPrice;
        settlementTimestamp = block.timestamp;

        boundWins = (finalPrice >= marketConfig.lowerBound && finalPrice <= marketConfig.upperBound);
        marketConfig.settled = true;

        uint256 totalPool = boundPool + breakPool;
        if (totalPool < seedPrincipal) revert SeedExceedsPool();
        uint256 traderPool = totalPool - seedPrincipal;
        uint256 totalBoundSupply = boundToken.totalSupply();
        uint256 totalBreakSupply = breakToken.totalSupply();

        bool onlyBoundExists = totalBoundSupply > 0 && totalBreakSupply == 0;
        bool onlyBreakExists = totalBreakSupply > 0 && totalBoundSupply == 0;

        uint256 protocolSkim;
        uint256 winnings;

        if (onlyBoundExists && !boundWins) {
            protocolSkim = traderPool;
        } else if (onlyBreakExists && boundWins) {
            protocolSkim = traderPool;
        } else {
            winnings = traderPool;
            if (boundWins && totalBoundSupply > 0) {
                redemptionRate = (winnings * 1e18) / totalBoundSupply;
            } else if (!boundWins && totalBreakSupply > 0) {
                redemptionRate = (winnings * 1e18) / totalBreakSupply;
            }
        }

        if (protocolSkim > 0) collateralToken.safeTransfer(treasury, protocolSkim);

        emit MarketSettled(boundWins, totalPool, winnings, resolvedPrice);

        if (liquidityVault == address(0)) revert ZeroAddress();

        if (seedFeeAccrued > 0) {
            uint256 sf = seedFeeAccrued;
            seedFeeAccrued = 0;
            collateralToken.safeTransfer(liquidityVault, sf);
            ILiquidityVault(liquidityVault).onSeedFee(sf);
            emit SeedFeesSent(liquidityVault, sf);
        }
        if (seedPrincipal > 0) {
            uint256 sp = seedPrincipal;
            collateralToken.safeTransfer(liquidityVault, sp);
            ILiquidityVault(liquidityVault).onPrincipalReturned(sp);
            emit SeedPrincipalReturned(liquidityVault, sp);
        }
    }

    function redeem(bool isBound, uint256 amount) external nonReentrant {
        if (!marketConfig.settled) revert NotSettled();
        if (redemptionRate == 0) revert NoRedemptionRate();
        if (amount == 0) revert InvalidAmount();

        uint256 payout = (amount * redemptionRate) / 1e18;
        if (payout == 0) revert ZeroPayout();

        if (isBound) {
            if (!boundWins) revert WrongSide();
            if (boundToken.balanceOf(msg.sender) < amount) revert InsufficientBalance();
            boundToken.burnFrom(msg.sender, amount);
        } else {
            if (boundWins) revert WrongSide();
            if (breakToken.balanceOf(msg.sender) < amount) revert InsufficientBalance();
            breakToken.burnFrom(msg.sender, amount);
        }

        collateralToken.safeTransfer(msg.sender, payout);
        emit TokensRedeemed(msg.sender, amount, payout);
    }

    function getBoundPrice() external view returns (uint256) {
        uint256 totalPool = boundPool + breakPool;
        if (totalPool == 0) return 5e17;
        return (boundPool * 1e18) / totalPool;
    }

    function getBreakPrice() external view returns (uint256) {
        uint256 totalPool = boundPool + breakPool;
        if (totalPool == 0) return 5e17;
        return (breakPool * 1e18) / totalPool;
    }

    function getEstimatedTokens(bool isBound, uint256 grossUsdc) external view returns (uint256) {
        uint256 netToPool = netUsdcToPool(grossUsdc);
        if (netToPool == 0) return 0;
        uint256 totalPool = boundPool + breakPool;
        if (totalPool == 0) return netToPool * 2;
        uint256 price = isBound ? (boundPool * 1e18) / totalPool : (breakPool * 1e18) / totalPool;
        return (netToPool * 1e18) / price;
    }

    function getEstimatedPayout(bool isBound, uint256 grossUsdc) external view returns (uint256) {
        if (marketConfig.settled) return 0;
        uint256 netToPool = netUsdcToPool(grossUsdc);
        if (netToPool == 0) return 0;
        uint256 totalPool = boundPool + breakPool;
        if (totalPool == 0) return 0;
        uint256 price = isBound ? (boundPool * 1e18) / totalPool : (breakPool * 1e18) / totalPool;
        if (price == 0) return 0;
        uint256 tokens = (netToPool * 1e18) / price;
        if (tokens == 0) return 0;
        uint256 newTotalPool = totalPool + netToPool;
        if (newTotalPool <= seedPrincipal) return 0;
        uint256 newTraderPool = newTotalPool - seedPrincipal;
        if (isBound) {
            uint256 newBoundSupply = boundToken.totalSupply() + tokens;
            return (tokens * newTraderPool) / newBoundSupply;
        } else {
            uint256 newBreakSupply = breakToken.totalSupply() + tokens;
            return (tokens * newTraderPool) / newBreakSupply;
        }
    }

    function getDisplayPool() external view returns (uint256) {
        uint256 totalPool = boundPool + breakPool;
        if (totalPool <= seedPrincipal) return 0;
        return totalPool - seedPrincipal;
    }
}
