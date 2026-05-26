// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IBrimdexLaunchOpenCoordinator {
    function launchPullCoordinator() external view returns (address);

    function scheduleLaunchAtNotional(address vault, uint8 assetId) external;

    function scheduleLaunchCompletion(address vault) external;
}
