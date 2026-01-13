// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

// @luxfi/standard unified imports - DO NOT import @openzeppelin directly
import {ERC20, IERC20, SafeERC20} from "@luxfi/standard/tokens/ERC20.sol";
import {ReentrancyGuard} from "@luxfi/standard/utils/Utils.sol";
import {Ownable2Step, Ownable} from "@luxfi/standard/access/Access.sol";

/// @title sPARS - Staked PARS with Index-Based Rebasing
/// @notice Stake PARS to receive sPARS which appreciates via index rebasing (~11% APY target)
/// @dev Uses gons/index model from OHM - balances are stored as gons, divided by index for display
/// @custom:security-contact security@cyrus.cash
contract sPARS is ERC20, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Initial index value (1e18 = 1.0)
    uint256 public constant INITIAL_INDEX = 1e18;

    /// @notice Maximum gons value to prevent overflow
    uint256 private constant MAX_UINT256 = type(uint256).max;
    uint256 private constant TOTAL_GONS = MAX_UINT256 - (MAX_UINT256 % INITIAL_INDEX);

    /// @notice Basis points denominator
    uint256 public constant BPS = 10000;

    // ═══════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice PARS token address
    IERC20 public immutable pars;

    /// @notice Current rebase index (starts at 1e18)
    uint256 public index;

    /// @notice Gons per fragment (for index calculation)
    uint256 private _gonsPerFragment;

    /// @notice Gon balances (internal accounting)
    mapping(address => uint256) private _gonBalances;

    /// @notice Total gons in circulation
    uint256 private _totalGons;

    /// @notice Staking contract (can trigger rebases and stake on behalf)
    address public stakingContract;

    /// @notice Rebase epoch tracking
    uint256 public lastRebaseEpoch;
    uint256 public lastRebaseTime;

    /// @notice Rebase parameters (governance-configurable)
    uint256 public rebaseRateBps; // Rebase rate per epoch in bps (default: ~0.4% per 8hr = ~11% APY)
    uint256 public epochDuration;  // Duration between rebases (default: 8 hours)

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event Staked(address indexed user, uint256 pars, uint256 spars);
    event Unstaked(address indexed user, uint256 spars, uint256 pars);
    event Rebased(uint256 indexed epoch, uint256 newIndex, uint256 profit);
    event StakingContractSet(address indexed stakingContract);
    event RebaseParametersSet(uint256 rateBps, uint256 duration);

    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error ZeroAmount();
    error NotStakingContract();
    error RebaseTooSoon();
    error InvalidParameters();
    error InsufficientBalance();

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Initialize sPARS
    /// @param _pars PARS token address
    /// @param initialOwner Governance address
    constructor(
        address _pars,
        address initialOwner
    ) ERC20("Staked Pars", "sPARS") Ownable(initialOwner) {
        if (_pars == address(0)) revert ZeroAddress();

        pars = IERC20(_pars);
        index = INITIAL_INDEX;
        _gonsPerFragment = TOTAL_GONS / INITIAL_INDEX;

        // Default: ~0.4% per 8 hours ≈ 11% APY
        rebaseRateBps = 40; // 0.4%
        epochDuration = 8 hours;
        lastRebaseTime = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STAKING
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Stake PARS to receive sPARS
    /// @param amount Amount of PARS to stake
    /// @return sparsAmount Amount of sPARS received
    function stake(uint256 amount) external nonReentrant returns (uint256 sparsAmount) {
        return _stake(msg.sender, msg.sender, amount);
    }

    /// @notice Stake PARS on behalf of another address
    /// @param recipient Address to receive sPARS
    /// @param amount Amount of PARS to stake
    /// @return sparsAmount Amount of sPARS received
    function stakeFor(address recipient, uint256 amount) external nonReentrant returns (uint256 sparsAmount) {
        return _stake(msg.sender, recipient, amount);
    }

    /// @notice Internal stake implementation
    /// @param from Address to pull PARS from
    /// @param to Address to send sPARS to
    /// @param amount Amount of PARS to stake
    /// @return sparsAmount Amount of sPARS minted
    function _stake(address from, address to, uint256 amount) internal returns (uint256 sparsAmount) {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        // Transfer PARS from sender
        pars.safeTransferFrom(from, address(this), amount);

        // Calculate sPARS amount (1:1 at index 1.0, less as index grows)
        sparsAmount = amount;

        // Mint sPARS (gons)
        uint256 gonValue = sparsAmount * _gonsPerFragment;
        _gonBalances[to] += gonValue;
        _totalGons += gonValue;

        emit Staked(to, amount, sparsAmount);
        emit Transfer(address(0), to, sparsAmount);
    }

    /// @notice Unstake sPARS to receive PARS
    /// @param sparsAmount Amount of sPARS to unstake
    /// @return parsAmount Amount of PARS received
    function unstake(uint256 sparsAmount) external nonReentrant returns (uint256 parsAmount) {
        if (sparsAmount == 0) revert ZeroAmount();

        // Calculate gons to burn
        uint256 gonValue = sparsAmount * _gonsPerFragment;
        if (_gonBalances[msg.sender] < gonValue) revert InsufficientBalance();

        // Burn sPARS (gons)
        _gonBalances[msg.sender] -= gonValue;
        _totalGons -= gonValue;

        // Calculate PARS to return (accounts for rebases)
        parsAmount = sparsAmount * index / INITIAL_INDEX;

        // Transfer PARS
        pars.safeTransfer(msg.sender, parsAmount);

        emit Unstaked(msg.sender, sparsAmount, parsAmount);
        emit Transfer(msg.sender, address(0), sparsAmount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // REBASING
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Trigger a rebase if epoch has elapsed
    /// @dev Can be called by anyone, but typically by staking contract
    /// @return newIndex The new index after rebase
    function rebase() external returns (uint256 newIndex) {
        if (block.timestamp < lastRebaseTime + epochDuration) revert RebaseTooSoon();

        // Calculate epochs elapsed
        uint256 epochsElapsed = (block.timestamp - lastRebaseTime) / epochDuration;
        if (epochsElapsed == 0) revert RebaseTooSoon();

        // Compound rebase rate
        uint256 profit = 0;
        for (uint256 i = 0; i < epochsElapsed; i++) {
            uint256 epochProfit = index * rebaseRateBps / BPS;
            index += epochProfit;
            profit += epochProfit;
        }

        // Update gons per fragment (inverse relationship)
        _gonsPerFragment = TOTAL_GONS / index;

        lastRebaseEpoch += epochsElapsed;
        lastRebaseTime += epochsElapsed * epochDuration;

        emit Rebased(lastRebaseEpoch, index, profit);
        return index;
    }

    /// @notice Distribute profit to stakers (increases index)
    /// @dev Called by staking contract when distributing rewards
    /// @param parsProfit Amount of PARS profit to distribute
    function distributeProfit(uint256 parsProfit) external {
        if (msg.sender != stakingContract && msg.sender != owner()) revert NotStakingContract();
        if (parsProfit == 0) return;

        // Transfer PARS profit to this contract
        pars.safeTransferFrom(msg.sender, address(this), parsProfit);

        // Increase index proportionally
        uint256 totalPars = pars.balanceOf(address(this));
        uint256 previousTotal = totalPars - parsProfit;
        if (previousTotal > 0) {
            index = index * totalPars / previousTotal;
            _gonsPerFragment = TOTAL_GONS / index;
        }

        emit Rebased(lastRebaseEpoch, index, parsProfit);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ERC20 OVERRIDES (Gon-based accounting)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Get total supply (gons / gonsPerFragment)
    function totalSupply() public view override returns (uint256) {
        return _totalGons / _gonsPerFragment;
    }

    /// @notice Get balance (gons / gonsPerFragment)
    function balanceOf(address account) public view override returns (uint256) {
        return _gonBalances[account] / _gonsPerFragment;
    }

    /// @notice Transfer sPARS
    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 gonValue = amount * _gonsPerFragment;
        if (_gonBalances[msg.sender] < gonValue) revert InsufficientBalance();

        _gonBalances[msg.sender] -= gonValue;
        _gonBalances[to] += gonValue;

        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Transfer sPARS from another address
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);

        uint256 gonValue = amount * _gonsPerFragment;
        if (_gonBalances[from] < gonValue) revert InsufficientBalance();

        _gonBalances[from] -= gonValue;
        _gonBalances[to] += gonValue;

        emit Transfer(from, to, amount);
        return true;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEWS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Get PARS value of sPARS amount
    /// @param sparsAmount Amount of sPARS
    /// @return PARS equivalent value
    function parsValue(uint256 sparsAmount) external view returns (uint256) {
        return sparsAmount * index / INITIAL_INDEX;
    }

    /// @notice Get sPARS amount for PARS value
    /// @param parsAmount Amount of PARS
    /// @return sPARS equivalent amount
    function sparsValue(uint256 parsAmount) external view returns (uint256) {
        return parsAmount * INITIAL_INDEX / index;
    }

    /// @notice Time until next rebase
    /// @return Seconds until next rebase (0 if ready)
    function timeUntilRebase() external view returns (uint256) {
        uint256 nextRebase = lastRebaseTime + epochDuration;
        if (block.timestamp >= nextRebase) return 0;
        return nextRebase - block.timestamp;
    }

    /// @notice Current APY based on rebase rate
    /// @return APY in basis points (e.g., 1100 = 11%)
    function currentAPY() external view returns (uint256) {
        // APY = (1 + rate)^(epochs per year) - 1
        // Simplified: rate * epochs per year (for small rates)
        uint256 epochsPerYear = 365 days / epochDuration;
        return rebaseRateBps * epochsPerYear; // Returns in bps (e.g., 1095 ≈ 11%)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN (Owner = Governance)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Set the staking contract address
    /// @param _stakingContract New staking contract address
    function setStakingContract(address _stakingContract) external onlyOwner {
        stakingContract = _stakingContract;
        emit StakingContractSet(_stakingContract);
    }

    /// @notice Set rebase parameters
    /// @param rateBps Rebase rate per epoch in basis points
    /// @param duration Duration between rebases in seconds
    function setRebaseParameters(uint256 rateBps, uint256 duration) external onlyOwner {
        if (rateBps > 1000) revert InvalidParameters(); // Max 10% per epoch
        if (duration < 1 hours || duration > 7 days) revert InvalidParameters();

        rebaseRateBps = rateBps;
        epochDuration = duration;
        emit RebaseParametersSet(rateBps, duration);
    }
}
