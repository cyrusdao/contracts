// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.5.0
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Bridgeable} from "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Bridgeable.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Cyrus Token - The Father of Human Rights
/// @notice Quadratic bonding curve token - USDT pricing from $0.01 to $1 (100X)
/// @dev Early buyers get more tokens per dollar via quadratic curve
/// @dev Transfers locked until Nowruz 2026 (March 21, 2026)
/// @custom:security-contact security@cyrus.cash
contract Cyrus is ERC20, ERC20Bridgeable, ERC20Burnable, ERC20Pausable, Ownable, ERC20Permit, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address internal constant SUPERCHAIN_TOKEN_BRIDGE = 0x4200000000000000000000000000000000000028;
    error Unauthorized();
    error TransfersLocked();

    /// @notice Nowruz 2026 - March 21, 2026 12:00:00 UTC (Spring Equinox)
    /// @dev Transfers are locked until this timestamp
    uint256 public constant NOWRUZ_2026 = 1742558400;

    /// @notice USDT on Base (6 decimals)
    IERC20 public immutable USDT;

    /// @notice Maximum supply cap for the token
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10 ** 18; // 1 billion tokens

    /// @notice Amount reserved for initial LP (10%)
    uint256 public constant LP_RESERVE = 100_000_000 * 10 ** 18; // 100M tokens

    /// @notice Amount available for bonding curve sale (90%)
    uint256 public constant SALE_SUPPLY = 900_000_000 * 10 ** 18; // 900M tokens

    /// @notice Starting price: $0.01 (in USDT with 6 decimals = 10000)
    uint256 public constant START_PRICE = 10000; // $0.01 in USDT (6 decimals)

    /// @notice End price: $1.00 (in USDT with 6 decimals = 1000000)
    uint256 public constant END_PRICE = 1000000; // $1.00 in USDT (6 decimals)

    /// @notice Tokens sold through bonding curve
    uint256 public tokensSold;

    /// @notice USDT raised through bonding curve
    uint256 public usdtRaised;

    /// @notice LP wallet for initial liquidity backing
    address public lpWallet;

    /// @notice Whether sale is active
    bool public saleActive = true;

    /// @notice Emitted when tokens are purchased
    event TokensPurchased(address indexed buyer, uint256 usdtAmount, uint256 tokenAmount, uint256 pricePerToken);

    /// @notice Emitted when USDT is sent to LP
    event LPFunded(address indexed lpWallet, uint256 usdtAmount);

    /// @notice Emitted when funds are withdrawn
    event Withdrawn(address indexed to, uint256 amount);

    constructor(address initialOwner, address _usdt, address _lpWallet)
        ERC20("Cyrus", "CYRUS")
        Ownable(initialOwner)
        ERC20Permit("Cyrus")
    {
        require(_usdt != address(0), "Invalid USDT address");
        require(_lpWallet != address(0), "Invalid LP wallet");

        USDT = IERC20(_usdt);
        lpWallet = _lpWallet;

        // Mint LP reserve to LP wallet for initial liquidity at $0.01
        _mint(_lpWallet, LP_RESERVE);
    }

    /// @notice Get current price on quadratic bonding curve (in USDT, 6 decimals)
    /// @dev Quadratic curve: price = startPrice + (endPrice - startPrice) * (sold/total)^2
    /// This gives early buyers significantly more tokens per dollar
    function getCurrentPrice() public view returns (uint256) {
        if (tokensSold >= SALE_SUPPLY) {
            return END_PRICE;
        }

        // Quadratic curve: price increases slowly at first, then accelerates
        // price = START_PRICE + (END_PRICE - START_PRICE) * (tokensSold / SALE_SUPPLY)^2

        // Calculate (tokensSold / SALE_SUPPLY)^2 with precision
        // Using 1e18 precision for intermediate calculation
        uint256 ratio = (tokensSold * 1e18) / SALE_SUPPLY;
        uint256 ratioSquared = (ratio * ratio) / 1e18;

        // price = START_PRICE + (END_PRICE - START_PRICE) * ratioSquared / 1e18
        uint256 priceDelta = END_PRICE - START_PRICE; // 990000
        uint256 priceIncrease = (priceDelta * ratioSquared) / 1e18;

        return START_PRICE + priceIncrease;
    }

    /// @notice Calculate tokens received for USDT amount
    /// @param usdtAmount Amount of USDT to spend (6 decimals)
    /// @return tokenAmount Amount of CYRUS tokens to receive (18 decimals)
    function calculateTokensForUsdt(uint256 usdtAmount) public view returns (uint256 tokenAmount) {
        uint256 remainingUsdt = usdtAmount;
        uint256 tokens = 0;
        uint256 currentSold = tokensSold;

        // Integrate along the quadratic curve in small steps
        // Smaller chunks = more accurate but more gas
        uint256 chunkSize = SALE_SUPPLY / 10000; // 0.01% chunks for precision

        while (remainingUsdt > 0 && currentSold < SALE_SUPPLY) {
            uint256 currentPrice = _getPriceAtSold(currentSold);
            uint256 tokensInChunk = chunkSize;

            if (currentSold + tokensInChunk > SALE_SUPPLY) {
                tokensInChunk = SALE_SUPPLY - currentSold;
            }

            // Cost for this chunk: (tokens * price) / 10^18 (convert token decimals to USDT decimals)
            uint256 chunkCost = (tokensInChunk * currentPrice) / 1e18;

            if (chunkCost == 0) chunkCost = 1; // Minimum 1 wei USDT per chunk

            if (chunkCost <= remainingUsdt) {
                tokens += tokensInChunk;
                remainingUsdt -= chunkCost;
                currentSold += tokensInChunk;
            } else {
                // Partial chunk - calculate how many tokens we can get
                uint256 partialTokens = (remainingUsdt * 1e18) / currentPrice;
                if (partialTokens > 0) {
                    tokens += partialTokens;
                }
                remainingUsdt = 0;
            }
        }

        return tokens;
    }

    /// @notice Buy tokens on bonding curve with USDT
    /// @param usdtAmount Amount of USDT to spend
    /// @param minTokensOut Minimum tokens expected (slippage protection, 0 for no slippage check)
    function buy(uint256 usdtAmount, uint256 minTokensOut) external nonReentrant {
        require(saleActive, "Sale not active");
        require(usdtAmount > 0, "Must send USDT");
        require(tokensSold < SALE_SUPPLY, "Sale complete");

        uint256 tokenAmount = calculateTokensForUsdt(usdtAmount);
        require(tokenAmount > 0, "Insufficient USDT");

        if (minTokensOut > 0) {
            require(tokenAmount >= minTokensOut, "Slippage exceeded");
        }

        if (tokensSold + tokenAmount > SALE_SUPPLY) {
            tokenAmount = SALE_SUPPLY - tokensSold;
            if (minTokensOut > 0) {
                require(tokenAmount >= minTokensOut, "Slippage exceeded");
            }
        }

        // Update state before external calls (checks-effects-interactions)
        tokensSold += tokenAmount;

        // Calculate actual USDT cost for the tokens
        uint256 actualCost = _calculateCostForTokens(tokenAmount);
        require(actualCost <= usdtAmount, "Price calculation error");

        usdtRaised += actualCost;

        // External calls after state updates
        USDT.safeTransferFrom(msg.sender, address(this), actualCost);
        _mint(msg.sender, tokenAmount);

        emit TokensPurchased(msg.sender, actualCost, tokenAmount, getCurrentPrice());

        // Auto-complete sale when sold out
        if (tokensSold >= SALE_SUPPLY) {
            saleActive = false;
        }
    }

    /// @notice Buy tokens with no slippage protection (convenience function)
    /// @param usdtAmount Amount of USDT to spend
    function buy(uint256 usdtAmount) external nonReentrant {
        require(saleActive, "Sale not active");
        require(usdtAmount > 0, "Must send USDT");
        require(tokensSold < SALE_SUPPLY, "Sale complete");

        uint256 tokenAmount = calculateTokensForUsdt(usdtAmount);
        require(tokenAmount > 0, "Insufficient USDT");

        if (tokensSold + tokenAmount > SALE_SUPPLY) {
            tokenAmount = SALE_SUPPLY - tokensSold;
        }

        // Update state before external calls (checks-effects-interactions)
        tokensSold += tokenAmount;

        // Calculate actual USDT cost for the tokens
        uint256 actualCost = _calculateCostForTokens(tokenAmount);
        require(actualCost <= usdtAmount, "Price calculation error");

        usdtRaised += actualCost;

        // External calls after state updates
        USDT.safeTransferFrom(msg.sender, address(this), actualCost);
        _mint(msg.sender, tokenAmount);

        emit TokensPurchased(msg.sender, actualCost, tokenAmount, getCurrentPrice());

        // Auto-complete sale when sold out
        if (tokensSold >= SALE_SUPPLY) {
            saleActive = false;
        }
    }

    /// @notice Calculate USDT cost for a given token amount
    function _calculateCostForTokens(uint256 tokenAmount) internal view returns (uint256) {
        uint256 avgPrice = (_getPriceAtSold(tokensSold) + _getPriceAtSold(tokensSold + tokenAmount)) / 2;
        return (tokenAmount * avgPrice) / 1e18;
    }

    /// @notice Internal price calculation at specific sold amount (quadratic)
    function _getPriceAtSold(uint256 sold) internal pure returns (uint256) {
        if (sold >= SALE_SUPPLY) return END_PRICE;

        uint256 ratio = (sold * 1e18) / SALE_SUPPLY;
        uint256 ratioSquared = (ratio * ratio) / 1e18;
        uint256 priceDelta = END_PRICE - START_PRICE;
        uint256 priceIncrease = (priceDelta * ratioSquared) / 1e18;

        return START_PRICE + priceIncrease;
    }

    /// @notice Send raised USDT to LP wallet for AMM backing
    function fundLP() external onlyOwner {
        uint256 amount = USDT.balanceOf(address(this));
        require(amount > 0, "No USDT to transfer");

        USDT.safeTransfer(lpWallet, amount);
        emit LPFunded(lpWallet, amount);
    }

    /// @notice Withdraw USDT to any address (flexible for LP, treasury, etc.)
    /// @param to Destination address
    /// @param amount Amount to withdraw (0 = all)
    function withdraw(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid destination");
        uint256 balance = USDT.balanceOf(address(this));
        uint256 withdrawAmount = amount == 0 ? balance : amount;
        require(withdrawAmount > 0 && withdrawAmount <= balance, "Invalid amount");

        USDT.safeTransfer(to, withdrawAmount);
        emit Withdrawn(to, withdrawAmount);
    }

    /// @notice Recover any ERC20 tokens accidentally sent to contract
    /// @param token Token address to recover
    /// @param to Destination address
    /// @param amount Amount to recover (0 = all)
    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid destination");
        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));
        uint256 recoverAmount = amount == 0 ? balance : amount;
        require(recoverAmount > 0 && recoverAmount <= balance, "Invalid amount");

        tokenContract.safeTransfer(to, recoverAmount);
        emit Withdrawn(to, recoverAmount);
    }

    /// @notice Update LP wallet address
    function setLPWallet(address _lpWallet) external onlyOwner {
        require(_lpWallet != address(0), "Invalid LP wallet");
        lpWallet = _lpWallet;
    }

    /// @notice End sale early if needed
    function endSale() external onlyOwner {
        saleActive = false;
    }

    /// @notice Resume sale if paused
    function resumeSale() external onlyOwner {
        require(tokensSold < SALE_SUPPLY, "Sale already complete");
        saleActive = true;
    }

    /**
     * @dev Checks if the caller is the predeployed SuperchainTokenBridge
     */
    function _checkTokenBridge(address caller) internal pure override {
        if (caller != SUPERCHAIN_TOKEN_BRIDGE) revert Unauthorized();
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    /// @notice Check if transfers are currently enabled
    function transfersEnabled() public view returns (bool) {
        return block.timestamp >= NOWRUZ_2026;
    }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        // Before Nowruz 2026, only allow:
        // 1. Minting (from == address(0)) - for bonding curve buys
        // 2. Burning (to == address(0)) - for burns
        // 3. LP wallet can transfer (for initial DEX setup)
        if (block.timestamp < NOWRUZ_2026) {
            bool isMint = from == address(0);
            bool isBurn = to == address(0);
            bool isFromLP = from == lpWallet;

            if (!isMint && !isBurn && !isFromLP) {
                revert TransfersLocked();
            }
        }

        super._update(from, to, value);
    }
}
