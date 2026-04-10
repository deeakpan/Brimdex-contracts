// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./BrimdexMarket.sol";
import "./BrimdexParimutuelToken.sol";
import "./MarketLiquidityVault.sol";

/// @title BrimdexMarketFactory
/// @notice Deploys markets + per-market liquidity vaults in a single tx.
///         Owner must approve this contract for `seedPrincipal` USDC before calling createMarket.
///         Seed is routed owner → vault (LP shares minted to owner) → market, keeping full vault accounting.
///         Vault remains open for additional LP deposits during active epoch.
contract BrimdexFactory is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable collateralToken;
    address public immutable feedsContract;
    address public immutable treasury;

    /// @notice USDC seeded per market (6 decimals).
    uint256 public seedPrincipal;

    address[] public markets;
    mapping(address => bool) public isMarket;
    mapping(address => address) public marketToBoundToken;
    mapping(address => address) public marketToBreakToken;
    mapping(address => address) public marketToLiquidityVault;
    mapping(bytes32 => address) public activeMarkets;

    struct CreateMarketParams {
        string name;
        uint256 expiryTimestamp;
        uint256 timeframeDuration;
        string feedName;
        uint256 bandPercent;
        string boundTokenName;
        string boundTokenSymbol;
        string breakTokenName;
        string breakTokenSymbol;
    }

    event MarketCreated(
        address indexed market,
        address indexed liquidityVault,
        address indexed boundToken,
        address breakToken,
        string name,
        uint256 lowerBound,
        uint256 upperBound,
        uint256 expiryTimestamp
    );

    constructor(
        address _collateralToken,
        address _feedsContract,
        address _owner,
        address _treasury
    ) Ownable(_owner) {
        require(_treasury != address(0), "Treasury required");
        collateralToken = _collateralToken;
        feedsContract = _feedsContract;
        treasury = _treasury;
        seedPrincipal = 20_000_000; // default $20 USDC (6 decimals)
    }

    function setSeedPrincipal(uint256 _seedPrincipal) external onlyOwner {
        require(_seedPrincipal > 0, "Seed principal must be > 0");
        seedPrincipal = _seedPrincipal;
    }

    function getMarketSlotKey(
        string memory name,
        uint256 timeframeDuration,
        uint256 bandPercent
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(name, timeframeDuration, bandPercent));
    }

    function isActiveMarket(
        string calldata name,
        uint256 timeframeDuration,
        uint256 bandPercent
    ) external view returns (bool) {
        bytes32 marketKey = getMarketSlotKey(name, timeframeDuration, bandPercent);
        address m = activeMarkets[marketKey];
        if (m == address(0)) return false;
        (, , , , uint256 existingExpiry, , , , bool existingSettled) = BrimdexMarket(m).marketConfig();
        return !existingSettled && existingExpiry > block.timestamp;
    }

    /// @notice Deploy and start a market in one tx.
    ///         Owner must pre-approve this contract for `seedPrincipal` USDC.
    ///         Seed flows: owner → factory → vault (LP shares minted to owner) → market.
    function createMarket(
        string memory name,
        uint256 expiryTimestamp,
        uint256 timeframeDuration,
        string memory feedName,
        uint256 bandPercent,
        string memory boundTokenName,
        string memory boundTokenSymbol,
        string memory breakTokenName,
        string memory breakTokenSymbol
    ) external onlyOwner nonReentrant returns (address market, address boundToken, address breakToken, address liquidityVault) {
        CreateMarketParams memory p = CreateMarketParams({
            name: name,
            expiryTimestamp: expiryTimestamp,
            timeframeDuration: timeframeDuration,
            feedName: feedName,
            bandPercent: bandPercent,
            boundTokenName: boundTokenName,
            boundTokenSymbol: boundTokenSymbol,
            breakTokenName: breakTokenName,
            breakTokenSymbol: breakTokenSymbol
        });
        return _createMarketInternal(p);
    }

    function _createMarketInternal(CreateMarketParams memory p)
        internal
        returns (address market, address boundToken, address breakToken, address liquidityVault)
    {
        require(bytes(p.name).length > 0 && bytes(p.name).length <= 8, "Name must be 1-8 characters");
        require(bytes(p.feedName).length > 0, "Feed name required");
        require(p.bandPercent > 0 && p.bandPercent <= 10000, "Band percent out of range");
        require(p.expiryTimestamp > block.timestamp, "Expiry must be in the future");
        require(p.timeframeDuration > 0, "Timeframe must be > 0");

        bytes32 marketKey = getMarketSlotKey(p.name, p.timeframeDuration, p.bandPercent);
        address existingMarket = activeMarkets[marketKey];
        if (existingMarket != address(0)) {
            (, , , , uint256 existingExpiry, , , , bool existingSettled) = BrimdexMarket(existingMarket).marketConfig();
            require(existingSettled || existingExpiry <= block.timestamp, "Active market exists for this slot");
        }

        // ── Deploy tokens ────────────────────────────────────────────────────
        boundToken = address(new BrimdexParimutuelToken(p.boundTokenName, p.boundTokenSymbol, address(this)));
        breakToken = address(new BrimdexParimutuelToken(p.breakTokenName, p.breakTokenSymbol, address(this)));

        // ── Deploy market ────────────────────────────────────────────────────
        market = address(
            new BrimdexMarket(
                collateralToken,
                boundToken,
                breakToken,
                msg.sender,
                address(this),
                feedsContract,
                treasury
            )
        );

        BrimdexParimutuelToken(boundToken).transferOwnership(market);
        BrimdexParimutuelToken(breakToken).transferOwnership(market);

        // ── Deploy vault ─────────────────────────────────────────────────────
        liquidityVault = address(new MarketLiquidityVault(market, collateralToken, address(this), seedPrincipal));
        BrimdexMarket(market).setLiquidityVault(liquidityVault);

        // ── Seed flow: owner → factory → vault → market ──────────────────────
        // Pull seedPrincipal USDC from owner into factory (owner approved factory beforehand)
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), seedPrincipal);

        // Approve vault to pull from factory, then depositFor owner (mints LP shares to owner)
        IERC20(collateralToken).forceApprove(liquidityVault, seedPrincipal);
        MarketLiquidityVault(liquidityVault).depositFor(msg.sender, seedPrincipal, address(this));
        IERC20(collateralToken).forceApprove(liquidityVault, 0);

        // Vault pulls seed to market
        MarketLiquidityVault(liquidityVault).pullSeedToMarket();

        // ── Initialize market (reads oracle, sets bounds) ─────────────────────
        BrimdexMarket(market).initialize(
            p.name,
            p.feedName,
            p.bandPercent,
            p.expiryTimestamp,
            seedPrincipal
        );

        // ── Register ──────────────────────────────────────────────────────────
        markets.push(market);
        isMarket[market] = true;
        marketToBoundToken[market] = boundToken;
        marketToBreakToken[market] = breakToken;
        marketToLiquidityVault[market] = liquidityVault;
        activeMarkets[marketKey] = market;

        (, , uint256 lowerBound, uint256 upperBound, uint256 exp, , , , ) = BrimdexMarket(market).marketConfig();

        emit MarketCreated(
            market,
            liquidityVault,
            boundToken,
            breakToken,
            p.name,
            lowerBound,
            upperBound,
            exp
        );
    }

    function getAllMarkets() external view returns (address[] memory) {
        return markets;
    }

    function getMarkets(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory result)
    {
        require(offset <= markets.length, "Offset out of range");
        uint256 end = offset + limit > markets.length ? markets.length : offset + limit;
        result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = markets[i];
        }
    }

    function getMarketCount() external view returns (uint256) {
        return markets.length;
    }
}
