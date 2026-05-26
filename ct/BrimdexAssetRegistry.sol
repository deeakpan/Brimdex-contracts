// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Stores the DIA Push Oracle address and maps assetKey → DIA feed key string.
/// @dev assetKey = keccak256(abi.encodePacked(feedKey)), e.g. keccak256("BTC/USD").
///      The oracle address is shared across all assets on a given chain.
contract BrimdexAssetRegistry is Ownable {
    /// @notice The DIA Push Oracle contract for this chain.
    address public diaOracle;

    /// @notice assetKey → DIA feed key string, e.g. "BTC/USD".
    mapping(bytes32 => string) public feedKeyByAssetKey;

    event OracleSet(address indexed oracle);
    event AssetFeedSet(bytes32 indexed assetKey, string feedKey);

    error FeedImmutable();

    constructor(address initialOwner, address diaOracle_) Ownable(initialOwner) {
        require(diaOracle_ != address(0), "zero oracle");
        diaOracle = diaOracle_;
    }

    /// @notice Update the DIA oracle address (e.g. when deploying to a new chain).
    function setOracle(address diaOracle_) external onlyOwner {
        require(diaOracle_ != address(0), "zero oracle");
        diaOracle = diaOracle_;
        emit OracleSet(diaOracle_);
    }

    /// @notice Register an asset feed. Each `assetKey` may only be set once (immutable mapping).
    /// @param assetKey  keccak256 of the feedKey string.
    /// @param feedKey   DIA key string, e.g. "BTC/USD".
    function setFeed(bytes32 assetKey, string calldata feedKey) external onlyOwner {
        require(bytes(feedKey).length > 0, "empty feedKey");
        if (bytes(feedKeyByAssetKey[assetKey]).length != 0) revert FeedImmutable();
        feedKeyByAssetKey[assetKey] = feedKey;
        emit AssetFeedSet(assetKey, feedKey);
    }

    /// @notice Returns the feed key for an asset, reverts if not registered.
    function getFeedKey(bytes32 assetKey) external view returns (string memory) {
        string memory key = feedKeyByAssetKey[assetKey];
        require(bytes(key).length > 0, "unknown assetKey");
        return key;
    }
}
