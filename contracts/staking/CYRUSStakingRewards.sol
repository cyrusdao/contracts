// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.31;

// @luxfi/standard unified imports - DO NOT import @openzeppelin directly
import {IERC20, SafeERC20} from "@luxfi/standard/tokens/ERC20.sol";
import {ReentrancyGuard, Pausable} from "@luxfi/standard/utils/Utils.sol";
import {AccessControl} from "@luxfi/standard/access/Access.sol";

/**
 * @title CYRUSStakingRewards
 * @author Cyrus Protocol
 * @notice Distributes PARS governance tokens to xCYRUS stakers
 * @dev Mints PARS rewards based on xCYRUS stake duration and amount
 *
 * REWARD MECHANISM:
 * ┌─────────────────────────────────────────────────────────────────────────────┐
 * │                      CYRUSStakingRewards                                    │
 * ├─────────────────────────────────────────────────────────────────────────────┤
 * │                                                                             │
 * │  ┌───────────────┐                        ┌───────────────┐                │
 * │  │ xCYRUS        │ ────── stake ────────► │ This Contract │                │
 * │  │ (yield vault) │                        │ (tracks time) │                │
 * │  └───────────────┘                        └───────┬───────┘                │
 * │                                                   │                         │
 * │                                           claim rewards                     │
 * │                                                   │                         │
 * │                                                   ▼                         │
 * │                                           ┌───────────────┐                │
 * │                                           │ PARS Token    │                │
 * │                                           │ (minted)      │                │
 * │                                           └───────────────┘                │
 * │                                                                             │
 * │  Reward Rate: ~11% APY in PARS (governance rewards for CYRUS stakers)      │
 * │  • Daily: ~0.03% of staked xCYRUS                                          │
 * │  • Accrues per second, claimable anytime                                   │
 * │                                                                             │
 * └─────────────────────────────────────────────────────────────────────────────┘
 *
 * @custom:security-contact security@cyrus.cash
 */

interface IPARSMintable {
    function mint(address to, uint256 amount) external;
    function mintWithReason(address to, uint256 amount, bytes32 reason) external;
}

contract CYRUSStakingRewards is ReentrancyGuard, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    // ============ Roles ============

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // ============ Constants ============

    uint256 public constant BPS = 10_000;
    uint256 public constant YEAR = 365 days;

    /// @notice Reward reason for PARS minting
    bytes32 public constant REWARD_REASON_STAKING = keccak256("CYRUS_STAKING_REWARDS");

    // ============ Immutables ============

    /// @notice xCYRUS token (staking receipt)
    IERC20 public immutable xCYRUS;

    /// @notice PARS governance token (reward)
    IPARSMintable public immutable pars;

    // ============ State ============

    /// @notice Annual reward rate in basis points (1100 = 11% APY)
    uint256 public rewardRateBps = 1100;

    /// @notice Maximum annual reward rate
    uint256 public constant MAX_REWARD_RATE_BPS = 5000; // 50% max

    /// @notice User staking info
    struct UserInfo {
        uint256 amount;           // xCYRUS staked in this contract
        uint256 rewardDebt;       // Reward debt for calculation
        uint256 lastUpdate;       // Last claim timestamp
        uint256 pendingRewards;   // Unclaimed rewards
    }

    mapping(address => UserInfo) public userInfo;

    /// @notice Total xCYRUS staked in this contract
    uint256 public totalStaked;

    /// @notice Total PARS rewards distributed
    uint256 public totalRewardsDistributed;

    /// @notice Accumulated rewards per share (scaled by 1e18)
    uint256 public accRewardsPerShare;

    /// @notice Last reward update timestamp
    uint256 public lastRewardTime;

    // ============ Events ============

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);

    // ============ Errors ============

    error ZeroAmount();
    error ZeroAddress();
    error InsufficientBalance();
    error InvalidRate();

    // ============ Constructor ============

    constructor(
        address _xCYRUS,
        address _pars,
        address _timelock
    ) {
        if (_xCYRUS == address(0) || _pars == address(0)) {
            revert ZeroAddress();
        }

        xCYRUS = IERC20(_xCYRUS);
        pars = IPARSMintable(_pars);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, _timelock != address(0) ? _timelock : msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);

        lastRewardTime = block.timestamp;
    }

    // ============ User Actions ============

    /**
     * @notice Stake xCYRUS to earn PARS rewards
     * @param amount Amount of xCYRUS to stake
     */
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        // Update rewards
        _updateRewards();

        UserInfo storage user = userInfo[msg.sender];

        // Claim pending rewards if any
        if (user.amount > 0) {
            uint256 pending = _pendingRewards(msg.sender);
            if (pending > 0) {
                user.pendingRewards += pending;
            }
        }

        // Transfer xCYRUS from user
        xCYRUS.safeTransferFrom(msg.sender, address(this), amount);

        // Update user info
        user.amount += amount;
        user.lastUpdate = block.timestamp;
        user.rewardDebt = (user.amount * accRewardsPerShare) / 1e18;
        totalStaked += amount;

        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Withdraw staked xCYRUS
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        UserInfo storage user = userInfo[msg.sender];
        if (user.amount < amount) revert InsufficientBalance();

        // Update rewards
        _updateRewards();

        // Calculate pending rewards
        uint256 pending = _pendingRewards(msg.sender);
        if (pending > 0) {
            user.pendingRewards += pending;
        }

        // Update user info
        user.amount -= amount;
        user.lastUpdate = block.timestamp;
        user.rewardDebt = (user.amount * accRewardsPerShare) / 1e18;
        totalStaked -= amount;

        // Transfer xCYRUS back to user
        xCYRUS.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @notice Claim accumulated PARS rewards
     * @return rewards Amount of PARS claimed
     */
    function claimRewards() external nonReentrant whenNotPaused returns (uint256 rewards) {
        // Update rewards
        _updateRewards();

        UserInfo storage user = userInfo[msg.sender];

        // Calculate total pending
        uint256 pending = _pendingRewards(msg.sender);
        rewards = user.pendingRewards + pending;

        if (rewards > 0) {
            // Reset pending
            user.pendingRewards = 0;
            user.lastUpdate = block.timestamp;
            user.rewardDebt = (user.amount * accRewardsPerShare) / 1e18;

            // Mint PARS rewards
            pars.mintWithReason(msg.sender, rewards, REWARD_REASON_STAKING);
            totalRewardsDistributed += rewards;

            emit RewardsClaimed(msg.sender, rewards);
        }
    }

    /**
     * @notice Stake and claim in one transaction
     * @param amount Amount of xCYRUS to stake
     */
    function stakeAndClaim(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        // Update rewards
        _updateRewards();

        UserInfo storage user = userInfo[msg.sender];

        // Claim pending rewards first
        uint256 pending = _pendingRewards(msg.sender);
        uint256 rewards = user.pendingRewards + pending;

        if (rewards > 0) {
            user.pendingRewards = 0;
            pars.mintWithReason(msg.sender, rewards, REWARD_REASON_STAKING);
            totalRewardsDistributed += rewards;
            emit RewardsClaimed(msg.sender, rewards);
        }

        // Then stake
        xCYRUS.safeTransferFrom(msg.sender, address(this), amount);

        user.amount += amount;
        user.lastUpdate = block.timestamp;
        user.rewardDebt = (user.amount * accRewardsPerShare) / 1e18;
        totalStaked += amount;

        emit Staked(msg.sender, amount);
    }

    // ============ View Functions ============

    /**
     * @notice Get pending rewards for user
     * @param account User address
     * @return pending Pending PARS rewards
     */
    function pendingRewards(address account) external view returns (uint256 pending) {
        UserInfo memory user = userInfo[account];

        // Calculate updated accRewardsPerShare
        uint256 _accRewardsPerShare = accRewardsPerShare;
        if (block.timestamp > lastRewardTime && totalStaked > 0) {
            uint256 timeElapsed = block.timestamp - lastRewardTime;
            uint256 reward = (totalStaked * rewardRateBps * timeElapsed) / (BPS * YEAR);
            _accRewardsPerShare += (reward * 1e18) / totalStaked;
        }

        pending = user.pendingRewards;
        if (user.amount > 0) {
            pending += (user.amount * _accRewardsPerShare) / 1e18 - user.rewardDebt;
        }
    }

    /**
     * @notice Get user's staking info
     * @param account User address
     */
    function getStakeInfo(address account) external view returns (
        uint256 stakedAmount,
        uint256 pendingPARS,
        uint256 lastClaim
    ) {
        UserInfo memory user = userInfo[account];
        stakedAmount = user.amount;
        lastClaim = user.lastUpdate;

        // Calculate pending
        uint256 _accRewardsPerShare = accRewardsPerShare;
        if (block.timestamp > lastRewardTime && totalStaked > 0) {
            uint256 timeElapsed = block.timestamp - lastRewardTime;
            uint256 reward = (totalStaked * rewardRateBps * timeElapsed) / (BPS * YEAR);
            _accRewardsPerShare += (reward * 1e18) / totalStaked;
        }

        pendingPARS = user.pendingRewards;
        if (user.amount > 0) {
            pendingPARS += (user.amount * _accRewardsPerShare) / 1e18 - user.rewardDebt;
        }
    }

    /**
     * @notice Calculate APY for display
     * @return apy Current APY in basis points
     */
    function currentAPY() external view returns (uint256 apy) {
        return rewardRateBps;
    }

    // ============ Governance ============

    /**
     * @notice Update reward rate
     * @param newRateBps New rate in basis points
     */
    function setRewardRate(uint256 newRateBps) external onlyRole(GOVERNANCE_ROLE) {
        if (newRateBps > MAX_REWARD_RATE_BPS) revert InvalidRate();

        // Update rewards before changing rate
        _updateRewards();

        emit RewardRateUpdated(rewardRateBps, newRateBps);
        rewardRateBps = newRateBps;
    }

    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }

    // ============ Internal ============

    function _updateRewards() internal {
        if (block.timestamp <= lastRewardTime) {
            return;
        }

        if (totalStaked == 0) {
            lastRewardTime = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - lastRewardTime;
        uint256 reward = (totalStaked * rewardRateBps * timeElapsed) / (BPS * YEAR);

        accRewardsPerShare += (reward * 1e18) / totalStaked;
        lastRewardTime = block.timestamp;
    }

    function _pendingRewards(address account) internal view returns (uint256) {
        UserInfo memory user = userInfo[account];
        if (user.amount == 0) return 0;

        return (user.amount * accRewardsPerShare) / 1e18 - user.rewardDebt;
    }
}
