// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

// @luxfi/standard unified imports - DO NOT import @openzeppelin directly
import {IERC20, SafeERC20} from "@luxfi/standard/tokens/ERC20.sol";
import {ReentrancyGuard} from "@luxfi/standard/utils/Utils.sol";
import {Ownable2Step, Ownable} from "@luxfi/standard/access/Access.sol";

/// @title CyrusRewardsGauge - LP Staking Rewards
/// @notice Receives PARS emissions and distributes them to LP stakers
/// @dev Stakers deposit LP tokens and earn PARS rewards proportionally
/// @custom:security-contact security@cyrus.cash
contract CyrusRewardsGauge is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Precision for reward calculations
    uint256 public constant PRECISION = 1e18;

    /// @notice Default reward duration (7 days)
    uint256 public constant DEFAULT_DURATION = 7 days;

    // ═══════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice LP token to stake
    IERC20 public immutable stakingToken;

    /// @notice PARS reward token
    IERC20 public immutable rewardToken;

    /// @notice GaugeController that distributes emissions
    address public gaugeController;

    /// @notice Human-readable name
    string public name;

    /// @notice Duration of rewards
    uint256 public rewardsDuration;

    /// @notice Timestamp when current rewards period ends
    uint256 public periodFinish;

    /// @notice Reward rate (tokens per second)
    uint256 public rewardRate;

    /// @notice Last time rewards were updated
    uint256 public lastUpdateTime;

    /// @notice Accumulated reward per staked token
    uint256 public rewardPerTokenStored;

    /// @notice Total staked LP tokens
    uint256 public totalSupply;

    /// @notice User staked balances
    mapping(address => uint256) public balanceOf;

    /// @notice Reward per token paid to user
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Pending rewards for user
    mapping(address => uint256) public rewards;

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 reward);
    event RewardNotified(uint256 reward, uint256 duration);
    event GaugeControllerSet(address indexed controller);
    event RewardsDurationSet(uint256 duration);

    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error ZeroAmount();
    error NotGaugeController();
    error RewardPeriodNotComplete();
    error RewardTooHigh();
    error InsufficientBalance();

    // ═══════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Initialize the RewardsGauge
    /// @param _stakingToken LP token to stake
    /// @param _rewardToken PARS token for rewards
    /// @param _name Human-readable name
    /// @param initialOwner Governance address
    constructor(
        address _stakingToken,
        address _rewardToken,
        string memory _name,
        address initialOwner
    ) Ownable(initialOwner) {
        if (_stakingToken == address(0) || _rewardToken == address(0)) revert ZeroAddress();

        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
        name = _name;
        rewardsDuration = DEFAULT_DURATION;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STAKING
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Stake LP tokens
    /// @param amount Amount to stake
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();

        totalSupply += amount;
        balanceOf[msg.sender] += amount;

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    /// @notice Withdraw staked LP tokens
    /// @param amount Amount to withdraw
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        _withdrawInternal(amount);
    }

    /// @notice Internal withdraw logic
    function _withdrawInternal(uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();

        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;

        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claim pending PARS rewards
    /// @return reward Amount of PARS claimed
    function claimReward() external nonReentrant updateReward(msg.sender) returns (uint256 reward) {
        reward = rewards[msg.sender];

        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardClaimed(msg.sender, reward);
        }
    }

    /// @notice Withdraw all and claim rewards
    function exit() external nonReentrant updateReward(msg.sender) {
        _withdrawInternal(balanceOf[msg.sender]);
        _claimRewardInternal();
    }

    /// @notice Internal claim logic
    function _claimRewardInternal() internal {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardClaimed(msg.sender, reward);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // REWARD DISTRIBUTION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Notify new rewards (called by GaugeController or owner)
    /// @param reward Amount of PARS to distribute
    function notifyRewardAmount(uint256 reward) external updateReward(address(0)) {
        if (msg.sender != gaugeController && msg.sender != owner()) revert NotGaugeController();

        // Transfer rewards from caller
        rewardToken.safeTransferFrom(msg.sender, address(this), reward);

        if (block.timestamp >= periodFinish) {
            // New reward period
            rewardRate = reward / rewardsDuration;
        } else {
            // Add to existing period
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }

        // Sanity check: reward rate must not exceed balance
        uint256 balance = rewardToken.balanceOf(address(this));
        if (rewardRate > balance / rewardsDuration) revert RewardTooHigh();

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;

        emit RewardNotified(reward, rewardsDuration);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Last time reward is applicable (now or period end)
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// @notice Current reward per token
    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) {
            return rewardPerTokenStored;
        }

        return rewardPerTokenStored + (
            (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION / totalSupply
        );
    }

    /// @notice Calculate earned rewards for user
    /// @param account User address
    /// @return Earned PARS amount
    function earned(address account) public view returns (uint256) {
        return (
            balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account]) / PRECISION
        ) + rewards[account];
    }

    /// @notice Remaining rewards for current period
    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    /// @notice Time until reward period ends
    function timeUntilPeriodEnd() external view returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        return periodFinish - block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS (Owner = Governance)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Set the GaugeController address
    /// @param _gaugeController New controller address
    function setGaugeController(address _gaugeController) external onlyOwner {
        gaugeController = _gaugeController;
        emit GaugeControllerSet(_gaugeController);
    }

    /// @notice Set rewards duration for future periods
    /// @param _duration New duration in seconds
    function setRewardsDuration(uint256 _duration) external onlyOwner {
        if (block.timestamp < periodFinish) revert RewardPeriodNotComplete();
        rewardsDuration = _duration;
        emit RewardsDurationSet(_duration);
    }

    /// @notice Recover accidentally sent tokens (not staking or reward token)
    /// @param token Token address to recover
    /// @param amount Amount to recover
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        require(token != address(stakingToken), "Cannot recover staking token");
        require(token != address(rewardToken), "Cannot recover reward token");
        IERC20(token).safeTransfer(owner(), amount);
    }
}
