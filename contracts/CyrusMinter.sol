// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

// @luxfi/standard unified imports - DO NOT import @openzeppelin directly
import {IERC20} from "@luxfi/standard/tokens/ERC20.sol";
import {ReentrancyGuard} from "@luxfi/standard/utils/Utils.sol";
import {Ownable} from "@luxfi/standard/access/Access.sol";

/// @title CyrusMinter - Progressive Fee Free Mint
/// @notice Allows users to mint CYRUS tokens with a progressive fee that goes to protocol-owned liquidity
/// @dev All fees are permanently added to Uniswap V3 liquidity - no one can withdraw
/// @custom:security-contact security@cyrus.cash
contract CyrusMinter is Ownable, ReentrancyGuard {
    /// @notice CYRUS token contract
    IERC20 public immutable cyrusToken;

    /// @notice Uniswap V3 NonfungiblePositionManager on Base
    address public constant UNISWAP_NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;

    /// @notice WETH on Base
    address public constant WETH = 0x4200000000000000000000000000000000000006;

    /// @notice Amount of CYRUS each user can mint
    uint256 public constant MINT_AMOUNT = 1_000 * 10 ** 18; // 1,000 CYRUS

    /// @notice Total CYRUS available for minting (70% of supply = 700M)
    uint256 public constant TOTAL_MINT_ALLOCATION = 700_000_000 * 10 ** 18;

    /// @notice Starting fee percentage (in basis points, 100 = 1%)
    uint256 public constant START_FEE_BPS = 100; // 1%

    /// @notice Ending fee percentage (in basis points, 10000 = 100%)
    uint256 public constant END_FEE_BPS = 10000; // 100%

    /// @notice Total CYRUS distributed through minting
    uint256 public totalMinted;

    /// @notice Track who has already minted
    mapping(address => bool) public hasMinted;

    /// @notice Protocol-owned liquidity position NFT ID
    uint256 public liquidityPositionId;

    /// @notice Emitted when someone mints
    event Mint(address indexed user, uint256 cyrusAmount, uint256 ethPaid, uint256 feeBps);

    /// @notice Emitted when fees are added to liquidity
    event LiquidityAdded(uint256 ethAmount, uint256 newLiquidity);

    error AlreadyMinted();
    error MintingComplete();
    error InsufficientPayment();
    error TransferFailed();

    constructor(
        address _cyrusToken,
        address initialOwner
    ) Ownable(initialOwner) {
        cyrusToken = IERC20(_cyrusToken);
    }

    /// @notice Calculate the current fee in basis points based on mint progress
    /// @return feeBps Current fee in basis points (100 = 1%, 10000 = 100%)
    function getCurrentFeeBps() public view returns (uint256) {
        if (totalMinted >= TOTAL_MINT_ALLOCATION) {
            return END_FEE_BPS;
        }

        // Linear interpolation from START_FEE_BPS to END_FEE_BPS
        // fee = START + (END - START) * (minted / total)
        uint256 progress = (totalMinted * 10000) / TOTAL_MINT_ALLOCATION;
        uint256 feeBps = START_FEE_BPS + ((END_FEE_BPS - START_FEE_BPS) * progress) / 10000;

        return feeBps;
    }

    /// @notice Calculate the ETH required to mint at current fee level
    /// @return ethRequired Amount of ETH needed (fee only, the "free" part is actually free)
    function getMintCost() public view returns (uint256) {
        uint256 feeBps = getCurrentFeeBps();
        // The fee is based on a base price. Let's say base price is 0.0001 ETH per CYRUS
        // So for 1000 CYRUS, base would be 0.1 ETH
        // Fee = basePrice * feeBps / 10000
        uint256 basePrice = 0.1 ether; // Base price for 1000 CYRUS
        return (basePrice * feeBps) / 10000;
    }

    /// @notice Mint CYRUS tokens with progressive fee
    /// @dev All ETH paid goes to protocol-owned liquidity
    function mint() external payable nonReentrant {
        if (hasMinted[msg.sender]) revert AlreadyMinted();
        if (totalMinted >= TOTAL_MINT_ALLOCATION) revert MintingComplete();

        uint256 feeBps = getCurrentFeeBps();
        uint256 cost = getMintCost();

        if (msg.value < cost) revert InsufficientPayment();

        // Mark as minted
        hasMinted[msg.sender] = true;
        totalMinted += MINT_AMOUNT;

        // Transfer CYRUS to user
        bool success = cyrusToken.transfer(msg.sender, MINT_AMOUNT);
        if (!success) revert TransferFailed();

        // Refund excess ETH
        if (msg.value > cost) {
            (bool refundSuccess, ) = msg.sender.call{value: msg.value - cost}("");
            if (!refundSuccess) revert TransferFailed();
        }

        emit Mint(msg.sender, MINT_AMOUNT, cost, feeBps);
    }

    /// @notice Add accumulated ETH to Uniswap V3 liquidity
    /// @dev Anyone can call this to add liquidity - all ETH becomes protocol-owned LP
    function addLiquidity() external nonReentrant {
        uint256 ethBalance = address(this).balance;
        require(ethBalance > 0, "No ETH to add");

        // Wrap ETH to WETH
        (bool wrapSuccess, ) = WETH.call{value: ethBalance}("");
        require(wrapSuccess, "WETH wrap failed");

        // Approve WETH for Uniswap
        IERC20(WETH).approve(UNISWAP_NPM, ethBalance);

        // If we have an existing position, increase liquidity
        // If not, create a new position
        if (liquidityPositionId > 0) {
            _increaseLiquidity(ethBalance);
        } else {
            _createPosition(ethBalance);
        }

        emit LiquidityAdded(ethBalance, ethBalance);
    }

    /// @notice Create new Uniswap V3 position
    function _createPosition(uint256 wethAmount) internal {
        // Simplified - in production this would use proper tick math
        // Position parameters matching the initial LP setup
        bytes memory data = abi.encodeWithSignature(
            "mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))",
            WETH,                    // token0
            address(cyrusToken),     // token1
            uint24(10000),           // fee (1%)
            int24(23000),            // tickLower
            int24(92000),            // tickUpper
            wethAmount,              // amount0Desired
            uint256(0),              // amount1Desired
            uint256(0),              // amount0Min
            uint256(0),              // amount1Min
            address(this),           // recipient (contract owns the position)
            block.timestamp + 1800   // deadline
        );

        (bool success, bytes memory result) = UNISWAP_NPM.call(data);
        require(success, "Position creation failed");

        // Decode the tokenId from result
        (uint256 tokenId, , , ) = abi.decode(result, (uint256, uint128, uint256, uint256));
        liquidityPositionId = tokenId;
    }

    /// @notice Increase liquidity in existing position
    function _increaseLiquidity(uint256 wethAmount) internal {
        bytes memory data = abi.encodeWithSignature(
            "increaseLiquidity((uint256,uint256,uint256,uint256,uint256,uint256))",
            liquidityPositionId,
            wethAmount,              // amount0Desired
            uint256(0),              // amount1Desired
            uint256(0),              // amount0Min
            uint256(0),              // amount1Min
            block.timestamp + 1800   // deadline
        );

        (bool success, ) = UNISWAP_NPM.call(data);
        require(success, "Liquidity increase failed");
    }

    /// @notice Get mint statistics
    function getMintStats() external view returns (
        uint256 minted,
        uint256 remaining,
        uint256 currentFeeBps,
        uint256 currentCost,
        uint256 pendingLiquidity
    ) {
        minted = totalMinted;
        remaining = TOTAL_MINT_ALLOCATION > totalMinted ? TOTAL_MINT_ALLOCATION - totalMinted : 0;
        currentFeeBps = getCurrentFeeBps();
        currentCost = getMintCost();
        pendingLiquidity = address(this).balance;
    }

    /// @notice Check if an address has already minted
    function canMint(address user) external view returns (bool) {
        return !hasMinted[user] && totalMinted < TOTAL_MINT_ALLOCATION;
    }

    /// @notice Receive ETH
    receive() external payable {}
}
