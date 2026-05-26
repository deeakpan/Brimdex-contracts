// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";

/**
 * @title BDXGovernor
 * @notice On-chain governance for Brimdex protocol.
 *         Voting power = xBDX balance from VotingEscrow (IVotes interface).
 *         Clock mode: timestamp (matches VotingEscrow's getPastVotes).
 *
 * Parameters:
 *   Voting delay:        1 day  (86400 seconds)
 *   Voting period:       5 days (432000 seconds)
 *   Proposal threshold:  100,000 xBDX
 *   Quorum:              4% of total xBDX supply
 *   Timelock delay:      2 days (set on TimelockController at deploy)
 *
 * What governance can do (anything owned by the TimelockController):
 *   - BrimdexFeeConfig.setFeeRates(standardFee, discountedFee)
 *       Change total fee anywhere from 0.1% to 0.9% — both rates in one tx
 *   - BrimdexFeeConfig.setFeeSplit(lpBps, stakerBps, protocolBps)
 *       Rebalance LP / staker / protocol cut — must sum to 10000 bps, one tx
 *   - BrimdexFeeConfig.setProtocolWallet(newWallet)
 *       Move protocol fee destination
 *   - BrimdexFeeConfig.setStakingRewards(newAddress)
 *   - BrimdexFeeConfig.setVotingEscrow(newAddress)
 *   - BrimdexLMSRStackFactory.setOperator(newOperator)
 *   - TimelockController: execute arbitrary calls to move funds or upgrade contracts
 *
 * Deployment:
 *   1. Deploy TimelockController(minDelay=2days, proposers=[], executors=[address(0)])
 *   2. Deploy BDXGovernor(votingEscrow, timelock)
 *   3. Grant PROPOSER_ROLE to BDXGovernor on the timelock
 *   4. Grant CANCELLER_ROLE to BDXGovernor on the timelock
 *   5. Revoke TIMELOCK_ADMIN_ROLE from deployer on the timelock
 *   6. Transfer ownership of BrimdexFeeConfig, BrimdexLMSRStackFactory → timelock
 */
contract BDXGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    constructor(IVotes _token, TimelockController _timelock)
        Governor("BDXGovernor")
        GovernorSettings(
            1 days,         // voting delay: 1 day in seconds
            5 days,         // voting period: 5 days in seconds
            100_000e18      // proposal threshold: 100,000 xBDX
        )
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(4)  // 4% quorum of total xBDX supply
        GovernorTimelockControl(_timelock)
    {}

    // ── Timestamp clock (must match VotingEscrow's getPastVotes) ─────────────

    /// @notice Use block.timestamp instead of block.number.
    ///         VotingEscrow.getPastVotes(account, timestamp) expects timestamps.
    function clock() public view override(Governor, GovernorVotes) returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override(Governor, GovernorVotes) returns (string memory) {
        return "mode=timestamp";
    }

    // ── Required overrides ────────────────────────────────────────────────────

    function votingDelay()
        public view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.votingDelay();
    }

    function votingPeriod()
        public view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.votingPeriod();
    }

    function quorum(uint256 timepoint)
        public view
        override(Governor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return super.quorum(timepoint);
    }

    function proposalThreshold()
        public view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    function state(uint256 proposalId)
        public view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal view
        override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }
}
