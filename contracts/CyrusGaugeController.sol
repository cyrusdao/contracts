// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

// @luxfi/standard unified imports - DO NOT import @openzeppelin directly
import {IERC20, IVotes} from "@luxfi/standard/tokens/ERC20.sol";
import {ReentrancyGuard} from "@luxfi/standard/utils/Utils.sol";
import {Ownable2Step, Ownable} from "@luxfi/standard/access/Access.sol";

/// @notice Interface for mintable PARS token
interface IPARSMintable {
    function mint(address to, uint256 amount) external;
}

/// @title CyrusGaugeController - Epoch-Based Emissions Distribution
/// @notice Controls PARS emissions distribution across gauges based on CYRUS voting
/// @dev Voters allocate voting power to gauges, emissions distributed proportionally per epoch
/// @custom:security-contact security@cyrus.cash
contract CyrusGaugeController is ReentrancyGuard, Ownable2Step {

    // ═══════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════

    struct Gauge {
        address gauge;              // Gauge contract address
        string name;                // Human-readable name
        uint256 weight;             // Current weight (votes allocated)
        uint256 lastClaimEpoch;     // Last epoch emissions claimed
        bool active;                // Whether gauge is accepting votes
    }

    struct VoteAllocation {
        uint256 gaugeId;            // Gauge voted for
        uint256 weight;             // Weight allocated (in basis points of user's voting power)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Basis points denominator
    uint256 public constant BPS = 10000;

    /// @notice Epoch duration (1 week)
    uint256 public constant EPOCH_DURATION = 7 days;

    /// @notice Maximum gauges a user can vote for
    uint256 public constant MAX_USER_VOTES = 10;

    /// @notice Nowruz 2026 - when public governance activates
    uint256 public constant NOWRUZ_2026 = 1742558400;

    // ═══════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice CYRUS governance token (for voting power)
    IVotes public immutable cyrus;

    /// @notice PARS emissions token (mintable)
    IPARSMintable public immutable pars;

    /// @notice PARS minter contract
    address public parsMinter;

    /// @notice All registered gauges
    Gauge[] public gauges;

    /// @notice Gauge ID by address (1-indexed, 0 = not found)
    mapping(address => uint256) public gaugeIds;

    /// @notice Current epoch number
    uint256 public currentEpoch;

    /// @notice Epoch start timestamp
    uint256 public epochStartTime;

    /// @notice PARS emissions per epoch (governance-configurable)
    uint256 public emissionsPerEpoch;

    /// @notice Total weight across all gauges for current epoch
    uint256 public totalWeight;

    /// @notice User vote allocations per epoch
    /// @dev user => epoch => allocations
    mapping(address => mapping(uint256 => VoteAllocation[])) public userVotes;

    /// @notice Total weight allocated by user in current epoch
    mapping(address => mapping(uint256 => uint256)) public userWeightUsed;

    /// @notice Weight per gauge per epoch
    mapping(uint256 => mapping(uint256 => uint256)) public gaugeWeightPerEpoch;

    /// @notice Total weight per epoch
    mapping(uint256 => uint256) public totalWeightPerEpoch;

    /// @notice Whether epoch has been finalized
    mapping(uint256 => bool) public epochFinalized;

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event GaugeAdded(uint256 indexed gaugeId, address indexed gauge, string name);
    event GaugeDeactivated(uint256 indexed gaugeId);
    event GaugeReactivated(uint256 indexed gaugeId);
    event VoteCast(address indexed voter, uint256 indexed gaugeId, uint256 weight, uint256 epoch);
    event VotesReset(address indexed voter, uint256 epoch);
    event EpochAdvanced(uint256 indexed epoch, uint256 totalWeight);
    event EmissionsDistributed(uint256 indexed gaugeId, uint256 indexed epoch, uint256 amount);
    event EmissionsPerEpochSet(uint256 oldAmount, uint256 newAmount);
    event ParsMinterSet(address indexed oldMinter, address indexed newMinter);

    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error GaugeNotActive();
    error GaugeAlreadyExists();
    error InvalidGaugeId();
    error ExceedsVotingPower();
    error TooManyVotes();
    error EpochNotEnded();
    error AlreadyFinalized();
    error NotFinalized();
    error VotingNotActive();
    error InvalidWeight();

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Initialize the GaugeController
    /// @param _cyrus CYRUS governance token address
    /// @param _pars PARS emissions token address
    /// @param _emissionsPerEpoch Initial PARS emissions per epoch
    /// @param initialOwner Governance address
    constructor(
        address _cyrus,
        address _pars,
        uint256 _emissionsPerEpoch,
        address initialOwner
    ) Ownable(initialOwner) {
        if (_cyrus == address(0) || _pars == address(0)) revert ZeroAddress();

        cyrus = IVotes(_cyrus);
        pars = IPARSMintable(_pars);
        emissionsPerEpoch = _emissionsPerEpoch;

        // Start first epoch
        currentEpoch = 1;
        epochStartTime = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VOTING
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Vote for gauges with weight allocation
    /// @param allocations Array of vote allocations (gaugeId, weight in BPS)
    function vote(VoteAllocation[] calldata allocations) external nonReentrant {
        // Advance epoch if needed
        _tryAdvanceEpoch();

        // Validate user hasn't already voted this epoch (must reset first)
        if (userVotes[msg.sender][currentEpoch].length > 0) revert VotingNotActive();
        if (allocations.length > MAX_USER_VOTES) revert TooManyVotes();

        // Get user's voting power
        uint256 votingPower = cyrus.getVotes(msg.sender);
        uint256 totalAllocated = 0;

        // Process each allocation
        for (uint256 i = 0; i < allocations.length; i++) {
            VoteAllocation memory alloc = allocations[i];

            // Validate gauge
            if (alloc.gaugeId == 0 || alloc.gaugeId > gauges.length) revert InvalidGaugeId();
            Gauge storage gauge = gauges[alloc.gaugeId - 1];
            if (!gauge.active) revert GaugeNotActive();

            // Validate weight
            if (alloc.weight == 0 || alloc.weight > BPS) revert InvalidWeight();
            totalAllocated += alloc.weight;
            if (totalAllocated > BPS) revert ExceedsVotingPower();

            // Calculate actual weight (user voting power * allocation percentage)
            uint256 actualWeight = votingPower * alloc.weight / BPS;

            // Update gauge weight
            gauge.weight += actualWeight;
            gaugeWeightPerEpoch[alloc.gaugeId][currentEpoch] += actualWeight;
            totalWeight += actualWeight;

            // Store user vote
            userVotes[msg.sender][currentEpoch].push(alloc);

            emit VoteCast(msg.sender, alloc.gaugeId, actualWeight, currentEpoch);
        }

        userWeightUsed[msg.sender][currentEpoch] = totalAllocated;
    }

    /// @notice Reset votes for current epoch (allows re-voting)
    function resetVotes() external nonReentrant {
        _tryAdvanceEpoch();

        VoteAllocation[] storage allocations = userVotes[msg.sender][currentEpoch];
        if (allocations.length == 0) return;

        uint256 votingPower = cyrus.getVotes(msg.sender);

        // Remove weight from each gauge
        for (uint256 i = 0; i < allocations.length; i++) {
            VoteAllocation memory alloc = allocations[i];
            uint256 actualWeight = votingPower * alloc.weight / BPS;

            Gauge storage gauge = gauges[alloc.gaugeId - 1];
            gauge.weight -= actualWeight;
            gaugeWeightPerEpoch[alloc.gaugeId][currentEpoch] -= actualWeight;
            totalWeight -= actualWeight;
        }

        // Clear user votes
        delete userVotes[msg.sender][currentEpoch];
        userWeightUsed[msg.sender][currentEpoch] = 0;

        emit VotesReset(msg.sender, currentEpoch);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EPOCH MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Advance to next epoch (can be called by anyone)
    function advanceEpoch() external {
        _advanceEpoch();
    }

    /// @notice Try to advance epoch if duration has passed
    function _tryAdvanceEpoch() internal {
        if (block.timestamp >= epochStartTime + EPOCH_DURATION) {
            _advanceEpoch();
        }
    }

    /// @notice Internal epoch advancement
    function _advanceEpoch() internal {
        if (block.timestamp < epochStartTime + EPOCH_DURATION) revert EpochNotEnded();

        // Finalize current epoch
        totalWeightPerEpoch[currentEpoch] = totalWeight;
        epochFinalized[currentEpoch] = true;

        emit EpochAdvanced(currentEpoch, totalWeight);

        // Start new epoch
        currentEpoch++;
        epochStartTime = block.timestamp;
        totalWeight = 0;

        // Reset gauge weights for new epoch
        for (uint256 i = 0; i < gauges.length; i++) {
            gauges[i].weight = 0;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EMISSIONS DISTRIBUTION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Claim emissions for a gauge for a specific epoch
    /// @param gaugeId Gauge ID to claim for
    /// @param epoch Epoch to claim for
    /// @return amount PARS emissions amount
    function claimEmissions(uint256 gaugeId, uint256 epoch) external nonReentrant returns (uint256 amount) {
        if (gaugeId == 0 || gaugeId > gauges.length) revert InvalidGaugeId();
        if (!epochFinalized[epoch]) revert NotFinalized();

        Gauge storage gauge = gauges[gaugeId - 1];
        if (gauge.lastClaimEpoch >= epoch) return 0;

        uint256 epochWeight = gaugeWeightPerEpoch[gaugeId][epoch];
        uint256 epochTotalWeight = totalWeightPerEpoch[epoch];

        if (epochTotalWeight == 0) {
            gauge.lastClaimEpoch = epoch;
            return 0;
        }

        // Calculate proportional emissions
        amount = emissionsPerEpoch * epochWeight / epochTotalWeight;

        gauge.lastClaimEpoch = epoch;

        // Mint PARS directly to gauge
        if (amount > 0) {
            pars.mint(gauge.gauge, amount);
        }

        emit EmissionsDistributed(gaugeId, epoch, amount);
    }

    /// @notice Claim emissions for multiple epochs
    /// @param gaugeId Gauge ID to claim for
    /// @param epochs Array of epochs to claim
    /// @return total Total PARS claimed
    function claimMultipleEpochs(uint256 gaugeId, uint256[] calldata epochs) external nonReentrant returns (uint256 total) {
        for (uint256 i = 0; i < epochs.length; i++) {
            total += _claimEmissionsInternal(gaugeId, epochs[i]);
        }
    }

    function _claimEmissionsInternal(uint256 gaugeId, uint256 epoch) internal returns (uint256 amount) {
        if (gaugeId == 0 || gaugeId > gauges.length) revert InvalidGaugeId();
        if (!epochFinalized[epoch]) return 0;

        Gauge storage gauge = gauges[gaugeId - 1];
        if (gauge.lastClaimEpoch >= epoch) return 0;

        uint256 epochWeight = gaugeWeightPerEpoch[gaugeId][epoch];
        uint256 epochTotalWeight = totalWeightPerEpoch[epoch];

        if (epochTotalWeight == 0) {
            gauge.lastClaimEpoch = epoch;
            return 0;
        }

        amount = emissionsPerEpoch * epochWeight / epochTotalWeight;
        gauge.lastClaimEpoch = epoch;

        if (amount > 0) {
            pars.mint(gauge.gauge, amount);
            emit EmissionsDistributed(gaugeId, epoch, amount);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Get number of gauges
    function gaugeCount() external view returns (uint256) {
        return gauges.length;
    }

    /// @notice Get gauge info by ID
    function getGauge(uint256 gaugeId) external view returns (Gauge memory) {
        if (gaugeId == 0 || gaugeId > gauges.length) revert InvalidGaugeId();
        return gauges[gaugeId - 1];
    }

    /// @notice Get user's votes for an epoch
    function getUserVotes(address user, uint256 epoch) external view returns (VoteAllocation[] memory) {
        return userVotes[user][epoch];
    }

    /// @notice Get pending emissions for a gauge
    function pendingEmissions(uint256 gaugeId) external view returns (uint256 total) {
        if (gaugeId == 0 || gaugeId > gauges.length) return 0;

        Gauge storage gauge = gauges[gaugeId - 1];
        uint256 lastClaimed = gauge.lastClaimEpoch;

        for (uint256 epoch = lastClaimed + 1; epoch < currentEpoch; epoch++) {
            if (epochFinalized[epoch]) {
                uint256 epochWeight = gaugeWeightPerEpoch[gaugeId][epoch];
                uint256 epochTotalWeight = totalWeightPerEpoch[epoch];
                if (epochTotalWeight > 0) {
                    total += emissionsPerEpoch * epochWeight / epochTotalWeight;
                }
            }
        }
    }

    /// @notice Time until next epoch
    function timeUntilNextEpoch() external view returns (uint256) {
        uint256 nextEpoch = epochStartTime + EPOCH_DURATION;
        if (block.timestamp >= nextEpoch) return 0;
        return nextEpoch - block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS (Owner = Governance)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Add a new gauge
    /// @param gauge Gauge contract address
    /// @param name Human-readable name
    /// @return gaugeId The new gauge's ID
    function addGauge(address gauge, string calldata name) external onlyOwner returns (uint256 gaugeId) {
        if (gauge == address(0)) revert ZeroAddress();
        if (gaugeIds[gauge] != 0) revert GaugeAlreadyExists();

        gauges.push(Gauge({
            gauge: gauge,
            name: name,
            weight: 0,
            lastClaimEpoch: currentEpoch > 0 ? currentEpoch - 1 : 0,
            active: true
        }));

        gaugeId = gauges.length;
        gaugeIds[gauge] = gaugeId;

        emit GaugeAdded(gaugeId, gauge, name);
    }

    /// @notice Deactivate a gauge (no new votes, can still claim)
    function deactivateGauge(uint256 gaugeId) external onlyOwner {
        if (gaugeId == 0 || gaugeId > gauges.length) revert InvalidGaugeId();
        gauges[gaugeId - 1].active = false;
        emit GaugeDeactivated(gaugeId);
    }

    /// @notice Reactivate a gauge
    function reactivateGauge(uint256 gaugeId) external onlyOwner {
        if (gaugeId == 0 || gaugeId > gauges.length) revert InvalidGaugeId();
        gauges[gaugeId - 1].active = true;
        emit GaugeReactivated(gaugeId);
    }

    /// @notice Set PARS emissions per epoch
    function setEmissionsPerEpoch(uint256 newAmount) external onlyOwner {
        emit EmissionsPerEpochSet(emissionsPerEpoch, newAmount);
        emissionsPerEpoch = newAmount;
    }

    /// @notice Set PARS minter address (for receiving emissions)
    function setParsMinter(address newMinter) external onlyOwner {
        emit ParsMinterSet(parsMinter, newMinter);
        parsMinter = newMinter;
    }
}
