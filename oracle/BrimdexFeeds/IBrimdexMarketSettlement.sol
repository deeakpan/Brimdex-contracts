// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice LMSR market surface for automated settlement.
interface IBrimdexMarketSettlement {
    function resolve() external;

    function vault() external view returns (address);
}
