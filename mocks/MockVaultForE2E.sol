// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BrimdexLMSRStackFactory} from "../lmsr/BrimdexLMSRStackFactory.sol";
import {Whitelist} from "../lmsr/Whitelist.sol";

/// @notice Authorized vault for e2e: pays `openMarket` and receives `receiveLP` from the LMSR after resolve.
contract MockVaultForE2E {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    BrimdexLMSRStackFactory public immutable stack;

    constructor(IERC20 usdc_, BrimdexLMSRStackFactory stack_) {
        usdc = usdc_;
        stack = stack_;
    }

    function receiveLP(uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
    }

    function openAndFund(
        address marketOwner,
        bytes32 assetKey,
        uint256 lowerBound,
        uint256 upperBound,
        uint256 expiryTimestamp,
        address whitelist_,
        uint256 funding,
        uint256 launchOracleSpot6,
        uint16 launchBandBps,
        uint256 launchHorizonSeconds
    ) external {
        usdc.forceApprove(address(stack), funding);
        stack.openMarket(
            marketOwner,
            assetKey,
            lowerBound,
            upperBound,
            expiryTimestamp,
            Whitelist(whitelist_),
            funding,
            launchOracleSpot6,
            launchBandBps,
            launchHorizonSeconds
        );
        usdc.forceApprove(address(stack), 0);
    }
}
