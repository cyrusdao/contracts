// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

// @luxfi/standard unified imports - DO NOT import @openzeppelin directly
import {IERC20, IVotes} from "@luxfi/standard/tokens/ERC20.sol";
import {ReentrancyGuard} from "@luxfi/standard/utils/Utils.sol";

/// @title CyrusDAO
/// @notice Governance contract for the CYRUS Persian diaspora community token
/// @dev Initial stewardship by Cyrus the Greatest with planned transition to full public governance
/// @custom:security-contact security@cyrus.cash
contract CyrusDAO is ReentrancyGuard {
    // ═══════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════

    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    struct Proposal {
        uint256 id;
        address proposer;
        uint256 eta;                // Execution time (for timelock)
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool canceled;
        bool executed;
        mapping(address => Receipt) receipts;
    }

    struct Receipt {
        bool hasVoted;
        uint8 support;  // 0 = Against, 1 = For, 2 = Abstain
        uint256 votes;
    }

    struct ProposalInfo {
        uint256 id;
        address proposer;
        uint256 eta;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool canceled;
        bool executed;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Minimum time between proposal and vote start (1 day)
    uint256 public constant VOTING_DELAY = 1 days;

    /// @notice Duration of voting period (5 days - aligns with Persian week)
    uint256 public constant VOTING_PERIOD = 5 days;

    /// @notice Minimum votes needed to create proposal (1M CYRUS = 0.1% of supply)
    uint256 public constant PROPOSAL_THRESHOLD = 1_000_000e18;

    /// @notice Minimum votes for quorum (10M CYRUS = 1% of supply)
    uint256 public constant QUORUM_VOTES = 10_000_000e18;

    /// @notice Timelock delay for execution (48 hours)
    uint256 public constant TIMELOCK_DELAY = 2 days;

    /// @notice Grace period for execution (14 days)
    uint256 public constant GRACE_PERIOD = 14 days;

    /// @notice Nowruz 2026 transfer unlock timestamp
    uint256 public constant NOWRUZ_2026 = 1742558400;

    // ═══════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice CYRUS governance token (must implement ERC20Votes)
    IVotes public immutable token;

    /// @notice Proposal count
    uint256 public proposalCount;

    /// @notice All proposals
    mapping(uint256 => Proposal) public proposals;

    /// @notice Latest proposal per proposer
    mapping(address => uint256) public latestProposalIds;

    /// @notice Guardian with veto power (initially Cyrus the Greatest multisig)
    address public guardian;

    /// @notice Treasury address for DAO funds
    address public treasury;

    /// @notice Whether full public governance has been activated
    bool public publicGovernance;

    /// @notice Board members with elevated proposal rights during stewardship
    mapping(address => bool) public boardMembers;

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event ProposalCreated(
        uint256 id,
        address proposer,
        address[] targets,
        uint256[] values,
        bytes[] calldatas,
        uint256 startBlock,
        uint256 endBlock,
        string description
    );
    event VoteCast(address indexed voter, uint256 proposalId, uint8 support, uint256 votes, string reason);
    event ProposalCanceled(uint256 id);
    event ProposalQueued(uint256 id, uint256 eta);
    event ProposalExecuted(uint256 id);
    event GuardianUpdated(address oldGuardian, address newGuardian);
    event PublicGovernanceActivated(uint256 timestamp);
    event BoardMemberUpdated(address member, bool status);
    event TreasuryUpdated(address oldTreasury, address newTreasury);

    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error InsufficientVotes();
    error InvalidProposalLength();
    error ActiveProposalExists();
    error InvalidProposalState();
    error OnlyGuardian();
    error OnlyProposer();
    error AlreadyVoted();
    error VotingClosed();
    error TimelockNotReady();
    error ProposalExpired();
    error ExecutionFailed();
    error VotingNotActive();
    error NotBoardMember();
    error AlreadyPublicGovernance();
    error TooEarlyForPublicGovernance();

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Initialize the DAO with founding board
    /// @param _token CYRUS token address
    /// @param _guardian Initial guardian (Cyrus the Greatest multisig)
    /// @param _treasury DAO treasury address
    /// @param _boardMembers Initial board member addresses
    constructor(
        address _token,
        address _guardian,
        address _treasury,
        address[] memory _boardMembers
    ) {
        token = IVotes(_token);
        guardian = _guardian;
        treasury = _treasury;

        // Add founding board members
        for (uint256 i = 0; i < _boardMembers.length; i++) {
            boardMembers[_boardMembers[i]] = true;
            emit BoardMemberUpdated(_boardMembers[i], true);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PROPOSAL LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Create a new proposal
    /// @dev During stewardship phase, only board members can propose
    /// @param targets Target addresses for calls
    /// @param values ETH values for calls
    /// @param calldatas Call data for each target
    /// @param description Human readable description
    /// @return Proposal ID
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external returns (uint256) {
        // Validate arrays
        if (targets.length != values.length || targets.length != calldatas.length) {
            revert InvalidProposalLength();
        }
        if (targets.length == 0) revert InvalidProposalLength();

        // Check proposer eligibility
        if (!publicGovernance) {
            // During stewardship, only board members can propose
            if (!boardMembers[msg.sender]) revert NotBoardMember();
        } else {
            // After public governance, need token threshold
            uint256 votes = _getCurrentVotes(msg.sender);
            if (votes < PROPOSAL_THRESHOLD) revert InsufficientVotes();
        }

        // Check no active proposal
        uint256 latestId = latestProposalIds[msg.sender];
        if (latestId != 0) {
            ProposalState state = _state(latestId);
            if (state == ProposalState.Active || state == ProposalState.Pending) {
                revert ActiveProposalExists();
            }
        }

        // Create proposal
        proposalCount++;
        uint256 proposalId = proposalCount;

        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.targets = targets;
        proposal.values = values;
        proposal.calldatas = calldatas;
        proposal.startBlock = block.number + VOTING_DELAY / 12; // ~12s blocks on Base
        proposal.endBlock = proposal.startBlock + VOTING_PERIOD / 12;

        latestProposalIds[msg.sender] = proposalId;

        emit ProposalCreated(
            proposalId,
            msg.sender,
            targets,
            values,
            calldatas,
            proposal.startBlock,
            proposal.endBlock,
            description
        );

        return proposalId;
    }

    /// @notice Queue a succeeded proposal for execution
    /// @param proposalId Proposal to queue
    function queue(uint256 proposalId) external {
        if (_state(proposalId) != ProposalState.Succeeded) revert InvalidProposalState();

        Proposal storage proposal = proposals[proposalId];
        proposal.eta = block.timestamp + TIMELOCK_DELAY;

        emit ProposalQueued(proposalId, proposal.eta);
    }

    /// @notice Execute a queued proposal
    /// @param proposalId Proposal to execute
    function execute(uint256 proposalId) external payable nonReentrant {
        if (_state(proposalId) != ProposalState.Queued) revert InvalidProposalState();

        Proposal storage proposal = proposals[proposalId];

        if (block.timestamp < proposal.eta) revert TimelockNotReady();
        if (block.timestamp > proposal.eta + GRACE_PERIOD) revert ProposalExpired();

        proposal.executed = true;

        for (uint256 i = 0; i < proposal.targets.length; i++) {
            (bool success, bytes memory returnData) = proposal.targets[i].call{value: proposal.values[i]}(
                proposal.calldatas[i]
            );
            if (!success) {
                // Bubble up revert
                assembly {
                    revert(add(returnData, 32), mload(returnData))
                }
            }
        }

        emit ProposalExecuted(proposalId);
    }

    /// @notice Cancel a proposal
    /// @param proposalId Proposal to cancel
    function cancel(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];

        // Only proposer or guardian can cancel
        if (msg.sender != proposal.proposer && msg.sender != guardian) {
            revert OnlyProposer();
        }

        ProposalState state = _state(proposalId);
        if (state == ProposalState.Executed) revert InvalidProposalState();

        proposal.canceled = true;

        emit ProposalCanceled(proposalId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VOTING
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Cast vote
    /// @param proposalId Proposal to vote on
    /// @param support 0 = Against, 1 = For, 2 = Abstain
    function castVote(uint256 proposalId, uint8 support) external {
        _castVote(msg.sender, proposalId, support, "");
    }

    /// @notice Cast vote with reason
    /// @param proposalId Proposal to vote on
    /// @param support 0 = Against, 1 = For, 2 = Abstain
    /// @param reason Vote reason
    function castVoteWithReason(uint256 proposalId, uint8 support, string calldata reason) external {
        _castVote(msg.sender, proposalId, support, reason);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Get proposal state
    function state(uint256 proposalId) external view returns (ProposalState) {
        return _state(proposalId);
    }

    /// @notice Get proposal info
    function getProposal(uint256 proposalId) external view returns (ProposalInfo memory) {
        Proposal storage p = proposals[proposalId];
        return ProposalInfo({
            id: p.id,
            proposer: p.proposer,
            eta: p.eta,
            startBlock: p.startBlock,
            endBlock: p.endBlock,
            forVotes: p.forVotes,
            againstVotes: p.againstVotes,
            abstainVotes: p.abstainVotes,
            canceled: p.canceled,
            executed: p.executed
        });
    }

    /// @notice Get proposal actions
    function getActions(uint256 proposalId)
        external
        view
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas
        )
    {
        Proposal storage p = proposals[proposalId];
        return (p.targets, p.values, p.calldatas);
    }

    /// @notice Get vote receipt
    function getReceipt(uint256 proposalId, address voter) external view returns (Receipt memory) {
        return proposals[proposalId].receipts[voter];
    }

    /// @notice Check if account has voted
    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        return proposals[proposalId].receipts[voter].hasVoted;
    }

    /// @notice Check if address is a board member
    function isBoardMember(address account) external view returns (bool) {
        return boardMembers[account];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // GUARDIAN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Update guardian
    function setGuardian(address newGuardian) external {
        if (msg.sender != guardian) revert OnlyGuardian();
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @notice Add or remove board member (only during stewardship)
    function setBoardMember(address member, bool status) external {
        if (msg.sender != guardian) revert OnlyGuardian();
        if (publicGovernance) revert AlreadyPublicGovernance();
        boardMembers[member] = status;
        emit BoardMemberUpdated(member, status);
    }

    /// @notice Update treasury address
    function setTreasury(address newTreasury) external {
        if (msg.sender != guardian) revert OnlyGuardian();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Activate full public governance
    /// @dev Can only be called after Nowruz 2026 (transfer unlock)
    /// @dev This is a one-way transition - cannot go back to stewardship
    function activatePublicGovernance() external {
        if (msg.sender != guardian) revert OnlyGuardian();
        if (publicGovernance) revert AlreadyPublicGovernance();
        if (block.timestamp < NOWRUZ_2026) revert TooEarlyForPublicGovernance();

        publicGovernance = true;
        emit PublicGovernanceActivated(block.timestamp);
    }

    /// @notice Abdicate guardian powers (full decentralization)
    /// @dev This permanently removes the guardian veto power
    function abdicateGuardian() external {
        if (msg.sender != guardian) revert OnlyGuardian();
        emit GuardianUpdated(guardian, address(0));
        guardian = address(0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function _state(uint256 proposalId) internal view returns (ProposalState) {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.canceled) return ProposalState.Canceled;
        if (proposal.executed) return ProposalState.Executed;
        if (block.number <= proposal.startBlock) return ProposalState.Pending;
        if (block.number <= proposal.endBlock) return ProposalState.Active;

        // Voting ended
        if (proposal.forVotes <= proposal.againstVotes || proposal.forVotes < QUORUM_VOTES) {
            return ProposalState.Defeated;
        }

        if (proposal.eta == 0) return ProposalState.Succeeded;
        if (block.timestamp >= proposal.eta + GRACE_PERIOD) return ProposalState.Expired;

        return ProposalState.Queued;
    }

    function _castVote(
        address voter,
        uint256 proposalId,
        uint8 support,
        string memory reason
    ) internal {
        if (_state(proposalId) != ProposalState.Active) revert VotingClosed();

        Proposal storage proposal = proposals[proposalId];
        Receipt storage receipt = proposal.receipts[voter];

        if (receipt.hasVoted) revert AlreadyVoted();

        // Use snapshot at proposal creation (prevents flash loan attacks)
        uint256 votes = _getVotes(voter, proposal.startBlock);

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = votes;

        if (support == 0) {
            proposal.againstVotes += votes;
        } else if (support == 1) {
            proposal.forVotes += votes;
        } else if (support == 2) {
            proposal.abstainVotes += votes;
        }

        emit VoteCast(voter, proposalId, support, votes, reason);
    }

    /// @notice Get voting power at a specific block (snapshot-based, flash loan resistant)
    /// @param account Address to get voting power for
    /// @param timepoint Block number to check voting power at
    /// @return Voting power at the specified block
    function _getVotes(address account, uint256 timepoint) internal view returns (uint256) {
        // Use checkpointed balance at timepoint (prevents flash loan attacks)
        return token.getPastVotes(account, timepoint);
    }

    /// @notice Get current voting power (for proposal threshold checks)
    /// @param account Address to get voting power for
    /// @return Current voting power
    function _getCurrentVotes(address account) internal view returns (uint256) {
        return token.getVotes(account);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RECEIVE
    // ═══════════════════════════════════════════════════════════════════════

    receive() external payable {}
}
