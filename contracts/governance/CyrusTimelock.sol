// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

// @luxfi/standard unified imports - DO NOT import @openzeppelin directly
import {TimelockController} from "@luxfi/standard/governance/Governance.sol";

/**
 * @title CyrusTimelock
 * @notice Timelock controller for Cyrus Protocol governance
 *
 * All protocol parameter changes must go through this timelock.
 * Initially controlled by Safe multisig, then hands off to vePARS governance.
 *
 * Timelock delays:
 * - CRITICAL_DELAY: 7 days (ownership, minting, large parameter changes)
 * - STANDARD_DELAY: 2 days (gauge weights, emission rates)
 * - EMERGENCY_DELAY: 6 hours (pause, emergency actions with multisig)
 */
contract CyrusTimelock is TimelockController {
    // ═══════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Minimum delay for critical operations (7 days)
    uint256 public constant CRITICAL_DELAY = 7 days;

    /// @notice Standard delay for governance operations (2 days)
    uint256 public constant STANDARD_DELAY = 2 days;

    /// @notice Emergency delay for urgent operations (6 hours)
    uint256 public constant EMERGENCY_DELAY = 6 hours;

    // ═══════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Mapping of operation type to required delay
    mapping(bytes4 => uint256) public functionDelays;

    /// @notice Safe multisig address (bootstrap admin)
    address public immutable safe;

    /// @notice Whether governance handoff has occurred
    bool public governanceActive;

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event GovernanceHandoff(address indexed governor);
    event FunctionDelaySet(bytes4 indexed selector, uint256 delay);

    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error GovernanceAlreadyActive();
    error OnlySafe();
    error DelayTooShort(uint256 required, uint256 provided);

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize timelock with Safe as initial admin
     * @param minDelay Minimum delay for operations (should be STANDARD_DELAY)
     * @param _safe Safe multisig address
     * @param proposers Initial proposers (Safe)
     * @param executors Initial executors (Safe + zero address for anyone)
     */
    constructor(
        uint256 minDelay,
        address _safe,
        address[] memory proposers,
        address[] memory executors
    ) TimelockController(minDelay, proposers, executors, _safe) {
        safe = _safe;

        // Set default function delays for critical operations
        // These require CRITICAL_DELAY (7 days)
        _setFunctionDelay(bytes4(keccak256("transferOwnership(address)")), CRITICAL_DELAY);
        _setFunctionDelay(bytes4(keccak256("setMinter(address)")), CRITICAL_DELAY);
        _setFunctionDelay(bytes4(keccak256("setTreasury(address)")), CRITICAL_DELAY);
        _setFunctionDelay(bytes4(keccak256("setLPWallet(address)")), CRITICAL_DELAY);

        // Emergency operations use EMERGENCY_DELAY
        _setFunctionDelay(bytes4(keccak256("pause()")), EMERGENCY_DELAY);
        _setFunctionDelay(bytes4(keccak256("unpause()")), EMERGENCY_DELAY);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // GOVERNANCE HANDOFF
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Hand off governance from Safe to vePARS-based governance
     * @param governor Address of the governor contract (CyrusDAO with vePARS voting)
     *
     * After handoff:
     * - Governor becomes sole proposer
     * - Anyone can execute (zero address executor)
     * - Safe loses admin rights
     */
    function handoffToGovernance(address governor) external {
        if (msg.sender != safe) revert OnlySafe();
        if (governanceActive) revert GovernanceAlreadyActive();

        // Grant governor the proposer role
        grantRole(PROPOSER_ROLE, governor);

        // Revoke Safe's proposer role (keeps executor for emergencies)
        revokeRole(PROPOSER_ROLE, safe);

        // Renounce admin role from Safe
        // Note: Timelock itself retains admin for future upgrades via governance
        revokeRole(DEFAULT_ADMIN_ROLE, safe);

        governanceActive = true;
        emit GovernanceHandoff(governor);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // DELAY MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Set custom delay for a function selector
     * @param selector Function selector (first 4 bytes of keccak256)
     * @param delay Required delay in seconds
     */
    function setFunctionDelay(bytes4 selector, uint256 delay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (delay < EMERGENCY_DELAY) revert DelayTooShort(EMERGENCY_DELAY, delay);
        _setFunctionDelay(selector, delay);
    }

    function _setFunctionDelay(bytes4 selector, uint256 delay) internal {
        functionDelays[selector] = delay;
        emit FunctionDelaySet(selector, delay);
    }

    /**
     * @notice Get required delay for a function call
     * @param data Calldata containing function selector
     * @return delay Required delay (falls back to minDelay if not set)
     */
    function getRequiredDelay(bytes calldata data) external view returns (uint256 delay) {
        if (data.length < 4) return getMinDelay();

        bytes4 selector = bytes4(data[:4]);
        delay = functionDelays[selector];

        if (delay == 0) {
            delay = getMinDelay();
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if an address is a proposer
     */
    function isProposer(address account) external view returns (bool) {
        return hasRole(PROPOSER_ROLE, account);
    }

    /**
     * @notice Check if an address is an executor
     */
    function isExecutor(address account) external view returns (bool) {
        return hasRole(EXECUTOR_ROLE, account);
    }

    /**
     * @notice Check if an address is an admin
     */
    function isAdmin(address account) external view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, account);
    }
}
