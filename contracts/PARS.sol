// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.31;

// @luxfi/standard unified imports - DO NOT import @openzeppelin directly
import {ERC20, ERC20Permit, ERC20Votes, IERC20, SafeERC20} from "@luxfi/standard/tokens/ERC20.sol";
import {ReentrancyGuard, Pausable, Nonces} from "@luxfi/standard/utils/Utils.sol";
import {AccessControl} from "@luxfi/standard/access/Access.sol";

/**
 * @title PARS - Rebasing Governance Token with Demurrage
 * @author Cyrus Protocol
 * @notice Shariah-compliant governance token earned by CYRUS stakers
 * @dev Based on luxfi-standard DLUX architecture
 *
 * ISLAMIC FINANCE PRINCIPLES:
 * - Profit-sharing: Earned as rewards for contributing to protocol (staking)
 * - No hoarding incentive: Demurrage discourages unproductive holding
 * - Community benefit: Rebase rewards active participants
 *
 * TOKENOMICS:
 * ┌─────────────────────────────────────────────────────────────────────────────┐
 * │  PARS is a rebasing governance token earned by CYRUS stakers               │
 * │                                                                             │
 * │  Properties:                                                                │
 * │  - Earned: By staking CYRUS (xCYRUS holders receive PARS emissions)        │
 * │  - Rebase Rate: 0.1% per epoch (24 hours) for staked PARS                  │
 * │  - Demurrage: 0.1% per day on unstaked PARS (encourages participation)     │
 * │  - Governance: Voting power for protocol decisions                          │
 * │                                                                             │
 * │  Staking Tiers:                                                             │
 * │  - Bronze (100+): 1.0x boost                                                │
 * │  - Silver (1K+): 1.1x boost, 7d lock                                        │
 * │  - Gold (10K+): 1.25x boost, 30d lock                                       │
 * │  - Diamond (100K+): 1.5x boost, 90d lock                                    │
 * │  - Quantum (1M+): 2.0x boost, 365d lock                                     │
 * │                                                                             │
 * │  Flow:                                                                      │
 * │  ┌──────────┐     mint     ┌──────────┐     stake     ┌──────────┐        │
 * │  │ xCYRUS   │ ──────────► │ PARS     │ ────────────► │ sPARS    │        │
 * │  │ stakers  │   rewards   │ (liquid) │   for boost   │ (staked) │        │
 * │  └──────────┘             └────┬─────┘               └──────────┘        │
 * │                                │                                          │
 * │                         demurrage if                                      │
 * │                          not staked                                       │
 * │                                │                                          │
 * │                                ▼                                          │
 * │                           burned 0.1%/day                                 │
 * └─────────────────────────────────────────────────────────────────────────────┘
 *
 * @custom:security-contact security@cyrus.cash
 */
contract PARS is ERC20, ERC20Permit, ERC20Votes, ReentrancyGuard, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    // ============ Roles ============

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant REBASE_ROLE = keccak256("REBASE_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // ============ Constants ============

    uint256 public constant BPS = 10_000;

    /// @notice Epoch duration (24 hours)
    uint256 public constant EPOCH_DURATION = 1 days;

    /// @notice Demurrage rate per day in basis points (10 = 0.1%)
    uint256 public constant DEMURRAGE_BPS = 10;

    /// @notice Maximum rebase rate per epoch in basis points (20 = 0.2%)
    uint256 public constant MAX_REBASE_RATE = 20;

    /// @notice Minimum rebase rate per epoch in basis points (5 = 0.05%)
    uint256 public constant MIN_REBASE_RATE = 5;

    /// @notice Staking tier thresholds
    uint256 public constant TIER_BRONZE = 100e18;
    uint256 public constant TIER_SILVER = 1_000e18;
    uint256 public constant TIER_GOLD = 10_000e18;
    uint256 public constant TIER_DIAMOND = 100_000e18;
    uint256 public constant TIER_QUANTUM = 1_000_000e18;

    /// @notice Lock periods per tier
    uint256 public constant LOCK_SILVER = 7 days;
    uint256 public constant LOCK_GOLD = 30 days;
    uint256 public constant LOCK_DIAMOND = 90 days;
    uint256 public constant LOCK_QUANTUM = 365 days;

    /// @notice Tier boosts in basis points (10000 = 1.0x)
    uint256 public constant BOOST_BRONZE = 10000;   // 1.0x
    uint256 public constant BOOST_SILVER = 11000;   // 1.1x
    uint256 public constant BOOST_GOLD = 12500;     // 1.25x
    uint256 public constant BOOST_DIAMOND = 15000;  // 1.5x
    uint256 public constant BOOST_QUANTUM = 20000;  // 2.0x

    // ============ Types ============

    enum Tier { None, Bronze, Silver, Gold, Diamond, Quantum }

    struct StakeInfo {
        uint256 amount;         // Amount staked
        uint256 lockEnd;        // Lock end timestamp
        uint256 lastRebase;     // Last rebase claim timestamp
        uint256 pendingRebase;  // Accumulated unclaimed rebases
        Tier tier;              // Current tier
    }

    struct DemurrageInfo {
        uint256 balance;        // Balance subject to demurrage
        uint256 lastUpdate;     // Last demurrage calculation timestamp
    }

    // ============ State ============

    /// @notice Current rebase rate in basis points
    uint256 public rebaseRate;

    /// @notice Current epoch
    uint256 public epoch;

    /// @notice Last epoch timestamp
    uint256 public lastEpochTime;

    /// @notice Total staked PARS
    uint256 public totalStaked;

    /// @notice Protocol treasury address
    address public treasury;

    /// @notice Staking info per user
    mapping(address => StakeInfo) public stakes;

    /// @notice Demurrage tracking for unstaked balances
    mapping(address => DemurrageInfo) private _demurrage;

    /// @notice Total PARS minted as rewards
    uint256 public totalRewardsMinted;

    /// @notice Total PARS burned from demurrage
    uint256 public totalDemurrageBurned;

    /// @notice Total PARS rebased
    uint256 public totalRebased;

    // ============ Events ============

    event Staked(address indexed user, uint256 amount, Tier tier, uint256 lockEnd);
    event Unstaked(address indexed user, uint256 amount);
    event RebaseClaimed(address indexed user, uint256 amount);
    event Rebased(uint256 epoch, uint256 totalRebased, uint256 rate);
    event DemurrageApplied(address indexed account, uint256 burned);
    event TierUpgraded(address indexed user, Tier from, Tier to);
    event RebaseRateUpdated(uint256 oldRate, uint256 newRate);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event RewardsMinted(address indexed to, uint256 amount, bytes32 indexed reason);

    // ============ Errors ============

    error ZeroAmount();
    error ZeroAddress();
    error InsufficientBalance();
    error LockNotExpired();
    error InvalidTier();
    error InvalidRebaseRate();
    error EpochNotReady();
    error DowngradeTier();

    // ============ Constructor ============

    constructor(
        address _treasury,
        address _timelock
    ) ERC20("PARS Governance", "PARS") ERC20Permit("PARS Governance") {
        if (_treasury == address(0)) revert ZeroAddress();

        treasury = _treasury;
        rebaseRate = 10; // 0.1% per 24hr epoch default

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, _timelock != address(0) ? _timelock : msg.sender);
        _grantRole(REBASE_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);

        lastEpochTime = block.timestamp;
    }

    // ============ Minter Functions ============

    /**
     * @notice Simple mint function (IPARS interface compatible)
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mintWithTracking(to, amount, keccak256("MINT"));
    }

    /**
     * @notice Mint PARS as rewards with reason logging
     * @param to Recipient address
     * @param amount Amount to mint
     * @param reason Reason for minting (for logging)
     */
    function mintWithReason(address to, uint256 amount, bytes32 reason) external onlyRole(MINTER_ROLE) {
        _mintWithTracking(to, amount, reason);
    }

    /**
     * @notice Burn PARS tokens from caller
     * @param amount Amount to burn
     */
    function burn(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _applyDemurrage(msg.sender);
        _burn(msg.sender, amount);
    }

    /**
     * @notice Batch mint PARS to multiple recipients
     * @param recipients Array of addresses
     * @param amounts Array of amounts
     * @param reason Shared reason
     */
    function batchMint(
        address[] calldata recipients,
        uint256[] calldata amounts,
        bytes32 reason
    ) external onlyRole(MINTER_ROLE) {
        require(recipients.length == amounts.length, "Length mismatch");

        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == address(0)) continue;
            if (amounts[i] == 0) continue;
            _mintWithTracking(recipients[i], amounts[i], reason);
        }
    }

    function _mintWithTracking(address to, uint256 amount, bytes32 reason) internal {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _mint(to, amount);
        totalRewardsMinted += amount;

        // Initialize demurrage tracking
        DemurrageInfo storage dem = _demurrage[to];
        if (dem.lastUpdate == 0) {
            dem.lastUpdate = block.timestamp;
        }

        emit RewardsMinted(to, amount, reason);
    }

    // ============ Staking Functions ============

    /**
     * @notice Stake PARS to earn rebases and avoid demurrage
     * @param amount Amount to stake
     * @param tier Desired staking tier
     */
    function stake(uint256 amount, Tier tier) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (tier == Tier.None) revert InvalidTier();

        // Apply demurrage first
        _applyDemurrage(msg.sender);

        // Validate tier requirements
        uint256 newTotal = stakes[msg.sender].amount + amount;
        _validateTier(tier, newTotal);

        // Claim pending rebases first
        StakeInfo storage info = stakes[msg.sender];
        if (info.pendingRebase > 0) {
            _claimRebase(msg.sender);
        }

        // Calculate lock period
        uint256 lockPeriod = _getLockPeriod(tier);
        uint256 newLockEnd = block.timestamp + lockPeriod;

        // Only extend lock, never reduce
        if (newLockEnd < info.lockEnd) {
            newLockEnd = info.lockEnd;
        }

        // Check for tier upgrade
        Tier oldTier = info.tier;
        if (tier > oldTier) {
            emit TierUpgraded(msg.sender, oldTier, tier);
        } else if (tier < oldTier) {
            revert DowngradeTier();
        }

        info.amount = newTotal;
        info.lockEnd = newLockEnd;
        info.lastRebase = block.timestamp;
        info.tier = tier;

        totalStaked += amount;

        emit Staked(msg.sender, amount, tier, newLockEnd);
    }

    /**
     * @notice Unstake PARS (after lock expires)
     * @param amount Amount to unstake
     */
    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        StakeInfo storage info = stakes[msg.sender];
        if (amount > info.amount) revert InsufficientBalance();
        if (block.timestamp < info.lockEnd) revert LockNotExpired();

        // Claim pending rebases first
        if (info.pendingRebase > 0) {
            _claimRebase(msg.sender);
        }

        info.amount -= amount;
        totalStaked -= amount;

        // Update tier if needed
        if (info.amount < _getTierMinimum(info.tier)) {
            info.tier = _calculateTier(info.amount);
        }

        // Initialize demurrage tracking for newly unstaked tokens
        DemurrageInfo storage dem = _demurrage[msg.sender];
        dem.lastUpdate = block.timestamp;

        emit Unstaked(msg.sender, amount);
    }

    /**
     * @notice Claim accumulated rebases
     * @return rebased Amount claimed
     */
    function claimRebase() external nonReentrant whenNotPaused returns (uint256 rebased) {
        return _claimRebase(msg.sender);
    }

    /**
     * @notice Apply demurrage to unstaked balance (anyone can call)
     * @param account Address to apply demurrage
     */
    function applyDemurrage(address account) external {
        _applyDemurrage(account);
    }

    /**
     * @notice Trigger epoch rebase (callable by anyone when ready)
     */
    function rebase() external nonReentrant whenNotPaused {
        if (block.timestamp < lastEpochTime + EPOCH_DURATION) revert EpochNotReady();

        uint256 epochs = (block.timestamp - lastEpochTime) / EPOCH_DURATION;
        if (epochs == 0) revert EpochNotReady();

        // Update epoch tracking
        epoch += epochs;
        lastEpochTime = lastEpochTime + (epochs * EPOCH_DURATION);

        // Calculate total rebase amount
        uint256 epochRebased = (totalStaked * rebaseRate * epochs) / BPS;
        totalRebased += epochRebased;

        emit Rebased(epoch, epochRebased, rebaseRate);
    }

    // ============ View Functions ============

    /**
     * @notice Get pending rebase amount
     * @param account Address to query
     */
    function pendingRebase(address account) external view returns (uint256 pending) {
        StakeInfo memory info = stakes[account];
        if (info.amount == 0) return 0;

        pending = info.pendingRebase;

        // Calculate additional rebases since last claim
        uint256 epochsSince = (block.timestamp - info.lastRebase) / EPOCH_DURATION;
        if (epochsSince > 0) {
            uint256 boost = _getTierBoost(info.tier);
            uint256 epochRebase = (info.amount * rebaseRate * boost) / (BPS * BPS);
            pending += epochRebase * epochsSince;
        }
    }

    /**
     * @notice Get effective balance after demurrage
     * @param account Address to query
     */
    function effectiveBalance(address account) external view returns (uint256) {
        uint256 staked = stakes[account].amount;
        uint256 balance = balanceOf(account);
        uint256 unstaked = balance > staked ? balance - staked : 0;

        if (unstaked == 0) return staked;

        // Calculate demurrage on unstaked portion
        DemurrageInfo memory dem = _demurrage[account];
        if (dem.lastUpdate == 0) {
            return staked + unstaked;
        }

        uint256 daysPassed = (block.timestamp - dem.lastUpdate) / 1 days;
        if (daysPassed > 0) {
            // Compound demurrage
            for (uint256 i = 0; i < daysPassed && i < 365; i++) {
                unstaked = (unstaked * (BPS - DEMURRAGE_BPS)) / BPS;
            }
        }

        return staked + unstaked;
    }

    /**
     * @notice Get stake details
     * @param account Address to query
     */
    function getStake(address account) external view returns (
        uint256 amount,
        uint256 lockEnd,
        Tier tier,
        uint256 boost
    ) {
        StakeInfo memory info = stakes[account];
        return (info.amount, info.lockEnd, info.tier, _getTierBoost(info.tier));
    }

    /**
     * @notice Get tier info
     * @param account Address to query
     */
    function tierOf(address account) external view returns (Tier tier, uint256 boost) {
        tier = stakes[account].tier;
        boost = _getTierBoost(tier);
    }

    // ============ Governance ============

    function setRebaseRate(uint256 newRate) external onlyRole(GOVERNANCE_ROLE) {
        if (newRate < MIN_REBASE_RATE || newRate > MAX_REBASE_RATE) {
            revert InvalidRebaseRate();
        }
        emit RebaseRateUpdated(rebaseRate, newRate);
        rebaseRate = newRate;
    }

    function setTreasury(address newTreasury) external onlyRole(GOVERNANCE_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }

    // ============ Internal ============

    function _claimRebase(address account) internal returns (uint256 rebased) {
        StakeInfo storage info = stakes[account];
        if (info.amount == 0) return 0;

        // Calculate epochs since last claim
        uint256 epochsSince = (block.timestamp - info.lastRebase) / EPOCH_DURATION;

        if (epochsSince > 0) {
            uint256 boost = _getTierBoost(info.tier);
            uint256 epochRebase = (info.amount * rebaseRate * boost) / (BPS * BPS);
            info.pendingRebase += epochRebase * epochsSince;
        }

        rebased = info.pendingRebase;
        if (rebased > 0) {
            info.pendingRebase = 0;
            info.lastRebase = block.timestamp;

            // Mint rebased PARS
            _mint(account, rebased);
            totalRebased += rebased;

            emit RebaseClaimed(account, rebased);
        }
    }

    function _applyDemurrage(address account) internal {
        uint256 staked = stakes[account].amount;
        uint256 total = balanceOf(account);
        uint256 unstaked = total > staked ? total - staked : 0;

        if (unstaked == 0) return;

        DemurrageInfo storage dem = _demurrage[account];
        if (dem.lastUpdate == 0) {
            dem.balance = unstaked;
            dem.lastUpdate = block.timestamp;
            return;
        }

        uint256 daysPassed = (block.timestamp - dem.lastUpdate) / 1 days;
        if (daysPassed == 0) return;

        // Calculate demurrage
        uint256 remaining = unstaked;
        for (uint256 i = 0; i < daysPassed && i < 365; i++) {
            remaining = (remaining * (BPS - DEMURRAGE_BPS)) / BPS;
        }

        uint256 burned = unstaked - remaining;
        if (burned > 0) {
            _burn(account, burned);
            totalDemurrageBurned += burned;
            emit DemurrageApplied(account, burned);
        }

        dem.balance = remaining;
        dem.lastUpdate = block.timestamp;
    }

    function _validateTier(Tier tier, uint256 amount) internal pure {
        uint256 minimum = _getTierMinimum(tier);
        if (amount < minimum) revert InvalidTier();
    }

    function _getTierMinimum(Tier tier) internal pure returns (uint256) {
        if (tier == Tier.Quantum) return TIER_QUANTUM;
        if (tier == Tier.Diamond) return TIER_DIAMOND;
        if (tier == Tier.Gold) return TIER_GOLD;
        if (tier == Tier.Silver) return TIER_SILVER;
        if (tier == Tier.Bronze) return TIER_BRONZE;
        return 0;
    }

    function _getTierBoost(Tier tier) internal pure returns (uint256) {
        if (tier == Tier.Quantum) return BOOST_QUANTUM;
        if (tier == Tier.Diamond) return BOOST_DIAMOND;
        if (tier == Tier.Gold) return BOOST_GOLD;
        if (tier == Tier.Silver) return BOOST_SILVER;
        if (tier == Tier.Bronze) return BOOST_BRONZE;
        return BPS; // 1.0x for no tier
    }

    function _getLockPeriod(Tier tier) internal pure returns (uint256) {
        if (tier == Tier.Quantum) return LOCK_QUANTUM;
        if (tier == Tier.Diamond) return LOCK_DIAMOND;
        if (tier == Tier.Gold) return LOCK_GOLD;
        if (tier == Tier.Silver) return LOCK_SILVER;
        return 0; // Bronze has no lock
    }

    function _calculateTier(uint256 amount) internal pure returns (Tier) {
        if (amount >= TIER_QUANTUM) return Tier.Quantum;
        if (amount >= TIER_DIAMOND) return Tier.Diamond;
        if (amount >= TIER_GOLD) return Tier.Gold;
        if (amount >= TIER_SILVER) return Tier.Silver;
        if (amount >= TIER_BRONZE) return Tier.Bronze;
        return Tier.None;
    }

    // ============ ERC20 Overrides ============

    /**
     * @dev Apply demurrage before transfers
     */
    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        // Apply demurrage on sender (if not minting)
        if (from != address(0)) {
            _applyDemurrage(from);
        }

        super._update(from, to, amount);

        // Initialize demurrage tracking for receiver
        if (to != address(0) && from != address(0)) {
            DemurrageInfo storage dem = _demurrage[to];
            if (dem.lastUpdate == 0) {
                dem.lastUpdate = block.timestamp;
            }
        }
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
