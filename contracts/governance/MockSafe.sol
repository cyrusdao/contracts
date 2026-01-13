// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/**
 * @title MockSafe
 * @notice Simplified Safe multisig for local testing
 *
 * This is NOT a production Safe - use Gnosis Safe for mainnet.
 * This contract simulates basic multisig functionality for testing
 * the governance bootstrap flow.
 *
 * Features:
 * - M-of-N signature threshold
 * - Transaction execution with signatures
 * - Owner management (via multisig)
 */
contract MockSafe {
    // ═══════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice List of owners
    address[] public owners;

    /// @notice Mapping for O(1) owner lookup
    mapping(address => bool) public isOwner;

    /// @notice Required signatures for execution
    uint256 public threshold;

    /// @notice Nonce for transaction uniqueness
    uint256 public nonce;

    /// @notice Pending transactions
    mapping(bytes32 => Transaction) public transactions;

    /// @notice Signatures for pending transactions
    mapping(bytes32 => mapping(address => bool)) public signatures;

    /// @notice Signature count for pending transactions
    mapping(bytes32 => uint256) public signatureCount;

    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 createdAt;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event TransactionProposed(bytes32 indexed txHash, address indexed proposer, address to, uint256 value);
    event TransactionSigned(bytes32 indexed txHash, address indexed signer);
    event TransactionExecuted(bytes32 indexed txHash, address indexed executor);
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event ThresholdChanged(uint256 newThreshold);

    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error NotOwner();
    error InvalidThreshold();
    error AlreadyOwner();
    error NotEnoughOwners();
    error TransactionNotFound();
    error AlreadySigned();
    error NotEnoughSignatures();
    error TransactionAlreadyExecuted();
    error ExecutionFailed();

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize Safe with owners and threshold
     * @param _owners Initial owner addresses
     * @param _threshold Required signatures (must be <= owners.length)
     */
    constructor(address[] memory _owners, uint256 _threshold) {
        if (_threshold == 0 || _threshold > _owners.length) revert InvalidThreshold();

        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            if (isOwner[owner]) revert AlreadyOwner();
            isOwner[owner] = true;
            owners.push(owner);
            emit OwnerAdded(owner);
        }

        threshold = _threshold;
        emit ThresholdChanged(_threshold);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert NotOwner();
        _;
    }

    modifier onlySelf() {
        require(msg.sender == address(this), "Only self");
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // TRANSACTION FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Propose a new transaction
     * @param to Target address
     * @param value ETH value to send
     * @param data Calldata
     * @return txHash Transaction hash
     */
    function proposeTransaction(
        address to,
        uint256 value,
        bytes calldata data
    ) external onlyOwner returns (bytes32 txHash) {
        txHash = keccak256(abi.encodePacked(to, value, data, nonce));
        nonce++;

        transactions[txHash] = Transaction({
            to: to,
            value: value,
            data: data,
            executed: false,
            createdAt: block.timestamp
        });

        // Proposer automatically signs
        signatures[txHash][msg.sender] = true;
        signatureCount[txHash] = 1;

        emit TransactionProposed(txHash, msg.sender, to, value);
        emit TransactionSigned(txHash, msg.sender);
    }

    /**
     * @notice Sign a pending transaction
     * @param txHash Transaction hash to sign
     */
    function signTransaction(bytes32 txHash) external onlyOwner {
        Transaction storage txn = transactions[txHash];
        if (txn.createdAt == 0) revert TransactionNotFound();
        if (txn.executed) revert TransactionAlreadyExecuted();
        if (signatures[txHash][msg.sender]) revert AlreadySigned();

        signatures[txHash][msg.sender] = true;
        signatureCount[txHash]++;

        emit TransactionSigned(txHash, msg.sender);
    }

    /**
     * @notice Execute a transaction with enough signatures
     * @param txHash Transaction hash to execute
     */
    function executeTransaction(bytes32 txHash) external onlyOwner {
        Transaction storage txn = transactions[txHash];
        if (txn.createdAt == 0) revert TransactionNotFound();
        if (txn.executed) revert TransactionAlreadyExecuted();
        if (signatureCount[txHash] < threshold) revert NotEnoughSignatures();

        txn.executed = true;

        (bool success,) = txn.to.call{value: txn.value}(txn.data);
        if (!success) revert ExecutionFailed();

        emit TransactionExecuted(txHash, msg.sender);
    }

    /**
     * @notice Propose, sign by all, and execute in one call (for testing)
     * @dev Only works if caller has threshold signatures worth of trust
     */
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data
    ) external onlyOwner returns (bool success) {
        // For local testing, allow single-call execution
        // In production Safe, this would require actual signatures
        (success,) = to.call{value: value}(data);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // OWNER MANAGEMENT (via multisig)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Add a new owner (must be called via multisig)
     */
    function addOwner(address owner) external onlySelf {
        if (isOwner[owner]) revert AlreadyOwner();
        isOwner[owner] = true;
        owners.push(owner);
        emit OwnerAdded(owner);
    }

    /**
     * @notice Remove an owner (must be called via multisig)
     */
    function removeOwner(address owner) external onlySelf {
        if (!isOwner[owner]) revert NotOwner();
        if (owners.length <= threshold) revert NotEnoughOwners();

        isOwner[owner] = false;

        // Remove from array
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == owner) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }

        emit OwnerRemoved(owner);
    }

    /**
     * @notice Change threshold (must be called via multisig)
     */
    function changeThreshold(uint256 newThreshold) external onlySelf {
        if (newThreshold == 0 || newThreshold > owners.length) revert InvalidThreshold();
        threshold = newThreshold;
        emit ThresholdChanged(newThreshold);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function getOwnerCount() external view returns (uint256) {
        return owners.length;
    }

    function getTransactionStatus(bytes32 txHash) external view returns (
        bool exists,
        bool executed,
        uint256 sigs,
        uint256 required
    ) {
        Transaction storage txn = transactions[txHash];
        return (
            txn.createdAt > 0,
            txn.executed,
            signatureCount[txHash],
            threshold
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RECEIVE
    // ═══════════════════════════════════════════════════════════════════════

    receive() external payable {}
}
