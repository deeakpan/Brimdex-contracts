// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./BrimdexMarket.sol";
import "./BrimdexFactory.sol";
import "./IDataStreams.sol";

/// @title BrimdexRouter
/// @notice Router contract that allows users to approve USDC once and use it across all markets
/// @dev Users approve this router contract, and it forwards USDC to individual market contracts
contract BrimdexRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    IERC20 public immutable collateralToken; // USDC
    BrimdexFactory public immutable factory;
    IDataStreams public immutable dataStreams; // Somnia Data Streams contract
    bytes32 public immutable purchaseSchemaId; // Schema ID for purchase data
    
    // Purchase schema: address user, address market, uint256 amount, uint256 tokens, uint64 timestamp, bool isBound
    // Schema ID: 0xd1e3226269cf1053c82a92ccf174d8a2cb06df1a7b9fd50d6d91156637aecefb
    constructor(
        address _collateralToken,
        address _factory,
        address _dataStreams,
        bytes32 _purchaseSchemaId
    ) {
        collateralToken = IERC20(_collateralToken);
        factory = BrimdexFactory(_factory);
        dataStreams = IDataStreams(_dataStreams);
        purchaseSchemaId = _purchaseSchemaId;
    }
    
    /// @notice Buy BOUND tokens through the router.
    /// @param marketAddress  Address of the target market.
    /// @param amount         USDC to spend (6 decimals).
    /// @param minTokensOut   Minimum BOUND tokens to receive (slippage guard,
    ///                       forwarded directly to the market contract).
    /// @dev Market now mints directly to msg.sender via the recipient
    ///      parameter — no balance-delta bookkeeping in the router.
    /// @dev try/catch ensures forceApprove is always revoked and USDC
    ///      is refunded to the user if the market call reverts.
    function buyBound(
        address marketAddress,
        uint256 amount,
        uint256 minTokensOut
    ) external nonReentrant {
        require(factory.isMarket(marketAddress), "Invalid market");
        require(amount > 0, "Amount must be > 0");
        
        // Validate token address is registered before proceeding.
        address boundToken = factory.marketToBoundToken(marketAddress);
        require(boundToken != address(0), "Bound token not registered");

        // Pull USDC from user into router.
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        
        BrimdexMarket market = BrimdexMarket(marketAddress);
        
        // Grant approval, call market, then unconditionally revoke.
        collateralToken.forceApprove(marketAddress, amount);

        try market.buyBound(amount, msg.sender, minTokensOut) {
            // Success — tokens were minted directly to msg.sender by the market.
        } catch {
            // Revert approval and return USDC to user before re-reverting.
            collateralToken.forceApprove(marketAddress, 0);
            collateralToken.safeTransfer(msg.sender, amount);
            revert("Market buy failed: check market state");
        }

        // Always revoke residual approval after a successful call.
        collateralToken.forceApprove(marketAddress, 0);
        
        // Publish purchase to Data Streams
        _publishPurchaseToStreams(marketAddress, msg.sender, amount, true);
    }
    
    /// @notice Buy BREAK tokens through the router.
    /// @param marketAddress  Address of the target market.
    /// @param amount         USDC to spend (6 decimals).
    /// @param minTokensOut   Minimum BREAK tokens to receive (slippage guard).
    function buyBreak(
        address marketAddress,
        uint256 amount,
        uint256 minTokensOut
    ) external nonReentrant {
        require(factory.isMarket(marketAddress), "Invalid market");
        require(amount > 0, "Amount must be > 0");
        
        // Validate token address is registered before proceeding.
        address breakToken = factory.marketToBreakToken(marketAddress);
        require(breakToken != address(0), "Break token not registered");

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        
        BrimdexMarket market = BrimdexMarket(marketAddress);
        
        collateralToken.forceApprove(marketAddress, amount);

        try market.buyBreak(amount, msg.sender, minTokensOut) {
            // Success — tokens minted directly to msg.sender.
        } catch {
            collateralToken.forceApprove(marketAddress, 0);
            collateralToken.safeTransfer(msg.sender, amount);
            revert("Market buy failed: check market state");
        }

        collateralToken.forceApprove(marketAddress, 0);
        
        // Publish purchase to Data Streams
        _publishPurchaseToStreams(marketAddress, msg.sender, amount, false);
    }

    // ─── Data Streams Publishing ──────────────────────────────────────────────

    /// @notice Encode purchase data according to schema: address user, address market, uint256 amount, uint256 tokens, uint64 timestamp, bool isBound
    /// @dev Schema: address user, address market, uint256 amount, uint256 tokens, uint64 timestamp, bool isBound
    function _encodePurchaseData(
        address user,
        address market,
        uint256 amount,
        uint256 tokens,
        uint64 timestamp,
        bool isBound
    ) internal pure returns (bytes memory) {
        // Encode according to schema format
        // Each field is padded to 32 bytes
        return abi.encodePacked(
            uint256(uint160(user)),      // address (20 bytes, padded to 32)
            uint256(uint160(market)),    // address (20 bytes, padded to 32)
            amount,                       // uint256 (32 bytes)
            tokens,                      // uint256 (32 bytes)
            uint256(timestamp),          // uint64 (8 bytes, padded to 32)
            isBound ? uint256(1) : uint256(0) // bool (1 byte, padded to 32)
        );
    }

    /// @notice Generate deterministic data ID for purchase
    /// @dev Uses keccak256 hash of market-user-timestamp combination
    function _generatePurchaseDataId(
        address market,
        address user,
        uint64 timestamp
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(market, user, timestamp));
    }

    /// @notice Publish purchase to Data Streams
    /// @dev Router is the publisher, but user address is stored in the data
    /// @dev Calculates tokens using pools BEFORE the purchase (work backwards from current pools)
    function _publishPurchaseToStreams(
        address marketAddress,
        address user,
        uint256 amount,
        bool isBound
    ) internal {
        BrimdexMarket market = BrimdexMarket(marketAddress);
        
        // Read pools AFTER purchase (they've been updated)
        uint256 newTotalPool = market.boundPool() + market.breakPool();
        uint256 newPool = isBound ? market.boundPool() : market.breakPool();
        
        uint256 netToPool = BrimdexMarket(marketAddress).netUsdcToPool(amount);

        // Calculate pools BEFORE purchase (net USDC is what increases pools)
        uint256 oldTotalPool = newTotalPool - netToPool;
        uint256 oldPool = newPool - netToPool;

        uint256 price = oldTotalPool > 0 ? (oldPool * 1e18) / oldTotalPool : 1e18;

        uint256 tokens = (netToPool * 1e18) / price;
        
        uint64 timestamp = uint64(block.timestamp);
        
        // Encode purchase data
        bytes memory purchaseData = _encodePurchaseData(
            user,
            marketAddress,
            amount,
            tokens,
            timestamp,
            isBound
        );
        
        // Generate data ID
        bytes32 dataId = _generatePurchaseDataId(marketAddress, user, timestamp);
        
        // Publish to Data Streams (router is publisher)
        IDataStreams.DataStream[] memory streams = new IDataStreams.DataStream[](1);
        streams[0] = IDataStreams.DataStream({
            id: dataId,
            schemaId: purchaseSchemaId,
            data: purchaseData
        });
        
        // Call streams contract (don't revert on failure - non-critical)
        try dataStreams.esstores(streams) {
            // Success
        } catch {
            // Silently fail - publishing is non-critical for purchase to succeed
        }
    }

    // ─── ETH guard ───────────────────────────────────────────────────────────

    /// @dev Reject accidental ETH transfers instead of locking them.
    receive() external payable {
        revert("BrimdexRouter: ETH not accepted");
    }
}
