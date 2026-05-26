// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVotingEscrow {
    function getVotes(address account) external view returns (uint256);
}

interface IStakingRewards {
    function notifyRewardAmount(uint256 reward) external;
}

/// @title BrimdexFeeConfig
/// @notice Stores all fee parameters for Brimdex LMSR markets.
///
/// Ownership model (Option B — governance + multisig):
///   owner = TimelockController (BDXGovernor / xBDX community vote)
///     - setFeeSplit: rebalance LP/staker/protocol allocation
///     - setStakingRewards: point to new staking contract
///     - setVotingEscrow: update xBDX contract address
///
///   protocolAdmin = Gnosis Safe 3/5 multisig
///     - setProtocolWallet: rotate fee destination immediately (no 8-day wait)
///     - setProtocolAdmin: transfer admin role to new multisig
///     - CANCELLER_ROLE on TimelockController: veto any queued governance proposal
///
/// Fee structure:
///   Total fee is always 0.9% (STANDARD_FEE) — this never changes.
///   xBDX holders with >= 200,000 xBDX pay 0.675% (DISCOUNTED_FEE) instead.
///   The 0.9% is split into three buckets (must always sum to 10000 bps):
///     LP share     — accrued in market, sent to vault LP pool on resolve
///     Staker share — pushed to BDXStaking.notifyRewardAmount() on every trade
///     Protocol share — accrued in market, withdrawable to protocolWallet
contract BrimdexFeeConfig is Ownable {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────

    /// @notice Denominator for fee rate calculations (1e18 = 100%).
    uint256 public constant FEE_RANGE = 1e18;

    /// @notice Total trading fee: always 0.9% (9e15). Never changes.
    ///         Governance only controls how this is split between LP, staker, and protocol.
    uint256 public constant STANDARD_FEE = 9e15;

    /// @notice Discounted fee for xBDX holders: 0.675% (25% off).
    ///         The discount reduces what the trader pays — the split still applies to whatever is collected.
    uint256 public constant DISCOUNTED_FEE = 675e13;

    /// @notice Minimum xBDX balance required for the discounted fee.
    uint256 public constant XBDX_DISCOUNT_THRESHOLD = 200_000e18;

    // ─── Mutable fee split (basis points, must sum to 10000) ─────────────────

    /// @notice LP share in bps. Default: 5333 (≈ 0.48% of 0.9%).
    uint16 public LP_BPS = 5333;

    /// @notice Staker share in bps. Default: 1111 (≈ 0.10% of 0.9%).
    uint16 public STAKER_BPS = 1111;

    /// @notice Protocol share in bps. Default: 3556 (≈ 0.32% of 0.9%).
    uint16 public PROTOCOL_BPS = 3556;

    // ─── Mutable addresses ────────────────────────────────────────────────────

    /// @notice Wallet that receives protocol fees. Must never be address(0).
    ///         Controlled by protocolAdmin (Gnosis Safe) — not governance.
    ///         Needs to move fast in case of wallet compromise.
    address public protocolWallet;

    /// @notice Address that can call setProtocolWallet — set to Gnosis Safe 3/5 multisig.
    ///         Separate from owner (TimelockController) so the multisig can rotate the
    ///         protocol wallet without waiting 8 days for a governance vote.
    address public protocolAdmin;

    /// @notice BDXStaking contract — receives staker cut on every trade via notifyRewardAmount.
    ///         If zero, the staker cut is redirected to protocolWallet.
    address public stakingRewards;

    /// @notice VotingEscrow contract — used to check xBDX balance for fee discount.
    ///         If zero, no discount is applied.
    address public votingEscrow;

    // ─── Events ───────────────────────────────────────────────────────────────

    event FeeSplitUpdated(uint16 lpBps, uint16 stakerBps, uint16 protocolBps);
    event ProtocolWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event ProtocolAdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event StakingRewardsUpdated(address indexed oldStakingRewards, address indexed newStakingRewards);
    event VotingEscrowUpdated(address indexed oldVotingEscrow, address indexed newVotingEscrow);

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param protocolWallet_  Address that receives protocol fees. Must not be zero.
    /// @param protocolAdmin_   Gnosis Safe — can rotate protocolWallet without governance vote.
    /// @param stakingRewards_  BDXStaking contract. May be address(0) to disable staker cut.
    /// @param votingEscrow_    VotingEscrow for xBDX. May be address(0) to disable discount.
    constructor(
        address protocolWallet_,
        address protocolAdmin_,
        address stakingRewards_,
        address votingEscrow_
    ) Ownable(msg.sender) {
        require(protocolWallet_ != address(0), "BrimdexFeeConfig: zero protocol wallet");
        require(protocolAdmin_ != address(0), "BrimdexFeeConfig: zero protocol admin");
        protocolWallet = protocolWallet_;
        protocolAdmin = protocolAdmin_;
        stakingRewards = stakingRewards_;
        votingEscrow = votingEscrow_;
    }

    modifier onlyProtocolAdmin() {
        require(msg.sender == protocolAdmin, "BrimdexFeeConfig: not protocol admin");
        _;
    }

    // ─── Governance: fee split setter ─────────────────────────────────────────

    /// @notice Set the LP / staker / protocol fee split in a single transaction.
    ///         Called by governance (TimelockController) after a successful vote.
    ///         All three values must sum to exactly 10000 bps.
    ///
    /// @param lpBps_      LP share in basis points.
    /// @param stakerBps_  Staker share in basis points.
    /// @param protocolBps_ Protocol share in basis points.
    ///
    /// Example: setFeeSplit(5000, 2000, 3000) → LP 50%, staker 20%, protocol 30%
    function setFeeSplit(uint16 lpBps_, uint16 stakerBps_, uint16 protocolBps_) external onlyOwner {
        require(uint256(lpBps_) + uint256(stakerBps_) + uint256(protocolBps_) == 10000,
            "BrimdexFeeConfig: split must sum to 10000 bps");
        require(lpBps_ > 0 && protocolBps_ > 0,
            "BrimdexFeeConfig: LP and protocol shares must be non-zero");
        LP_BPS = lpBps_;
        STAKER_BPS = stakerBps_;
        PROTOCOL_BPS = protocolBps_;
        emit FeeSplitUpdated(lpBps_, stakerBps_, protocolBps_);
    }

    // ─── Governance: address setters ──────────────────────────────────────────

    /// @notice Update the StakingRewards contract. Set to address(0) to redirect staker cut to protocol.
    ///         Called by governance (TimelockController).
    function setStakingRewards(address newStakingRewards) external onlyOwner {
        emit StakingRewardsUpdated(stakingRewards, newStakingRewards);
        stakingRewards = newStakingRewards;
    }

    /// @notice Update the VotingEscrow contract. Set to address(0) to disable xBDX discount.
    ///         Called by governance (TimelockController).
    function setVotingEscrow(address newVotingEscrow) external onlyOwner {
        emit VotingEscrowUpdated(votingEscrow, newVotingEscrow);
        votingEscrow = newVotingEscrow;
    }

    // ─── Protocol admin setters (Gnosis Safe) ─────────────────────────────────

    /// @notice Rotate the protocol fee wallet.
    ///         Called by protocolAdmin (Gnosis Safe 3/5) — no governance vote needed.
    ///         Kept separate so a compromised wallet can be rotated immediately.
    function setProtocolWallet(address newWallet) external onlyProtocolAdmin {
        require(newWallet != address(0), "BrimdexFeeConfig: zero address");
        emit ProtocolWalletUpdated(protocolWallet, newWallet);
        protocolWallet = newWallet;
    }

    /// @notice Transfer protocol admin role to a new address (e.g. new multisig).
    ///         Called by current protocolAdmin (Gnosis Safe).
    function setProtocolAdmin(address newAdmin) external onlyProtocolAdmin {
        require(newAdmin != address(0), "BrimdexFeeConfig: zero address");
        emit ProtocolAdminUpdated(protocolAdmin, newAdmin);
        protocolAdmin = newAdmin;
    }

    // ─── Fee logic (read by MarketMaker on every trade) ───────────────────────

    /// @notice Returns the applicable fee rate for `user`.
    ///         Returns DISCOUNTED_FEE if VotingEscrow is set and user holds >= threshold.
    ///         Returns STANDARD_FEE otherwise.
    function getFeeRate(address user) external view returns (uint256) {
        if (
            votingEscrow != address(0) &&
            IVotingEscrow(votingEscrow).getVotes(user) >= XBDX_DISCOUNT_THRESHOLD
        ) {
            return DISCOUNTED_FEE;
        }
        return STANDARD_FEE;
    }

    /// @notice Splits `totalFee` into LP, staker, and protocol portions.
    ///         Uses the current mutable LP_BPS / STAKER_BPS / PROTOCOL_BPS values.
    ///
    /// @param totalFee      The gross fee amount to split.
    /// @param stakingActive Whether a StakingRewards contract is active (non-zero address).
    /// @return lpFee        LP's share.
    /// @return stakerFee    Staker's share (0 if !stakingActive — absorbed into protocolFee).
    /// @return protocolFee  Protocol's share.
    function splitFee(uint256 totalFee, bool stakingActive)
        external
        view
        returns (
            uint256 lpFee,
            uint256 stakerFee,
            uint256 protocolFee
        )
    {
        lpFee = (totalFee * LP_BPS) / 10000;
        stakerFee = stakingActive ? (totalFee * STAKER_BPS) / 10000 : 0;
        protocolFee = totalFee - lpFee - stakerFee;
    }
}
