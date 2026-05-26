// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBrimdexFeedAgentPuller {
    function pullForLaunch(address vault) external;

    function pullForSettlement(uint64 tick, address market) external;

    /// @notice Coordinator-only: `finishOpen` on vault after feed pull (high-gas reactivity tick).
    function completeLaunch(address vault) external;
}
