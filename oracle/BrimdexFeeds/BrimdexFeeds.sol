// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BrimdexFeedAssets} from "./BrimdexFeedAssets.sol";
import {IDIAOracleV2} from "./IDIAOracleV2.sol";

/// @title BrimdexFeeds
/// @notice DIA-shaped price store (`getValue`). Updates come from the immutable `updater` (`report`) or from
///         trusted `BrimdexFeedAgentPuller` contracts (`setFromPuller`). JSON API / Somnia ticks live elsewhere.
/// @dev Crude is **WTI** (`WTI/USD`): `https://api.diadata.org/v1/rwa/Commodities/WTI-USD` (DIA public API).
contract BrimdexFeeds is IDIAOracleV2 {
    struct Stored {
        uint128 price;
        uint128 timestamp;
    }

    address public immutable updater;

    mapping(bytes32 => Stored) private _values;
    mapping(address => bool) public trustedPuller;

    event PriceReported(string diaKey, uint128 price, uint128 timestamp);
    event PriceSetFromPuller(string diaKey, uint128 price, uint128 timestamp, address indexed puller);
    event PullerTrusted(address indexed puller, bool trusted);

    error Unauthorized();
    error BadConfig();

    uint8 public constant ASSET_COUNT = 16;

    constructor(address updater_) {
        if (updater_ == address(0)) revert BadConfig();
        updater = updater_;
    }

    receive() external payable {}

    /// @inheritdoc IDIAOracleV2
    function getValue(string calldata key) external view override returns (uint128 value, uint128 timestamp) {
        Stored memory s = _values[keccak256(bytes(key))];
        return (s.price, s.timestamp);
    }

    /// @notice Authorized updater writes the latest price for a DIA-style key (e.g. `BTC/USD`).
    /// @dev `price` is **USD with 8 decimals fixed-point** (same convention many DIA deployments use).
    function report(string calldata diaKey, uint128 price, uint128 timestamp_) external {
        if (msg.sender != updater) revert Unauthorized();
        _values[keccak256(bytes(diaKey))] = Stored(price, timestamp_);
        emit PriceReported(diaKey, price, timestamp_);
    }

    /// @notice One trusted puller writes one key (same decimals as `report`).
    function setFromPuller(string calldata diaKey, uint128 price, uint128 timestamp_) external {
        if (!trustedPuller[msg.sender]) revert Unauthorized();
        _values[keccak256(bytes(diaKey))] = Stored(price, timestamp_);
        emit PriceSetFromPuller(diaKey, price, timestamp_, msg.sender);
    }

    function trustPuller(address puller, bool trusted) external {
        if (msg.sender != updater) revert Unauthorized();
        trustedPuller[puller] = trusted;
        emit PullerTrusted(puller, trusted);
    }

    function trustPullers(address[16] calldata pullers_, bool trusted) external {
        if (msg.sender != updater) revert Unauthorized();
        for (uint8 i = 0; i < BrimdexFeedAssets.ASSET_COUNT; ++i) {
            trustedPuller[pullers_[i]] = trusted;
            emit PullerTrusted(pullers_[i], trusted);
        }
    }

    function diaKeyOf(uint8 assetId) public pure returns (string memory) {
        return BrimdexFeedAssets.diaKeyOf(assetId);
    }

    function feedUrl(uint8 assetId) public pure returns (string memory) {
        return BrimdexFeedAssets.feedUrl(assetId);
    }
}
