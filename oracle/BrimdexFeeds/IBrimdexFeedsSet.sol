// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Oracle surface used by `BrimdexFeedAgentPuller` after a successful agent callback.
interface IBrimdexFeedsSet {
    function setFromPuller(string calldata diaKey, uint128 price, uint128 timestamp_) external;
}
