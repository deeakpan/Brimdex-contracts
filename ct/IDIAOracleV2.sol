// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Standard DIA Oracle V2 (pull) interface — widely deployed across chains.
/// @dev    `getValue(key)` returns **(price, timestamp)** — price first, then last update time.
///         Price decimals follow the feed (Brimdex uses 8-decimal DIA prices and normalizes in CTF).
interface IDIAOracleV2 {
    function getValue(string memory key) external view returns (uint128 price, uint128 timestamp);
}
