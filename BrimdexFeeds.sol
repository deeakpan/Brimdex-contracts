// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BrimdexFeeds
 * @notice A single contract that stores and manages multiple price feeds
 * @dev Uses bytes32 feed IDs for gas efficiency with string conversion helpers
 */
contract BrimdexFeeds {
    struct PriceData {
        int256 price;      // Price scaled by decimals
        uint64 timestamp;  // When price was updated
        uint80 roundId;    // Round ID from source (Chainlink roundId or CoinGecko timestamp)
        uint8 decimals;   // Number of decimals for price
    }

    // Mapping: feedId (bytes32) => PriceData
    mapping(bytes32 => PriceData) public feeds;
    
    // Mapping: feedId => human-readable name (for convenience)
    mapping(bytes32 => string) public feedNames;
    
    // Array of all registered feed IDs
    bytes32[] public allFeedIds;
    
    // Mapping to check if feed exists
    mapping(bytes32 => bool) public feedExists;
    
    // Owner address (only owner can update)
    address public owner;
    
    // Events
    event FeedUpdated(
        bytes32 indexed feedId,
        string feedName,
        int256 price,
        uint64 timestamp,
        uint80 roundId,
        uint8 decimals
    );
    
    event FeedRegistered(bytes32 indexed feedId, string feedName);
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /**
     * @notice Convert string feed name to bytes32 ID
     * @param feedName Human-readable feed name (e.g., "ETH/USD")
     * @return feedId bytes32 hash of the feed name
     */
    function getFeedId(string memory feedName) public pure returns (bytes32) {
        return keccak256(bytes(feedName));
    }

    /**
     * @notice Register a new feed (optional, for tracking)
     * @param feedName Human-readable feed name
     */
    function registerFeed(string memory feedName) external onlyOwner {
        bytes32 feedId = getFeedId(feedName);
        require(!feedExists[feedId], "Feed already exists");
        
        feedExists[feedId] = true;
        feedNames[feedId] = feedName;
        allFeedIds.push(feedId);
        
        emit FeedRegistered(feedId, feedName);
    }

    /**
     * @notice Update price for a specific feed (internal function)
     * @param feedId bytes32 hash of feed name
     * @param price Price value (scaled by decimals)
     * @param roundId Round ID from source
     * @param decimals Number of decimals
     */
    function _updateFeed(
        bytes32 feedId,
        int256 price,
        uint80 roundId,
        uint8 decimals
    ) internal {
        // Auto-register if doesn't exist
        if (!feedExists[feedId]) {
            feedExists[feedId] = true;
            allFeedIds.push(feedId);
        }
        
        feeds[feedId] = PriceData({
            price: price,
            timestamp: uint64(block.timestamp),
            roundId: roundId,
            decimals: decimals
        });
        
        emit FeedUpdated(
            feedId,
            feedNames[feedId],
            price,
            uint64(block.timestamp),
            roundId,
            decimals
        );
    }

    /**
     * @notice Update feed using string name (convenience function)
     * @param feedName Human-readable feed name (e.g., "ETH/USD")
     * @param price Price value (scaled by decimals)
     * @param roundId Round ID from source
     * @param decimals Number of decimals
     */
    function updateFeedByName(
        string memory feedName,
        int256 price,
        uint80 roundId,
        uint8 decimals
    ) external onlyOwner {
        bytes32 feedId = getFeedId(feedName);
        
        // Store feed name if not set
        if (bytes(feedNames[feedId]).length == 0) {
            feedNames[feedId] = feedName;
        }
        
        _updateFeed(feedId, price, roundId, decimals);
    }

    /**
     * @notice Get price data for a specific feed by bytes32 ID (internal)
     * @param feedId bytes32 hash of feed name
     * @return PriceData struct
     */
    function _getFeed(bytes32 feedId) internal view returns (PriceData memory) {
        require(feedExists[feedId], "Feed does not exist");
        return feeds[feedId];
    }

    /**
     * @notice Get price data for a specific feed by bytes32 ID
     * @param feedId bytes32 hash of feed name
     * @return PriceData struct
     */
    function getFeed(bytes32 feedId) external view returns (PriceData memory) {
        return _getFeed(feedId);
    }

    /**
     * @notice Get price data for a specific feed by string name
     * @param feedName Human-readable feed name
     * @return PriceData struct
     */
    function getFeedByName(string memory feedName) external view returns (PriceData memory) {
        bytes32 feedId = getFeedId(feedName);
        return _getFeed(feedId);
    }

    /**
     * @notice Get multiple feeds at once (internal)
     * @param feedIds Array of bytes32 feed IDs
     * @return Array of PriceData structs
     */
    function _getFeeds(bytes32[] memory feedIds) internal view returns (PriceData[] memory) {
        PriceData[] memory results = new PriceData[](feedIds.length);
        for (uint256 i = 0; i < feedIds.length; i++) {
            require(feedExists[feedIds[i]], "Feed does not exist");
            results[i] = feeds[feedIds[i]];
        }
        return results;
    }

    /**
     * @notice Get multiple feeds at once
     * @param feedIds Array of bytes32 feed IDs
     * @return Array of PriceData structs
     */
    function getFeeds(bytes32[] memory feedIds) external view returns (PriceData[] memory) {
        return _getFeeds(feedIds);
    }

    /**
     * @notice Get multiple feeds by string names
     * @param feedNameArray Array of feed names
     * @return Array of PriceData structs
     */
    function getFeedsByName(string[] memory feedNameArray) external view returns (PriceData[] memory) {
        bytes32[] memory feedIds = new bytes32[](feedNameArray.length);
        for (uint256 i = 0; i < feedNameArray.length; i++) {
            feedIds[i] = getFeedId(feedNameArray[i]);
        }
        return _getFeeds(feedIds);
    }

    /**
     * @notice Get total number of registered feeds
     * @return Count of feeds
     */
    function getFeedCount() external view returns (uint256) {
        return allFeedIds.length;
    }

    /**
     * @notice Get all feed IDs (for enumeration)
     * @return Array of all feed IDs
     */
    function getAllFeedIds() external view returns (bytes32[] memory) {
        return allFeedIds;
    }

    /**
     * @notice Transfer ownership
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner cannot be zero address");
        owner = newOwner;
    }
}
