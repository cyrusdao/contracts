// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

// @luxfi/standard unified imports - DO NOT import @openzeppelin directly
import {IERC20, IVotes} from "@luxfi/standard/tokens/ERC20.sol";
import {ReentrancyGuard} from "@luxfi/standard/utils/Utils.sol";
import {AccessControl} from "@luxfi/standard/access/Access.sol";

/**
 * @title CyrusSubDAO
 * @notice Sub-DAO for decentralized community governance
 * @dev Each sub-DAO focuses on a specific domain (treasury, grants, dev, etc.)
 *
 * SUB-DAO ARCHITECTURE:
 * ┌─────────────────────────────────────────────────────────────────────────────┐
 * │                        CyrusSubDAO System                                   │
 * ├─────────────────────────────────────────────────────────────────────────────┤
 * │                                                                             │
 * │  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐    │
 * │  │ Treasury    │   │ Grants      │   │ Development │   │ Community   │    │
 * │  │ SubDAO      │   │ SubDAO      │   │ SubDAO      │   │ SubDAO      │    │
 * │  └──────┬──────┘   └──────┬──────┘   └──────┬──────┘   └──────┬──────┘    │
 * │         │                 │                 │                 │            │
 * │         └─────────────────┴─────────────────┴─────────────────┘            │
 * │                                    │                                        │
 * │                            ┌───────▼───────┐                               │
 * │                            │  CyrusDAO     │                               │
 * │                            │  (Main DAO)   │                               │
 * │                            └───────────────┘                               │
 * │                                                                             │
 * │  Each SubDAO has:                                                           │
 * │  - Own voting threshold                                                     │
 * │  - Budget allocation                                                        │
 * │  - GitHub discussion link                                                   │
 * │  - Domain-specific permissions                                              │
 * └─────────────────────────────────────────────────────────────────────────────┘
 *
 * @custom:security-contact security@cyrus.cash
 */
contract CyrusSubDAO is ReentrancyGuard, AccessControl {

    // ═══════════════════════════════════════════════════════════════════════
    // ROLES
    // ═══════════════════════════════════════════════════════════════════════

    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

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
        Executed
    }

    enum SubDAOCategory {
        Treasury,       // Fund management
        Grants,         // Community grants
        Development,    // Protocol development
        Community,      // Community initiatives
        Marketing,      // Marketing & growth
        Research,       // R&D initiatives
        Regional,       // Regional chapters
        Custom          // Custom sub-DAO
    }

    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        string discussionUrl;       // GitHub discussion link
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool canceled;
        bool executed;
    }

    struct SubDAOConfig {
        string name;
        string description;
        SubDAOCategory category;
        string githubRepo;          // e.g., "cyrus-pahlavi/cyrus-token"
        uint256 votingPeriod;       // Voting period in seconds
        uint256 votingDelay;        // Delay before voting starts
        uint256 proposalThreshold;  // Min voting power to propose
        uint256 quorumBps;          // Quorum in basis points (100 = 1%)
        uint256 budgetAllocation;   // Budget in PARS tokens
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_VOTING_PERIOD = 1 days;
    uint256 public constant MAX_VOTING_PERIOD = 14 days;

    // ═══════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Governance token for voting
    IVotes public immutable governanceToken;

    /// @notice Parent DAO address
    address public parentDAO;

    /// @notice Sub-DAO configuration
    SubDAOConfig public config;

    /// @notice All proposals
    mapping(uint256 => Proposal) public proposals;

    /// @notice Vote receipts per proposal
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => mapping(address => uint8)) public voteSupport;

    /// @notice Proposal count
    uint256 public proposalCount;

    /// @notice Total budget spent
    uint256 public budgetSpent;

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string title,
        string discussionUrl
    );
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        uint8 support,
        uint256 weight
    );
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);
    event ConfigUpdated(string name, string description);
    event BudgetIncreased(uint256 amount);

    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error InvalidConfig();
    error InsufficientVotingPower();
    error ProposalNotActive();
    error AlreadyVoted();
    error InvalidVote();
    error ProposalNotSucceeded();
    error ProposalAlreadyExecuted();
    error BudgetExceeded();

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    constructor(
        address _governanceToken,
        address _parentDAO,
        SubDAOConfig memory _config
    ) {
        if (_governanceToken == address(0)) revert ZeroAddress();
        if (_config.votingPeriod < MIN_VOTING_PERIOD || _config.votingPeriod > MAX_VOTING_PERIOD) {
            revert InvalidConfig();
        }

        governanceToken = IVotes(_governanceToken);
        parentDAO = _parentDAO;
        config = _config;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PROPOSER_ROLE, msg.sender);
        _grantRole(EXECUTOR_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PROPOSAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Create a new proposal
     * @param title Proposal title
     * @param description Proposal description
     * @param discussionUrl GitHub discussion URL
     * @param targets Target addresses for execution
     * @param values ETH values for execution
     * @param calldatas Call data for execution
     */
    function propose(
        string calldata title,
        string calldata description,
        string calldata discussionUrl,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    ) external nonReentrant returns (uint256 proposalId) {
        // Check voting power
        uint256 votingPower = governanceToken.getVotes(msg.sender);
        if (votingPower < config.proposalThreshold) {
            revert InsufficientVotingPower();
        }

        proposalId = ++proposalCount;

        Proposal storage p = proposals[proposalId];
        p.id = proposalId;
        p.proposer = msg.sender;
        p.title = title;
        p.description = description;
        p.discussionUrl = discussionUrl;
        p.targets = targets;
        p.values = values;
        p.calldatas = calldatas;
        p.startTime = block.timestamp + config.votingDelay;
        p.endTime = p.startTime + config.votingPeriod;

        emit ProposalCreated(proposalId, msg.sender, title, discussionUrl);
    }

    /**
     * @notice Cast a vote
     * @param proposalId Proposal to vote on
     * @param support 0 = Against, 1 = For, 2 = Abstain
     */
    function castVote(uint256 proposalId, uint8 support) external nonReentrant {
        if (support > 2) revert InvalidVote();

        Proposal storage p = proposals[proposalId];
        if (block.timestamp < p.startTime || block.timestamp > p.endTime) {
            revert ProposalNotActive();
        }
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted();

        uint256 weight = governanceToken.getPastVotes(msg.sender, p.startTime);

        hasVoted[proposalId][msg.sender] = true;
        voteSupport[proposalId][msg.sender] = support;

        if (support == 0) {
            p.againstVotes += weight;
        } else if (support == 1) {
            p.forVotes += weight;
        } else {
            p.abstainVotes += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    /**
     * @notice Execute a successful proposal
     * @param proposalId Proposal to execute
     */
    function execute(uint256 proposalId) external nonReentrant onlyRole(EXECUTOR_ROLE) {
        Proposal storage p = proposals[proposalId];

        if (state(proposalId) != ProposalState.Succeeded) {
            revert ProposalNotSucceeded();
        }
        if (p.executed) revert ProposalAlreadyExecuted();

        p.executed = true;

        for (uint256 i = 0; i < p.targets.length; i++) {
            (bool success,) = p.targets[i].call{value: p.values[i]}(p.calldatas[i]);
            require(success, "Execution failed");
        }

        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Cancel a proposal
     * @param proposalId Proposal to cancel
     */
    function cancel(uint256 proposalId) external onlyRole(GUARDIAN_ROLE) {
        proposals[proposalId].canceled = true;
        emit ProposalCanceled(proposalId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get proposal state
     */
    function state(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage p = proposals[proposalId];

        if (p.canceled) return ProposalState.Canceled;
        if (p.executed) return ProposalState.Executed;
        if (block.timestamp < p.startTime) return ProposalState.Pending;
        if (block.timestamp <= p.endTime) return ProposalState.Active;

        // Check quorum
        uint256 totalVotes = p.forVotes + p.againstVotes + p.abstainVotes;
        uint256 totalSupply = governanceToken.getPastTotalSupply(p.startTime);
        uint256 quorum = totalSupply * config.quorumBps / BPS;

        if (totalVotes < quorum) return ProposalState.Defeated;
        if (p.forVotes > p.againstVotes) return ProposalState.Succeeded;
        return ProposalState.Defeated;
    }

    /**
     * @notice Get proposal details
     */
    function getProposal(uint256 proposalId) external view returns (
        string memory title,
        string memory description,
        string memory discussionUrl,
        ProposalState proposalState,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 abstainVotes
    ) {
        Proposal storage p = proposals[proposalId];
        return (
            p.title,
            p.description,
            p.discussionUrl,
            state(proposalId),
            p.forVotes,
            p.againstVotes,
            p.abstainVotes
        );
    }

    /**
     * @notice Get GitHub discussion URL for creating discussions
     */
    function getDiscussionUrl() external view returns (string memory) {
        return string(abi.encodePacked(
            "https://github.com/",
            config.githubRepo,
            "/discussions"
        ));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Update sub-DAO configuration
     */
    function updateConfig(SubDAOConfig calldata newConfig) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newConfig.votingPeriod < MIN_VOTING_PERIOD || newConfig.votingPeriod > MAX_VOTING_PERIOD) {
            revert InvalidConfig();
        }
        config = newConfig;
        emit ConfigUpdated(newConfig.name, newConfig.description);
    }

    /**
     * @notice Increase budget allocation
     */
    function increaseBudget(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        config.budgetAllocation += amount;
        emit BudgetIncreased(amount);
    }

    /**
     * @notice Grant proposer role
     */
    function grantProposer(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(PROPOSER_ROLE, account);
    }

    /**
     * @notice Revoke proposer role
     */
    function revokeProposer(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(PROPOSER_ROLE, account);
    }
}
