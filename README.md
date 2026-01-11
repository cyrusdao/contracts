# CYRUS Token

> *"The Father of Human Rights"*

A USDT-based bonding curve token honoring Cyrus the Great and his legacy of human rights.

## The Vision

Cyrus the Great (c. 600-530 BC), founder of the Achaemenid Empire, created the first declaration of human rights - the Cyrus Cylinder. This token honors his legacy and the timeless principles of freedom, tolerance, and human dignity.

## Token Details

- **Name:** Cyrus
- **Symbol:** CYRUS
- **Chain:** Base (Omnichain via Superchain)
- **Max Supply:** 1,000,000,000 CYRUS
- **LP Reserve:** 100,000,000 CYRUS (10%) - minted to LP wallet at deploy
- **Bonding Curve Sale:** 900,000,000 CYRUS (90%)

## Bonding Curve (USDT-based)

The token uses a quadratic bonding curve with USDT pricing:

| Phase | Price | Notes |
|-------|-------|-------|
| Start | $0.01 | Early supporters |
| End | $1.00 | 100x from start |

```solidity
// Buy tokens with USDT (with slippage protection)
function buy(uint256 usdtAmount, uint256 minTokensOut) external

// Buy tokens with USDT (no slippage protection)
function buy(uint256 usdtAmount) external

// Check current price
function getCurrentPrice() public view returns (uint256)

// Calculate tokens for USDT amount
function calculateTokensForUsdt(uint256 usdtAmount) public view returns (uint256)
```

## Constructor Arguments

The Cyrus contract requires 3 constructor arguments:

1. `initialOwner` - Owner address (controls pause, LP functions)
2. `_usdt` - USDT/USDC contract address on Base
3. `_lpWallet` - Wallet to receive 100M CYRUS for initial LP

## Deployment

### 1. Configure Environment

```bash
cp .env.example .env
```

Edit `.env` with your values:

```bash
# Required
PRIVATE_KEY=your_private_key_here
LP_WALLET=0xYourLPWalletAddress

# Optional (defaults provided)
USDT_ADDRESS=0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA  # USDbC on Base
```

### 2. Install Dependencies

```bash
npm install
```

### 3. Compile Contracts

```bash
npm run compile
```

### 4. Run Tests

```bash
npm test
```

### 5. Deploy

**Base Sepolia (Testnet):**
```bash
npm run deploy:baseSepolia
```

**Base Mainnet:**
```bash
npm run deploy:base
```

### 6. Verify Contract

After deployment, verify on Basescan:

```bash
npx hardhat verify --network base <CONTRACT_ADDRESS> "<OWNER>" "<USDT_ADDRESS>" "<LP_WALLET>"
```

### 7. Add Liquidity (Optional)

Create a CYRUS/USDT pool on Uniswap V3:

```bash
# Set deployed token address
export CYRUS_TOKEN=0xDeployedAddress

# Run liquidity script
npx hardhat run scripts/addLiquidity.js --network base
```

This creates a Uniswap V3 pool at $0.01 initial price with:
- 100M CYRUS from LP wallet
- Equivalent USDT for balanced liquidity
- 1% fee tier
- Price range: $0.001 - $1.00

## USDT Addresses on Base

| Token | Address | Decimals |
|-------|---------|----------|
| USDbC (Bridged) | `0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA` | 6 |
| USDC (Native) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | 6 |

## Security

- OpenZeppelin contracts v5.5.0
- ERC20Bridgeable for Superchain compatibility
- Pausable by owner for emergencies
- Burnable by token holders
- ReentrancyGuard for sale protection
- SafeERC20 for USDT transfers

## Owner Functions

```solidity
// Pause/unpause all transfers
function pause() public onlyOwner
function unpause() public onlyOwner

// Send raised USDT to LP wallet
function fundLP() external onlyOwner

// Update LP wallet
function setLPWallet(address _lpWallet) external onlyOwner

// Control sale
function endSale() external onlyOwner
function resumeSale() external onlyOwner
```

## Links

- Website: https://cyrus.cash
- Twitter: @CyrusToken
- GitHub: https://github.com/luxdao/cyrus

## Disclaimer

This is a community token. Not financial advice. Not an investment. This token has no intrinsic value and makes no promises of returns. It exists to honor the legacy of Cyrus the Great and the principles of human rights.

---

*"I am Cyrus, king of the world..."* - The Cyrus Cylinder
