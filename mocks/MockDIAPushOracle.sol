// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Mock DIA Oracle V2 for tests — implements `getValue` (price, timestamp) order.
contract MockDIAPushOracle {
    mapping(string => uint128) public prices;
    mapping(string => uint128) public timestamps;

    function setPrice(string memory key, uint128 price, uint128 ts) external {
        prices[key] = price;
        timestamps[key] = ts;
    }

    function getValue(string memory key) external view returns (uint128 price, uint128 timestamp) {
        return (prices[key], timestamps[key]);
    }
}
