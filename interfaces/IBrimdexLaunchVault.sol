// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Stack vault surface for agent-driven launch after notional is reached.
interface IBrimdexLaunchVault {
    function finishOpen() external;

    function phase() external view returns (uint8);

    function reactivityCoordinator() external view returns (address);

    /// @notice Open tick handler (`BrimdexLaunchOpenCoordinator`); `finishOpen` checks this coordinator’s puller.
    function launchOpenCoordinator() external view returns (address);

    function assetId() external view returns (uint8);
}
