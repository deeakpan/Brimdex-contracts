// SPDX-License-Identifier: LGPL-3.0
pragma solidity ^0.8.24;

import {Fixed192x64Math} from "./Fixed192x64Math.sol";
import {SignedSafeMath} from "./SignedSafeMath.sol";
import {MarketMaker, IBrimdexFeeConfig} from "./MarketMaker.sol";
import {BrimdexConditionalTokens} from "../ct/BrimdexConditionalTokens.sol";
import {Whitelist} from "./Whitelist.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LMSRMarketMaker (Gnosis fork, 0.8)
contract LMSRMarketMaker is MarketMaker {
    using SignedSafeMath for int256;

    uint256 internal constant LMSR_ONE = 0x10000000000000000;
    int256 internal constant EXP_LIMIT = 3394200909562557497344;

    constructor(
        address initialOwner,
        address tradeRouter_,
        address bootstrapExecutor_,
        BrimdexConditionalTokens _pmSystem,
        IERC20 _collateralToken,
        bytes32[] memory _conditionIds,
        IBrimdexFeeConfig feeConfig_,
        Whitelist _whitelist,
        bytes32 _assetKey,
        uint256 _lowerBound,
        uint256 _upperBound,
        uint256 _expiryTimestamp,
        address _vault
    ) MarketMaker(initialOwner, tradeRouter_, bootstrapExecutor_, _pmSystem, _collateralToken, _conditionIds, feeConfig_, _whitelist, _assetKey, _lowerBound, _upperBound, _expiryTimestamp, _vault) {}

    function calcNetCost(int256[] memory outcomeTokenAmounts) public view override returns (int256 netCost) {
        require(outcomeTokenAmounts.length == atomicOutcomeSlotCount, "len");

        int256[] memory otExpNums = new int256[](atomicOutcomeSlotCount);
        for (uint256 i = 0; i < atomicOutcomeSlotCount; i++) {
            int256 balance = int256(pmSystem.balanceOf(address(this), generateAtomicPositionId(i)));
            require(balance >= 0, "bal");
            otExpNums[i] = outcomeTokenAmounts[i].sub(balance);
        }

        int256 log2N = Fixed192x64Math.binaryLog(
            atomicOutcomeSlotCount * LMSR_ONE,
            Fixed192x64Math.EstimationMode.UpperBound
        );

        (uint256 sum, int256 offset, ) = sumExpOffset(log2N, otExpNums, 0, Fixed192x64Math.EstimationMode.UpperBound);
        netCost = Fixed192x64Math.binaryLog(sum, Fixed192x64Math.EstimationMode.UpperBound);
        netCost = netCost.add(offset);
        netCost = (netCost.mul(int256(LMSR_ONE)) / log2N).mul(int256(funding));

        if (netCost <= 0 || (netCost / int256(LMSR_ONE)) * int256(LMSR_ONE) == netCost) {
            netCost /= int256(LMSR_ONE);
        } else {
            netCost = netCost / int256(LMSR_ONE) + 1;
        }
    }

    function calcMarginalPrice(uint8 outcomeTokenIndex) public view returns (uint256 price) {
        int256[] memory negOutcomeTokenBalances = new int256[](atomicOutcomeSlotCount);
        for (uint256 i = 0; i < atomicOutcomeSlotCount; i++) {
            int256 negBalance = -int256(pmSystem.balanceOf(address(this), generateAtomicPositionId(i)));
            require(negBalance <= 0, "neg");
            negOutcomeTokenBalances[i] = negBalance;
        }

        int256 log2N = Fixed192x64Math.binaryLog(
            negOutcomeTokenBalances.length * LMSR_ONE,
            Fixed192x64Math.EstimationMode.Midpoint
        );
        (uint256 sum, , uint256 outcomeExpTerm) = sumExpOffset(
            log2N,
            negOutcomeTokenBalances,
            outcomeTokenIndex,
            Fixed192x64Math.EstimationMode.Midpoint
        );
        return outcomeExpTerm / (sum / LMSR_ONE);
    }

    function sumExpOffset(
        int256 log2N,
        int256[] memory otExpNums,
        uint8 outcomeIndex,
        Fixed192x64Math.EstimationMode estimationMode
    ) private view returns (uint256 sum, int256 offset, uint256 outcomeExpTerm) {
        require(log2N >= 0 && int256(funding) >= 0, "funding");
        offset = Fixed192x64Math.max(otExpNums);
        offset = offset.mul(log2N) / int256(funding);
        offset = offset.sub(EXP_LIMIT);
        uint256 term;
        for (uint256 i = 0; i < otExpNums.length; i++) {
            term = Fixed192x64Math.pow2(
                (otExpNums[i].mul(log2N) / int256(funding)).sub(offset),
                estimationMode
            );
            if (i == outcomeIndex) {
                outcomeExpTerm = term;
            }
            sum += term;
        }
    }
}
