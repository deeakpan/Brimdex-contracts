// SPDX-License-Identifier: LGPL-3.0
pragma solidity ^0.8.24;

import {LMSRMarketMaker} from "./LMSRMarketMaker.sol";
import {Whitelist} from "./Whitelist.sol";

/// @title BrimdexLMSRRouter
/// @notice Trade entrypoint only: forwards to `tradeFrom` on the market (collateral / ERC1155 approvals are to the LMSR contract).
contract BrimdexLMSRRouter {
    /// @notice `payer` is always `msg.sender`; approvals must be to `market`.
    function tradeLmsr(LMSRMarketMaker market, int256[] calldata outcomeTokenAmounts, int256 collateralLimit)
        external
        returns (int256 netCost)
    {
        int256[] memory amounts = new int256[](outcomeTokenAmounts.length);
        for (uint256 i = 0; i < outcomeTokenAmounts.length; i++) {
            amounts[i] = outcomeTokenAmounts[i];
        }
        return market.tradeFrom(msg.sender, amounts, collateralLimit);
    }
}
