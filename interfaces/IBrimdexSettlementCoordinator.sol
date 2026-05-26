// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Pull coordinator: launch pull tick + expiry settlement; open tick is `BrimdexLaunchOpenCoordinator`.
interface IBrimdexSettlementCoordinator {
    function requestMarketLaunch(address vault, uint8 assetId) external;

    function scheduleMarketSettlement(address market, uint8 assetId, uint256 expiryTimestamp) external;

    /// @notice Puller calls after DIA feed write — schedules `completeLaunch` on a reactivity tick.
    function scheduleLaunchCompletion(address vault) external;

    function puller(uint8 assetId) external view returns (address);

    function scheduleMillisByMarket(address market) external view returns (uint256);
}
