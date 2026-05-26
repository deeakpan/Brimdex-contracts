// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title BDXEmissionsDistributor (epoch-gauge)
 * @notice Distributes 210M $BDX to xBDX lockers over 4 years using fixed weekly epochs.
 *
 * Design — adapted from Curve `FeeDistributor.vy` and Velodrome v1 `RewardsDistributor.sol`:
 *   - Time is split into weekly epochs starting at `startTime` (set when the vault calls `notifyStart`).
 *   - For epoch `e`, the contract pays out `epochEmissions(e)` BDX in total, distributed pro-rata to
 *     every account by their xBDX voting power at the START of that epoch.
 *   - Snapshots come from `VotingEscrow.getPastVotes(user, t)` and `getPastTotalSupply(t)`, which are
 *     correct *as of timestamp t* — no continuous decay drift, unlike the Synthetix accumulator.
 *   - Users may only claim epochs that have already finished (i.e. `block.timestamp >= epochEnd(e)`).
 *   - Per-call iteration is capped (`MAX_EPOCHS_PER_CLAIM`) so a long-absent user never OOGs; they
 *     simply call `claim()` more than once.
 *
 * Year-based emission rates (BDX per second, 18 decimals) are kept identical to the prior contract,
 * so the same 75/55/45/35M-per-year curve still applies. Within each weekly epoch the contract
 * sums the rate over (possibly two) year segments.
 *
 * Setup (one-time at deploy):
 *   1. Deploy BDXToken
 *   2. Deploy BDXEmissionsVault
 *   3. Mint 210,000,000 BDX to BDXEmissionsVault
 *   4. Deploy BDXEmissionsDistributor(vault, votingEscrow)
 *   5. Call vault.setDistributor(distributor) → vault calls notifyStart() here, clock starts.
 */

interface IVotingEscrow {
    function getPastVotes(address account, uint256 timestamp) external view returns (uint256);
    function getPastTotalSupply(uint256 timestamp) external view returns (uint256);
}

interface IBDXEmissionsVault {
    function release(address to, uint256 amount) external;
    function remaining() external view returns (uint256);
}

contract BDXEmissionsDistributor is ReentrancyGuard, Ownable {

    // ── Schedule constants ────────────────────────────────────────────────────

    uint256 public constant YEAR = 365 days;
    uint256 public constant EPOCH = 1 weeks;

    /// @notice BDX emitted per second in each year (18 decimals).
    ///         Year 1: 75M, Year 2: 55M, Year 3: 45M, Year 4: 35M, then 0.
    uint256 public constant RATE_YEAR_1 = 2_378_234_398_782_343;
    uint256 public constant RATE_YEAR_2 = 1_743_638_959_107_451;
    uint256 public constant RATE_YEAR_3 = 1_426_940_639_269_406;
    uint256 public constant RATE_YEAR_4 = 1_110_242_319_431_361;

    /// @notice Hard cap on epochs walked per `claim` call — protects against OOG for long-absent lockers.
    uint256 public constant MAX_EPOCHS_PER_CLAIM = 52;

    // ── State ─────────────────────────────────────────────────────────────────

    IBDXEmissionsVault public immutable emissionsVault;
    IVotingEscrow public immutable votingEscrow;

    /// @notice Timestamp of the first epoch boundary. Zero until `notifyStart` is called by the vault.
    uint256 public startTime;

    /// @notice Per-user cursor: the next epoch index they will claim from (inclusive).
    mapping(address => uint256) public nextClaimEpoch;

    /// @notice Next epoch the global sweeper will visit. Epochs `< lastGlobalSweepEpoch` have already
    ///         had their empty-epoch emissions folded into `bonusEmissions` of the first subsequent
    ///         non-empty epoch (or, if still no non-empty epoch seen, into `pendingFromEmptyEpochs`).
    uint256 public lastGlobalSweepEpoch;

    /// @notice BDX emitted by epochs with `totalVotesAt == 0` that have NOT yet been folded into a
    ///         subsequent non-empty epoch's `bonusEmissions`. The next sweep across a non-empty
    ///         epoch consumes this and routes it to that epoch.
    uint256 public pendingFromEmptyEpochs;

    /// @notice Extra BDX to distribute in epoch `e`, in addition to `epochEmissions(e)`. Populated
    ///         by the sweeper when folding emissions from prior empty epochs into the first
    ///         subsequent epoch with positive voting power.
    mapping(uint256 => uint256) public bonusEmissions;

    // ── Events ────────────────────────────────────────────────────────────────

    event EmissionsClaimed(address indexed user, uint256 fromEpoch, uint256 toEpoch, uint256 amount);
    event EmptyEpochsSwept(uint256 fromEpoch, uint256 toEpoch, uint256 foldedInto, uint256 amountFolded, uint256 pendingAfter);

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(address _emissionsVault, address _votingEscrow) Ownable(msg.sender) {
        require(_emissionsVault != address(0), "zero vault");
        require(_votingEscrow != address(0), "zero ve");
        emissionsVault = IBDXEmissionsVault(_emissionsVault);
        votingEscrow = IVotingEscrow(_votingEscrow);
    }

    /// @notice Called by `BDXEmissionsVault.setDistributor()` to start the emission clock.
    function notifyStart() external {
        require(msg.sender == address(emissionsVault), "BDXEmissionsDistributor: only vault");
        require(startTime == 0, "BDXEmissionsDistributor: already started");
        // Align epoch 0 boundary to the call timestamp; epoch e starts at `startTime + e * EPOCH`.
        startTime = block.timestamp;
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    /// @notice Timestamp at which epoch `e` begins.
    function epochStart(uint256 e) public view returns (uint256) {
        return startTime + e * EPOCH;
    }

    /// @notice Timestamp at which epoch `e` ends (= start of epoch e+1).
    function epochEnd(uint256 e) public view returns (uint256) {
        return startTime + (e + 1) * EPOCH;
    }

    /// @notice Index of the in-progress epoch right now. Reverts before `notifyStart`.
    function currentEpoch() public view returns (uint256) {
        require(startTime != 0, "not started");
        if (block.timestamp < startTime) return 0;
        return (block.timestamp - startTime) / EPOCH;
    }

    /// @notice Total BDX emitted into epoch `e` from the year-schedule (excludes folded empties).
    function epochEmissions(uint256 e) public view returns (uint256) {
        return _emittedBetween(epochStart(e), epochEnd(e));
    }

    /// @notice Total BDX distributable in epoch `e`: scheduled emissions PLUS any empties folded
    ///         in by the sweeper. This is the figure user pro-rata is taken from.
    function effectiveEmissions(uint256 e) public view returns (uint256) {
        return epochEmissions(e) + bonusEmissions[e];
    }

    /// @notice xBDX voting power of `user` at the start of epoch `e`.
    function userVotesAt(address user, uint256 e) public view returns (uint256) {
        return votingEscrow.getPastVotes(user, epochStart(e));
    }

    /// @notice Total xBDX voting power at the start of epoch `e`.
    function totalVotesAt(uint256 e) public view returns (uint256) {
        return votingEscrow.getPastTotalSupply(epochStart(e));
    }

    /// @notice Earned BDX for `user` in a specific epoch. Only meaningful for already-swept epochs;
    ///         pre-sweep, `bonusEmissions[e]` may still be zero even if empties precede `e`.
    function earnedInEpoch(address user, uint256 e) public view returns (uint256) {
        uint256 totalVotes = totalVotesAt(e);
        if (totalVotes == 0) return 0;
        uint256 myVotes = userVotesAt(user, e);
        if (myVotes == 0) return 0;
        return (effectiveEmissions(e) * myVotes) / totalVotes;
    }

    /// @notice Total claimable BDX for `user` across all currently-finished epochs (capped to
    ///         `MAX_EPOCHS_PER_CLAIM` to match `claim()` behaviour). Off-chain callers can
    ///         simulate after calling `sweep()` to see post-fold values.
    function claimable(address user) public view returns (uint256 amount, uint256 fromEpoch, uint256 toEpoch) {
        if (startTime == 0) return (0, 0, 0);
        fromEpoch = nextClaimEpoch[user];
        uint256 cur = currentEpoch();
        toEpoch = fromEpoch;
        uint256 limit = fromEpoch + MAX_EPOCHS_PER_CLAIM;
        if (limit > cur) limit = cur;
        if (limit > lastGlobalSweepEpoch) limit = lastGlobalSweepEpoch;
        for (uint256 e = fromEpoch; e < limit; e++) {
            amount += earnedInEpoch(user, e);
            toEpoch = e + 1;
        }
    }

    /// @notice Remaining BDX in the emissions vault.
    function remainingEmissions() external view returns (uint256) {
        return emissionsVault.remaining();
    }

    // ── Mutative ──────────────────────────────────────────────────────────────

    /// @notice Permissionless: advance the global sweep cursor, folding empty-epoch emissions
    ///         into the first subsequent non-empty epoch. Useful if claimers are far behind and
    ///         want to refresh the bonus pool before they can read up-to-date `effectiveEmissions`.
    /// @return advancedTo new value of `lastGlobalSweepEpoch`
    function sweep() external returns (uint256 advancedTo) {
        require(startTime != 0, "not started");
        return _sweepUpTo(lastGlobalSweepEpoch + MAX_EPOCHS_PER_CLAIM);
    }

    /// @notice Claim accumulated BDX emissions for all finished + swept epochs (up to
    ///         `MAX_EPOCHS_PER_CLAIM`). Auto-sweeps to keep the bonus pool fresh.
    ///         Callable any time after the first epoch ends; never expires.
    function claim() external nonReentrant returns (uint256 amount) {
        require(startTime != 0, "not started");
        uint256 fromEpoch = nextClaimEpoch[msg.sender];
        uint256 cur = currentEpoch();
        uint256 limit = fromEpoch + MAX_EPOCHS_PER_CLAIM;
        if (limit > cur) limit = cur;

        // Sweep ahead first so `bonusEmissions[e]` is set for every epoch we are about to walk.
        // If the sweeper is still catching up, clamp our walk to what's been swept.
        _sweepUpTo(limit);
        if (limit > lastGlobalSweepEpoch) limit = lastGlobalSweepEpoch;

        for (uint256 e = fromEpoch; e < limit; e++) {
            amount += earnedInEpoch(msg.sender, e);
        }

        nextClaimEpoch[msg.sender] = limit;

        if (amount > 0) {
            emissionsVault.release(msg.sender, amount);
        }
        emit EmissionsClaimed(msg.sender, fromEpoch, limit, amount);
    }

    /// @notice Self-only fast-forward of the caller's claim cursor across epochs where they had
    ///         zero voting power. Useful for users who joined late and want to skip ahead without
    ///         paying the gas of walking a full year of empty epochs in `claim()`.
    /// @dev Verifies *every* skipped epoch has zero personal votes so we never silently burn
    ///      rewards, and is restricted to `msg.sender` so no one can advance another account's
    ///      cursor past epochs where they did hold votes. The empty-epoch carry is preserved at
    ///      the protocol level via `pendingFromEmptyEpochs`, so skipping does not strand value
    ///      for other lockers.
    function skipEpochs(uint256 epochs) external {
        require(startTime != 0, "not started");
        require(epochs > 0 && epochs <= MAX_EPOCHS_PER_CLAIM, "bad epochs");
        uint256 cur = currentEpoch();
        uint256 from = nextClaimEpoch[msg.sender];
        uint256 target = from + epochs;
        if (target > cur) target = cur;
        // Make sure the sweep has consumed the empties we are about to skip past so the
        // protocol-level pendingFromEmptyEpochs reflects everything.
        _sweepUpTo(target);
        for (uint256 e = from; e < target; e++) {
            require(userVotesAt(msg.sender, e) == 0, "would burn rewards");
        }
        nextClaimEpoch[msg.sender] = target;
    }

    /// @dev Walks finished epochs from `lastGlobalSweepEpoch` up to `min(target, currentEpoch())`
    ///      and capped to `MAX_EPOCHS_PER_CLAIM` per call. Empty epochs (total votes = 0) have
    ///      their `epochEmissions` accumulated into `pendingFromEmptyEpochs`. The first
    ///      non-empty epoch crossed receives the accumulated pending via `bonusEmissions`.
    function _sweepUpTo(uint256 target) internal returns (uint256) {
        uint256 cur = currentEpoch();
        if (target > cur) target = cur;
        uint256 capped = lastGlobalSweepEpoch + MAX_EPOCHS_PER_CLAIM;
        if (target > capped) target = capped;
        if (target <= lastGlobalSweepEpoch) return lastGlobalSweepEpoch;

        uint256 pending = pendingFromEmptyEpochs;
        uint256 startFrom = lastGlobalSweepEpoch;
        uint256 folded;
        uint256 foldedInto;
        for (uint256 e = startFrom; e < target; e++) {
            uint256 total = totalVotesAt(e);
            if (total == 0) {
                pending += epochEmissions(e);
            } else if (pending > 0) {
                bonusEmissions[e] += pending;
                folded = pending;
                foldedInto = e;
                pending = 0;
            }
        }
        pendingFromEmptyEpochs = pending;
        lastGlobalSweepEpoch = target;
        emit EmptyEpochsSwept(startFrom, target, foldedInto, folded, pending);
        return target;
    }

    // ── Owner ─────────────────────────────────────────────────────────────────

    /// @notice Emergency: recover non-BDX tokens accidentally sent here.
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    // ── Internal: rate schedule ──────────────────────────────────────────────

    /// @dev Emissions over the half-open interval [from, to). Walks year boundaries inside the range.
    function _emittedBetween(uint256 from, uint256 to) internal view returns (uint256 emitted) {
        if (to <= from || startTime == 0) return 0;
        uint256 cursor = from;
        while (cursor < to) {
            uint256 elapsed = cursor - startTime;
            uint256 yearIdx = elapsed / YEAR;
            if (yearIdx >= 4) break; // emissions ended
            uint256 yearEnd = startTime + (yearIdx + 1) * YEAR;
            uint256 segmentEnd = to < yearEnd ? to : yearEnd;
            uint256 rate;
            if (yearIdx == 0) rate = RATE_YEAR_1;
            else if (yearIdx == 1) rate = RATE_YEAR_2;
            else if (yearIdx == 2) rate = RATE_YEAR_3;
            else rate = RATE_YEAR_4;
            emitted += (segmentEnd - cursor) * rate;
            cursor = segmentEnd;
        }
    }
}
