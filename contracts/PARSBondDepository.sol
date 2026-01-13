// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

// @luxfi/standard unified imports - DO NOT import @openzeppelin directly
import {IERC20, SafeERC20} from "@luxfi/standard/tokens/ERC20.sol";
import {ReentrancyGuard} from "@luxfi/standard/utils/Utils.sol";
import {Ownable} from "@luxfi/standard/access/Access.sol";
import {IPARS} from "./interfaces/IPARS.sol";

/**
 * @title PARSBondDepository
 * @notice OHM-style bond depository for PARS token
 *
 * Users deposit reserve assets (USDC, ETH) or LP tokens at a discount
 * in exchange for vested PARS payouts. This enables the protocol to:
 * - Accumulate reserve assets (treasury)
 * - Acquire protocol-owned liquidity (POL)
 *
 * Payout Formula:
 *   M(V) = 1 + β * (V / Vmax)²     [quadratic duration multiplier]
 *   payout = (depositUSD / P_pars) * (1 + discount) * M(V)
 *
 * Safety Constraints:
 * - maxPayoutPerBond (per-bond cap)
 * - maxPayoutPerEpoch (epoch budget)
 * - maxDebt (total outstanding unvested)
 * - TWAP pricing for manipulation resistance
 */
contract PARSBondDepository is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Bond market configuration
    struct BondMarket {
        address depositToken;       // Token to deposit (reserve or LP)
        bool isLPToken;             // True if LP token
        uint256 discountBps;        // Base discount in basis points (e.g., 500 = 5%)
        uint256 minVesting;         // Minimum vesting duration (seconds)
        uint256 maxVesting;         // Maximum vesting duration (seconds)
        uint256 betaBps;            // Duration bonus multiplier (e.g., 20000 = 2x max bonus)
        uint256 maxPayoutPerBond;   // Max PARS per single bond
        uint256 epochBudget;        // Max PARS bonded per epoch for this market
        uint256 epochBonded;        // PARS bonded this epoch (resets each epoch)
        uint256 lastEpochReset;     // Timestamp of last epoch reset
        bool active;                // Market enabled
    }

    /// @notice User's bond position
    struct Bond {
        uint256 marketId;           // Which market
        uint256 payout;             // Total PARS to receive
        uint256 vesting;            // Vesting duration (seconds)
        uint256 lastClaim;          // Last claim timestamp
        uint256 depositedAt;        // Bond creation timestamp
        uint256 claimed;            // PARS already claimed
    }

    /// @notice TWAP observation
    struct TWAPObservation {
        uint256 price;              // Price in USD (18 decimals)
        uint256 timestamp;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice PARS token
    IPARS public immutable pars;

    /// @notice Treasury address
    address public treasury;

    /// @notice Epoch duration (default 7 days)
    uint256 public epochDuration = 7 days;

    /// @notice PARS price in USD (18 decimals) - set by oracle/governance
    uint256 public parsPrice = 1e18; // $1.00 default

    /// @notice Maximum total unvested PARS (debt ceiling)
    uint256 public maxDebt = 10_000_000e18; // 10M PARS

    /// @notice Current total unvested PARS
    uint256 public totalDebt;

    /// @notice Bond markets
    mapping(uint256 => BondMarket) public markets;
    uint256 public marketCount;

    /// @notice User bonds: user => bondId => Bond
    mapping(address => mapping(uint256 => Bond)) public bonds;
    mapping(address => uint256) public bondCount;

    /// @notice Asset price feeds (token => USD price, 18 decimals)
    mapping(address => uint256) public assetPrices;

    /// @notice TWAP observations for assets
    mapping(address => TWAPObservation[]) public twapObservations;
    uint256 public constant TWAP_WINDOW = 30 minutes;
    uint256 public constant TWAP_GRANULARITY = 12; // 12 observations

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event MarketCreated(uint256 indexed marketId, address depositToken, bool isLP);
    event MarketUpdated(uint256 indexed marketId);
    event BondCreated(
        address indexed user,
        uint256 indexed bondId,
        uint256 indexed marketId,
        uint256 depositAmount,
        uint256 payout,
        uint256 vesting
    );
    event BondClaimed(address indexed user, uint256 indexed bondId, uint256 amount);
    event PriceUpdated(address indexed token, uint256 price);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error MarketInactive();
    error InvalidVesting();
    error ExceedsMaxPayout();
    error ExceedsEpochBudget();
    error ExceedsMaxDebt();
    error InvalidPrice();
    error NothingToClaim();
    error InvalidMarket();

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    constructor(
        address _pars,
        address _treasury,
        address _owner
    ) Ownable(_owner) {
        pars = IPARS(_pars);
        treasury = _treasury;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BOND FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Create a bond by depositing assets
     * @param marketId Bond market ID
     * @param amount Amount of deposit token
     * @param vestingDuration Vesting duration in seconds
     * @return bondId The created bond ID
     * @return payout The PARS payout amount
     */
    function bond(
        uint256 marketId,
        uint256 amount,
        uint256 vestingDuration
    ) external nonReentrant returns (uint256 bondId, uint256 payout) {
        BondMarket storage market = markets[marketId];

        if (!market.active) revert MarketInactive();
        if (vestingDuration < market.minVesting || vestingDuration > market.maxVesting) {
            revert InvalidVesting();
        }

        // Reset epoch budget if new epoch
        _maybeResetEpoch(marketId);

        // Calculate deposit USD value
        uint256 depositUSD = _calculateDepositValue(market.depositToken, amount, market.isLPToken);

        // Calculate payout with quadratic duration multiplier
        payout = _calculatePayout(depositUSD, market.discountBps, vestingDuration, market.maxVesting, market.betaBps);

        // Safety checks
        if (payout > market.maxPayoutPerBond) revert ExceedsMaxPayout();
        if (market.epochBonded + payout > market.epochBudget) revert ExceedsEpochBudget();
        if (totalDebt + payout > maxDebt) revert ExceedsMaxDebt();

        // Update state
        market.epochBonded += payout;
        totalDebt += payout;

        // Transfer deposit to treasury
        IERC20(market.depositToken).safeTransferFrom(msg.sender, treasury, amount);

        // Create bond
        bondId = bondCount[msg.sender]++;
        bonds[msg.sender][bondId] = Bond({
            marketId: marketId,
            payout: payout,
            vesting: vestingDuration,
            lastClaim: block.timestamp,
            depositedAt: block.timestamp,
            claimed: 0
        });

        emit BondCreated(msg.sender, bondId, marketId, amount, payout, vestingDuration);
    }

    /**
     * @notice Claim vested PARS from a bond
     * @param bondId Bond ID to claim from
     * @return amount PARS claimed
     */
    function claim(uint256 bondId) external nonReentrant returns (uint256 amount) {
        Bond storage userBond = bonds[msg.sender][bondId];
        if (userBond.payout == 0) revert InvalidMarket();

        amount = _claimable(userBond);
        if (amount == 0) revert NothingToClaim();

        userBond.lastClaim = block.timestamp;
        userBond.claimed += amount;
        totalDebt -= amount;

        // Mint PARS to user (requires MINTER_ROLE on PARS)
        pars.mint(msg.sender, amount);

        emit BondClaimed(msg.sender, bondId, amount);
    }

    /**
     * @notice Claim all vested PARS from multiple bonds
     * @param bondIds Array of bond IDs
     * @return total Total PARS claimed
     */
    function claimAll(uint256[] calldata bondIds) external nonReentrant returns (uint256 total) {
        for (uint256 i = 0; i < bondIds.length; i++) {
            Bond storage userBond = bonds[msg.sender][bondIds[i]];
            if (userBond.payout == 0) continue;

            uint256 amount = _claimable(userBond);
            if (amount == 0) continue;

            userBond.lastClaim = block.timestamp;
            userBond.claimed += amount;
            totalDebt -= amount;
            total += amount;

            emit BondClaimed(msg.sender, bondIds[i], amount);
        }

        if (total > 0) {
            pars.mint(msg.sender, total);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get claimable PARS for a bond
     */
    function claimable(address user, uint256 bondId) external view returns (uint256) {
        return _claimable(bonds[user][bondId]);
    }

    /**
     * @notice Preview payout for a potential bond
     */
    function previewBond(
        uint256 marketId,
        uint256 amount,
        uint256 vestingDuration
    ) external view returns (uint256 payout, uint256 depositUSD) {
        BondMarket storage market = markets[marketId];

        depositUSD = _calculateDepositValue(market.depositToken, amount, market.isLPToken);
        payout = _calculatePayout(depositUSD, market.discountBps, vestingDuration, market.maxVesting, market.betaBps);
    }

    /**
     * @notice Get remaining epoch budget for a market
     */
    function remainingEpochBudget(uint256 marketId) external view returns (uint256) {
        BondMarket storage market = markets[marketId];

        // Check if epoch has reset
        if (block.timestamp >= market.lastEpochReset + epochDuration) {
            return market.epochBudget;
        }

        return market.epochBudget > market.epochBonded ? market.epochBudget - market.epochBonded : 0;
    }

    /**
     * @notice Get all user bonds info
     */
    function getUserBonds(address user) external view returns (Bond[] memory) {
        uint256 count = bondCount[user];
        Bond[] memory userBonds = new Bond[](count);
        for (uint256 i = 0; i < count; i++) {
            userBonds[i] = bonds[user][i];
        }
        return userBonds;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // GOVERNANCE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Create a new bond market
     */
    function createMarket(
        address depositToken,
        bool isLPToken,
        uint256 discountBps,
        uint256 minVesting,
        uint256 maxVesting,
        uint256 betaBps,
        uint256 maxPayoutPerBond,
        uint256 epochBudget
    ) external onlyOwner returns (uint256 marketId) {
        marketId = marketCount++;

        markets[marketId] = BondMarket({
            depositToken: depositToken,
            isLPToken: isLPToken,
            discountBps: discountBps,
            minVesting: minVesting,
            maxVesting: maxVesting,
            betaBps: betaBps,
            maxPayoutPerBond: maxPayoutPerBond,
            epochBudget: epochBudget,
            epochBonded: 0,
            lastEpochReset: block.timestamp,
            active: true
        });

        emit MarketCreated(marketId, depositToken, isLPToken);
    }

    /**
     * @notice Update market parameters
     */
    function updateMarket(
        uint256 marketId,
        uint256 discountBps,
        uint256 minVesting,
        uint256 maxVesting,
        uint256 betaBps,
        uint256 maxPayoutPerBond,
        uint256 epochBudget,
        bool active
    ) external onlyOwner {
        BondMarket storage market = markets[marketId];
        if (market.depositToken == address(0)) revert InvalidMarket();

        market.discountBps = discountBps;
        market.minVesting = minVesting;
        market.maxVesting = maxVesting;
        market.betaBps = betaBps;
        market.maxPayoutPerBond = maxPayoutPerBond;
        market.epochBudget = epochBudget;
        market.active = active;

        emit MarketUpdated(marketId);
    }

    /**
     * @notice Set asset price (for assets without oracle)
     */
    function setAssetPrice(address token, uint256 price) external onlyOwner {
        if (price == 0) revert InvalidPrice();
        assetPrices[token] = price;

        // Add TWAP observation
        _addTWAPObservation(token, price);

        emit PriceUpdated(token, price);
    }

    /**
     * @notice Set PARS price
     */
    function setParsPrice(uint256 price) external onlyOwner {
        if (price == 0) revert InvalidPrice();
        parsPrice = price;
        emit PriceUpdated(address(pars), price);
    }

    /**
     * @notice Set treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    /**
     * @notice Set max debt ceiling
     */
    function setMaxDebt(uint256 _maxDebt) external onlyOwner {
        maxDebt = _maxDebt;
    }

    /**
     * @notice Set epoch duration
     */
    function setEpochDuration(uint256 _epochDuration) external onlyOwner {
        epochDuration = _epochDuration;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate deposit value in USD
     */
    function _calculateDepositValue(
        address token,
        uint256 amount,
        bool isLPToken
    ) internal view returns (uint256) {
        if (isLPToken) {
            // For LP tokens, get total value of underlying
            // Simplified: assume LP token price is stored directly
            return (amount * _getTWAP(token)) / 1e18;
        } else {
            // For reserve assets, use TWAP
            return (amount * _getTWAP(token)) / 1e18;
        }
    }

    /**
     * @notice Calculate payout with quadratic duration multiplier
     * @dev M(V) = 1 + β * (V / Vmax)²
     *      payout = (depositUSD / P_pars) * (1 + discount) * M(V)
     */
    function _calculatePayout(
        uint256 depositUSD,
        uint256 discountBps,
        uint256 vesting,
        uint256 maxVesting,
        uint256 betaBps
    ) internal view returns (uint256) {
        // Base payout without bonuses
        uint256 basePayout = (depositUSD * 1e18) / parsPrice;

        // Apply discount: (1 + discount/10000)
        uint256 withDiscount = (basePayout * (10000 + discountBps)) / 10000;

        // Calculate quadratic multiplier: M(V) = 1 + β * (V/Vmax)²
        // All in basis points for precision
        uint256 vestingRatio = (vesting * 10000) / maxVesting; // 0 to 10000
        uint256 vestingRatioSquared = (vestingRatio * vestingRatio) / 10000; // (V/Vmax)² in bps
        uint256 multiplier = 10000 + (betaBps * vestingRatioSquared) / 10000; // 1 + β*(V/Vmax)²

        return (withDiscount * multiplier) / 10000;
    }

    /**
     * @notice Calculate claimable amount for a bond
     */
    function _claimable(Bond storage userBond) internal view returns (uint256) {
        if (userBond.payout == 0) return 0;

        uint256 elapsed = block.timestamp - userBond.depositedAt;
        uint256 vested;

        if (elapsed >= userBond.vesting) {
            vested = userBond.payout;
        } else {
            vested = (userBond.payout * elapsed) / userBond.vesting;
        }

        return vested > userBond.claimed ? vested - userBond.claimed : 0;
    }

    /**
     * @notice Get TWAP for an asset
     */
    function _getTWAP(address token) internal view returns (uint256) {
        TWAPObservation[] storage observations = twapObservations[token];

        if (observations.length == 0) {
            // Fallback to spot price
            return assetPrices[token];
        }

        // Calculate TWAP from observations within window
        uint256 windowStart = block.timestamp > TWAP_WINDOW ? block.timestamp - TWAP_WINDOW : 0;
        uint256 priceSum = 0;
        uint256 count = 0;

        for (uint256 i = observations.length; i > 0; i--) {
            TWAPObservation storage obs = observations[i - 1];
            if (obs.timestamp < windowStart) break;
            priceSum += obs.price;
            count++;
        }

        return count > 0 ? priceSum / count : assetPrices[token];
    }

    /**
     * @notice Add TWAP observation
     */
    function _addTWAPObservation(address token, uint256 price) internal {
        twapObservations[token].push(TWAPObservation({
            price: price,
            timestamp: block.timestamp
        }));

        // Prune old observations
        TWAPObservation[] storage observations = twapObservations[token];
        uint256 windowStart = block.timestamp > TWAP_WINDOW ? block.timestamp - TWAP_WINDOW : 0;

        while (observations.length > TWAP_GRANULARITY && observations[0].timestamp < windowStart) {
            // Shift array (expensive but keeps it bounded)
            for (uint256 i = 0; i < observations.length - 1; i++) {
                observations[i] = observations[i + 1];
            }
            observations.pop();
        }
    }

    /**
     * @notice Reset epoch budget if new epoch
     */
    function _maybeResetEpoch(uint256 marketId) internal {
        BondMarket storage market = markets[marketId];

        if (block.timestamp >= market.lastEpochReset + epochDuration) {
            market.epochBonded = 0;
            market.lastEpochReset = block.timestamp;
        }
    }
}
