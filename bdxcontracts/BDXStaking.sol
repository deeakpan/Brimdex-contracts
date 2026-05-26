// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./sBDX.sol";

/**
 * @title BDXStaking
 * @notice Stake $BDX → mint sBDX 1:1 to wallet (like Uniswap V2 LP tokens)
 *         sBDX represents your share of the staking pool
 *         Earn USDC trade fees proportional to sBDX held
 *         Withdraw → burn sBDX → return $BDX 1:1
 *
 * sBDX flow:
 *   User deposits 1000 BDX
 *   → BDXStaking mints 1000 sBDX to user's wallet
 *   → User holds sBDX freely (transferable, can lock in VotingEscrow)
 *   → User withdraws: burns 1000 sBDX, receives 1000 BDX back
 *
 * USDC fee flow:
 *   Trade happens on Brimdex
 *   → 0.1% USDC fee collected
 *   → Prediction market calls notifyRewardAmount(usdcAmount)
 *   → USDC distributed proportionally to all sBDX holders via rewardPerToken accumulator
 *   → User calls claimUSDC() anytime — past rewards never lost
 *
 * Fee discount:
 *   Prediction market calls hasDiscount(user) before calculating fee
 *   If user staked >= 200,000 BDX → 25% discount applied
 *
 * Note: USDC rewards accrue based on sBDX balance at time of accumulation
 *       If user transfers sBDX out, new holder earns future rewards
 *       Past unclaimed rewards stay with original staker via checkpoint
 */
contract BDXStaking is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /* ========== TOKENS ========== */

    IERC20 public immutable BDX;    // $BDX — staking token
    SBDX public immutable sBDX;     // sBDX — receipt token minted 1:1
    IERC20 public immutable USDC;   // USDC — reward token from trade fees

    /// @notice BrimdexLMSRStackFactory — may register LMSR addresses as reward notifiers.
    address public stackFactory;
    mapping(address => bool) public authorizedRewardNotifier;

    /* ========== REWARD STATE ========== */

    uint256 public rewardsDuration = 7 days;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    /// @notice USDC pulled by `notifyRewardAmount` that did not fit into `rewardRate`
    ///         after integer division (i.e. `(reward + carry) % rewardsDuration`). Carried
    ///         forward into the next call so sub-duration trickles are never stranded.
    uint256 public undistributed;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public pendingUSDC;

    /* ========== CONSTANTS ========== */

    uint256 public constant DISCOUNT_THRESHOLD = 200_000e18; // 200,000 sBDX = 25% fee discount

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _bdx,
        address _sbdx,
        address _usdc
    ) Ownable(msg.sender) {
        BDX = IERC20(_bdx);
        sBDX = SBDX(_sbdx);
        USDC = IERC20(_usdc);
    }

    function setStackFactory(address factory) external onlyOwner {
        require(factory != address(0), "zero factory");
        stackFactory = factory;
    }

    /// @notice Called by `BrimdexLMSRStackFactory` once per deployed LMSR so markets can push staker fees.
    function authorizeRewardNotifier(address market) external {
        require(msg.sender == stackFactory, "only stack factory");
        require(market != address(0), "zero market");
        authorizedRewardNotifier[market] = true;
    }

    /* ========== VIEWS ========== */

    /// @notice Total sBDX in existence = total BDX staked
    function totalStaked() external view returns (uint256) {
        return sBDX.totalSupply();
    }

    /// @notice sBDX balance of user = their staked BDX amount
    function stakedBalance(address account) external view returns (uint256) {
        return sBDX.balanceOf(account);
    }

    /// @notice Called by prediction market to check fee discount eligibility
    function hasDiscount(address account) external view returns (bool) {
        return sBDX.balanceOf(account) >= DISCOUNT_THRESHOLD;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        uint256 supply = sBDX.totalSupply();
        if (supply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + (
            (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18 / supply
        );
    }

    /// @notice Claimable USDC for account — accumulates indefinitely until claimed
    function earnedUSDC(address account) public view returns (uint256) {
        return (
            sBDX.balanceOf(account) *
            (rewardPerToken() - userRewardPerTokenPaid[account]) / 1e18
        ) + pendingUSDC[account];
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice Stake $BDX → receive sBDX 1:1 in wallet
     * Like Uniswap V2: deposit tokens → get LP tokens minted to you
     * sBDX is a real ERC20 you hold and can transfer or lock in VotingEscrow
     */
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        BDX.safeTransferFrom(msg.sender, address(this), amount);
        sBDX.mint(msg.sender, amount); // mint 1:1 sBDX to user's wallet
        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Burn sBDX → receive $BDX 1:1 back
     * Like Uniswap V2: burn LP tokens → get underlying tokens back
     * Must have sBDX in wallet — if locked in VotingEscrow must unlock first
     */
    function withdraw(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        require(sBDX.balanceOf(msg.sender) >= amount, "Insufficient sBDX");
        sBDX.burn(msg.sender, amount); // burn sBDX from user's wallet
        BDX.safeTransfer(msg.sender, amount); // return BDX 1:1
        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @notice Claim accumulated USDC trade fee rewards
     * Callable anytime — no expiry, no daily requirement
     * Accumulates from all trades since last claim
     */
    function claimUSDC() external nonReentrant updateReward(msg.sender) {
        uint256 reward = pendingUSDC[msg.sender];
        if (reward > 0) {
            pendingUSDC[msg.sender] = 0;
            USDC.safeTransfer(msg.sender, reward);
            emit USDCClaimed(msg.sender, reward);
        }
    }

    /// @notice Withdraw all BDX and claim all USDC in one tx.
    /// @dev    Must inline (not call `this.withdraw` / `this.claimUSDC`) because external
    ///         self-calls would set `msg.sender == address(this)` inside the callees, which
    ///         operates on the contract's own zero sBDX balance instead of the user's.
    function exit() external nonReentrant updateReward(msg.sender) {
        uint256 bal = sBDX.balanceOf(msg.sender);
        if (bal > 0) {
            sBDX.burn(msg.sender, bal);
            BDX.safeTransfer(msg.sender, bal);
            emit Withdrawn(msg.sender, bal);
        }
        uint256 reward = pendingUSDC[msg.sender];
        if (reward > 0) {
            pendingUSDC[msg.sender] = 0;
            USDC.safeTransfer(msg.sender, reward);
            emit USDCClaimed(msg.sender, reward);
        }
    }

    /* ========== RESTRICTED ========== */

    /**
     * @notice Called by Brimdex prediction market after collecting USDC trade fee share for stakers.
     *         Callable by owner or by an LMSR registered via `authorizeRewardNotifier`.
     */
    function notifyRewardAmount(uint256 reward) external nonReentrant updateReward(address(0)) {
        require(msg.sender == owner() || authorizedRewardNotifier[msg.sender], "not notifier");
        USDC.safeTransferFrom(msg.sender, address(this), reward);

        // Roll forward any sub-duration dust from previous notifications so that
        // tiny per-trade USDC fees do not get truncated to zero by integer division.
        uint256 effective = reward + undistributed;
        if (block.timestamp >= periodFinish) {
            rewardRate = effective / rewardsDuration;
            undistributed = effective - rewardRate * rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            uint256 pool = effective + leftover;
            rewardRate = pool / rewardsDuration;
            undistributed = pool - rewardRate * rewardsDuration;
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(block.timestamp > periodFinish, "Previous period not finished");
        rewardsDuration = _rewardsDuration;
    }

    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(BDX), "Cannot recover BDX");
        require(tokenAddress != address(USDC), "Cannot recover USDC");
        require(tokenAddress != address(sBDX), "Cannot recover sBDX");
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
    }

    /* ========== MODIFIERS ========== */

    /**
     * @notice Checkpoint reward state before any balance change
     * Snapshots pending USDC earned so far before sBDX balance changes
     * Prevents rewards being lost when sBDX is transferred or burned
     */
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            pendingUSDC[account] = earnedUSDC(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /* ========== EVENTS ========== */

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event USDCClaimed(address indexed user, uint256 amount);
    event RewardAdded(uint256 reward);
}
