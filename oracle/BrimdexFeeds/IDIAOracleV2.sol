// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IDIAOracleV2
/// @notice DIA-style oracle surface (`getValue`) as described in DIA’s Solidity integration guides.
/// @dev Brimdex-backed feeds may be updated by an authorized updater (`report`) and/or trusted on-chain
///      puller contracts that complete Somnia JSON API callbacks (`setFromPuller`).
interface IDIAOracleV2 {
    /// @param key DIA-style pair key, e.g. `"BTC/USD"`.
    /// @return value Latest price in **1e8-scaled USD** (see `report`).
    /// @return timestamp Unix seconds of last update (as pushed by updater).
    function getValue(string calldata key) external view returns (uint128 value, uint128 timestamp);
}
