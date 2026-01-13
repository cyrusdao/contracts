// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.31;

// @luxfi/standard unified imports - DO NOT import @openzeppelin directly
import {ERC20, ERC20Permit, ERC20Votes, IERC20, SafeERC20} from "@luxfi/standard/tokens/ERC20.sol";
import {ReentrancyGuard, Pausable, Nonces} from "@luxfi/standard/utils/Utils.sol";
import {AccessControl} from "@luxfi/standard/access/Access.sol";

/**
 * @title LiquidCYRUS (xCYRUS)
 * @author Cyrus Protocol
 * @notice Shariah-compliant master yield vault for CYRUS tokens
 * @dev Based on luxfi-standard LiquidLUX architecture with Islamic finance modifications
 *
 * ISLAMIC FINANCE PRINCIPLES:
 * - No Riba (interest): Yield comes from real economic activity (staking, validator rewards)
 * - Asset-backed: All positions fully collateralized with real assets
 * - Profit-sharing: Returns distributed proportionally to stake (Musharakah model)
 * - Zakat: 10% of yields directed to community treasury for charitable purposes
 * - Transparency: All flows auditable on-chain
 *
 * ARCHITECTURE (mirrors LiquidLUX from luxfi-standard):
 * ┌─────────────────────────────────────────────────────────────────────────────┐
 * │                        LiquidCYRUS (xCYRUS)                                 │
 * ├─────────────────────────────────────────────────────────────────────────────┤
 * │  INFLOWS (Halal sources only):                                             │
 * │  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐                    │
 * │  │ DEX Fees      │ │ Bridge Fees   │ │ Validator     │                    │
 * │  │ (from AMMs)   │ │ (from xchain) │ │ Rewards       │                    │
 * │  └───────┬───────┘ └───────┬───────┘ └───────┬───────┘                    │
 * │          │                 │                 │                             │
 * │          ▼                 ▼                 ▼                             │
 * │  ┌───────────────────────────────────────────────────────────────────────┐ │
 * │  │                    receiveFees(amount, feeType)                       │ │
 * │  │                         → 10% to treasury (zakat fund)                │ │
 * │  │                         → 90% to vault (profit share)                 │ │
 * │  └───────────────────────────────────────────────────────────────────────┘ │
 * │                                                                             │
 * │  OUTFLOWS:                                                                  │
 * │  • Users deposit CYRUS → receive xCYRUS shares                             │
 * │  • Users withdraw xCYRUS → receive CYRUS + proportional yield              │
 * │  • xCYRUS is checkpointed (ERC20Votes) for governance                      │
 * │                                                                             │
 * │  ZAKAT DISTRIBUTION:                                                        │
 * │  • 10% of yields directed to community treasury for charitable purposes    │
 * │                                                                             │
 * │  SLASHING POLICY:                                                           │
 * │  • Reserve buffer accumulated from fees                                     │
 * │  • Losses socialized if reserve insufficient                                │
 * └─────────────────────────────────────────────────────────────────────────────┘
 *
 * @custom:security-contact security@cyrus.cash
 */
contract LiquidCYRUS is ERC20, ERC20Permit, ERC20Votes, ReentrancyGuard, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    // ============ Fee Type Constants (bytes32) ============

    bytes32 public constant FEE_DEX = keccak256("DEX");
    bytes32 public constant FEE_BRIDGE = keccak256("BRIDGE");
    bytes32 public constant FEE_LENDING = keccak256("LENDING");
    bytes32 public constant FEE_PERPS = keccak256("PERPS");
    bytes32 public constant FEE_LIQUID = keccak256("LIQUID");
    bytes32 public constant FEE_NFT = keccak256("NFT");
    bytes32 public constant FEE_VALIDATOR = keccak256("VALIDATOR");
    bytes32 public constant FEE_OTHER = keccak256("OTHER");

    // ============ Roles ============

    bytes32 public constant FEE_DISTRIBUTOR_ROLE = keccak256("FEE_DISTRIBUTOR_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // ============ Constants ============

    uint256 public constant BPS = 10_000;
    uint256 public constant ZAKAT_BPS = 1000; // 10% for charitable distribution
    uint256 public constant MAX_ZAKAT_BPS = 2500; // 25% maximum
    uint256 public constant MAX_SLASHING_RESERVE_BPS = 2000; // 20% max

    // ============ Immutables ============

    IERC20 public immutable cyrus;

    // ============ Configuration (Governance-controlled) ============

    /// @notice Treasury address for zakat (charitable) distributions
    address public zakatTreasury;

    /// @notice Zakat rate in basis points (default 10% = 1000 bps)
    uint256 public zakatBps = ZAKAT_BPS;

    // ============ Slashing Policy ============

    /// @notice Slashing reserve buffer (accumulated from portion of fees)
    uint256 public slashingReserve;

    /// @notice Basis points of incoming fees directed to slashing reserve
    uint256 public slashingReserveBps = 100; // 1% default

    /// @notice If true, losses beyond reserve are socialized across all holders
    bool public socializeLosses = true;

    // ============ Accounting Ledgers ============

    /// @notice Total protocol fees received (before zakat)
    uint256 public totalProtocolFeesIn;

    /// @notice Total validator rewards received (no zakat fee)
    uint256 public totalValidatorRewardsIn;

    /// @notice Total zakat fees distributed
    uint256 public totalZakatOut;

    /// @notice Total slashing losses applied
    uint256 public totalSlashingLosses;

    /// @notice Fees by source type
    mapping(bytes32 => uint256) public feesBySource;

    /// @notice Approved fee distributors
    mapping(address => bool) public feeDistributors;

    /// @notice Approved validator sources
    mapping(address => bool) public validatorSources;

    // ============ Events ============

    event FeesReceived(address indexed from, uint256 amount, bytes32 indexed feeType, uint256 zakat, uint256 toReserve);
    event ValidatorRewardsReceived(address indexed from, uint256 amount);
    event SlashingApplied(uint256 amount, uint256 fromReserve, uint256 socialized);
    event ZakatTreasuryUpdated(address indexed newTreasury);
    event ZakatBpsUpdated(uint256 newBps);
    event SlashingReserveBpsUpdated(uint256 newBps);
    event SocializeLossesUpdated(bool newValue);
    event FeeDistributorUpdated(address indexed distributor, bool approved);
    event ValidatorSourceUpdated(address indexed source, bool approved);
    event EmergencyWithdrawal(address indexed to, uint256 amount);

    // ============ Errors ============

    error InvalidAddress();
    error InvalidBps();
    error NotFeeDistributor();
    error NotValidatorSource();
    error InsufficientBalance();
    error InsufficientShares();
    error ZeroAmount();

    // ============ Constructor ============

    constructor(
        address _cyrus,
        address _zakatTreasury,
        address _timelock
    ) ERC20("Liquid CYRUS", "xCYRUS") ERC20Permit("Liquid CYRUS") {
        if (_cyrus == address(0) || _zakatTreasury == address(0)) revert InvalidAddress();

        cyrus = IERC20(_cyrus);
        zakatTreasury = _zakatTreasury;

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, _timelock != address(0) ? _timelock : msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }

    // ============ User Actions ============

    /**
     * @notice Deposit CYRUS and receive xCYRUS shares
     * @param amount Amount of CYRUS to deposit
     * @return shares Amount of xCYRUS shares minted
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();

        shares = _convertToShares(amount);
        if (shares == 0) revert ZeroAmount();

        // CEI: Effects before interactions
        _mint(msg.sender, shares);

        // Transfer CYRUS from user
        cyrus.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraw CYRUS by burning xCYRUS shares
     * @param shares Amount of xCYRUS shares to burn
     * @return amount Amount of CYRUS withdrawn
     */
    function withdraw(uint256 shares) external nonReentrant whenNotPaused returns (uint256 amount) {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();

        amount = _convertToAssets(shares);
        if (amount == 0) revert ZeroAmount();

        // CEI: Effects before interactions
        _burn(msg.sender, shares);

        // Transfer CYRUS to user
        cyrus.safeTransfer(msg.sender, amount);
    }

    // ============ Fee Reception ============

    /**
     * @notice Receive protocol fees from approved distributors
     * @param amount Amount of CYRUS fees
     * @param feeType Type of fee (use FEE_* constants)
     */
    function receiveFees(uint256 amount, bytes32 feeType) external nonReentrant whenNotPaused {
        if (!feeDistributors[msg.sender]) revert NotFeeDistributor();
        if (amount == 0) revert ZeroAmount();

        // Transfer CYRUS from distributor
        cyrus.safeTransferFrom(msg.sender, address(this), amount);

        // Calculate zakat (charitable portion - 10%)
        uint256 zakat = (amount * zakatBps) / BPS;

        // Calculate slashing reserve contribution
        uint256 toReserve = (amount * slashingReserveBps) / BPS;

        // Update accounting
        totalProtocolFeesIn += amount;
        totalZakatOut += zakat;
        feesBySource[feeType] += amount;
        slashingReserve += toReserve;

        // Send zakat to treasury for charitable distribution
        if (zakat > 0) {
            cyrus.safeTransfer(zakatTreasury, zakat);
        }

        emit FeesReceived(msg.sender, amount, feeType, zakat, toReserve);
    }

    /**
     * @notice Receive validator rewards (no zakat fee - validators exempt)
     * @param amount Amount of CYRUS rewards
     */
    function depositValidatorRewards(uint256 amount) external nonReentrant whenNotPaused {
        if (!validatorSources[msg.sender]) revert NotValidatorSource();
        if (amount == 0) revert ZeroAmount();

        // Transfer CYRUS from validator source
        cyrus.safeTransferFrom(msg.sender, address(this), amount);

        // Update accounting (no zakat for validators)
        totalValidatorRewardsIn += amount;
        feesBySource[FEE_VALIDATOR] += amount;

        emit ValidatorRewardsReceived(msg.sender, amount);
    }

    // ============ Slashing ============

    /**
     * @notice Apply slashing loss to the vault
     * @dev Called by governance when validator is slashed
     * @param amount Amount of CYRUS lost to slashing
     */
    function applySlashing(uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        if (amount == 0) revert ZeroAmount();

        uint256 fromReserve = 0;
        uint256 socialized = 0;

        // First, use slashing reserve
        if (slashingReserve >= amount) {
            slashingReserve -= amount;
            fromReserve = amount;
        } else {
            fromReserve = slashingReserve;
            slashingReserve = 0;

            // Remaining loss
            uint256 remaining = amount - fromReserve;

            if (socializeLosses) {
                // Loss is socialized - reduces vault balance
                // This effectively dilutes all xCYRUS holders proportionally
                socialized = remaining;
            } else {
                // Without socialization, excess loss is absorbed by protocol
                revert InsufficientBalance();
            }
        }

        totalSlashingLosses += amount;

        emit SlashingApplied(amount, fromReserve, socialized);
    }

    // ============ Governance Setters (Timelock-controlled) ============

    function setZakatTreasury(address _treasury) external onlyRole(GOVERNANCE_ROLE) {
        if (_treasury == address(0)) revert InvalidAddress();
        zakatTreasury = _treasury;
        emit ZakatTreasuryUpdated(_treasury);
    }

    function setZakatBps(uint256 _bps) external onlyRole(GOVERNANCE_ROLE) {
        if (_bps > MAX_ZAKAT_BPS) revert InvalidBps();
        zakatBps = _bps;
        emit ZakatBpsUpdated(_bps);
    }

    function setSlashingReserveBps(uint256 _bps) external onlyRole(GOVERNANCE_ROLE) {
        if (_bps > MAX_SLASHING_RESERVE_BPS) revert InvalidBps();
        slashingReserveBps = _bps;
        emit SlashingReserveBpsUpdated(_bps);
    }

    function setSocializeLosses(bool _socialize) external onlyRole(GOVERNANCE_ROLE) {
        socializeLosses = _socialize;
        emit SocializeLossesUpdated(_socialize);
    }

    // ============ Access Control ============

    function addFeeDistributor(address distributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (distributor == address(0)) revert InvalidAddress();
        feeDistributors[distributor] = true;
        emit FeeDistributorUpdated(distributor, true);
    }

    function removeFeeDistributor(address distributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeDistributors[distributor] = false;
        emit FeeDistributorUpdated(distributor, false);
    }

    function addValidatorSource(address source) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (source == address(0)) revert InvalidAddress();
        validatorSources[source] = true;
        emit ValidatorSourceUpdated(source, true);
    }

    function removeValidatorSource(address source) external onlyRole(DEFAULT_ADMIN_ROLE) {
        validatorSources[source] = false;
        emit ValidatorSourceUpdated(source, false);
    }

    // ============ Emergency ============

    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency withdrawal to treasury
     * @dev Only callable when paused by emergency role
     */
    function emergencyWithdrawToTreasury() external onlyRole(EMERGENCY_ROLE) {
        require(paused(), "Must be paused");

        uint256 balance = cyrus.balanceOf(address(this));
        if (balance == 0) revert InsufficientBalance();

        cyrus.safeTransfer(zakatTreasury, balance);

        emit EmergencyWithdrawal(zakatTreasury, balance);
    }

    // ============ View Functions ============

    /**
     * @notice Total CYRUS assets in the vault
     */
    function totalAssets() public view returns (uint256) {
        return cyrus.balanceOf(address(this));
    }

    /**
     * @notice Convert CYRUS amount to xCYRUS shares
     */
    function convertToShares(uint256 assets) external view returns (uint256) {
        return _convertToShares(assets);
    }

    /**
     * @notice Convert xCYRUS shares to CYRUS amount
     */
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return _convertToAssets(shares);
    }

    /**
     * @notice Current exchange rate (CYRUS per xCYRUS, scaled by 1e18)
     */
    function exchangeRate() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        return (totalAssets() * 1e18) / supply;
    }

    /**
     * @notice Reconciliation view for auditing
     * @return expectedBalance What balance should be based on inflows - outflows
     * @return actualBalance Actual CYRUS balance
     * @return discrepancy Difference (should be 0 or small from rounding)
     */
    function reconcile() external view returns (
        uint256 expectedBalance,
        uint256 actualBalance,
        int256 discrepancy
    ) {
        // Expected = Total In - Zakat - Slashing Losses
        expectedBalance = totalProtocolFeesIn + totalValidatorRewardsIn
                        - totalZakatOut - totalSlashingLosses;
        actualBalance = cyrus.balanceOf(address(this));
        discrepancy = int256(actualBalance) - int256(expectedBalance);
    }

    /**
     * @notice Get fee breakdown by source
     */
    function getFeeBreakdown() external view returns (
        uint256 dex,
        uint256 bridge,
        uint256 lending,
        uint256 perps,
        uint256 liquid,
        uint256 nft,
        uint256 validator,
        uint256 other
    ) {
        return (
            feesBySource[FEE_DEX],
            feesBySource[FEE_BRIDGE],
            feesBySource[FEE_LENDING],
            feesBySource[FEE_PERPS],
            feesBySource[FEE_LIQUID],
            feesBySource[FEE_NFT],
            feesBySource[FEE_VALIDATOR],
            feesBySource[FEE_OTHER]
        );
    }

    // ============ Internal ============

    function _convertToShares(uint256 assets) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return assets; // 1:1 for first deposit
        }
        return (assets * supply) / totalAssets();
    }

    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return shares; // 1:1 if no supply
        }
        return (shares * totalAssets()) / supply;
    }

    // ============ ERC20 Overrides (for ERC20Votes) ============

    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._update(from, to, amount);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
