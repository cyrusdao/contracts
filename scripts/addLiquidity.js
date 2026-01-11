const hre = require("hardhat");

// Uniswap V3 addresses on Base
const UNISWAP_V3_FACTORY = "0x33128a8fC17869897dcE68Ed026d694621f6FDfD";
const UNISWAP_V3_NPM = "0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1"; // NonfungiblePositionManager

// USDbC on Base (Bridged USDC - 6 decimals)
const USDC_BASE = "0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA";

// Pool parameters
const FEE_TIER = 10000; // 1% fee tier (good for volatile/new tokens)
const TICK_SPACING = 200; // Tick spacing for 1% fee tier

// ABIs
const ERC20_ABI = [
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function balanceOf(address account) external view returns (uint256)",
  "function allowance(address owner, address spender) external view returns (uint256)",
  "function decimals() external view returns (uint8)",
  "function symbol() external view returns (string)"
];

const NPM_ABI = [
  "function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96) external payable returns (address pool)",
  "function mint((address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min, address recipient, uint256 deadline)) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)"
];

const FACTORY_ABI = [
  "function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool)"
];

/**
 * Convert a price to sqrtPriceX96 format for Uniswap V3
 * sqrtPriceX96 = sqrt(price) * 2^96
 */
function priceToSqrtPriceX96(price) {
  const sqrtPrice = Math.sqrt(price);
  const Q96 = BigInt(2) ** BigInt(96);
  return BigInt(Math.floor(sqrtPrice * Number(Q96)));
}

/**
 * Convert a price to tick
 * tick = floor(log_1.0001(price))
 */
function priceToTick(price) {
  return Math.floor(Math.log(price) / Math.log(1.0001));
}

/**
 * Round tick to nearest usable tick based on tick spacing
 */
function nearestUsableTick(tick, tickSpacing) {
  return Math.round(tick / tickSpacing) * tickSpacing;
}

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const provider = deployer.provider;

  // Configuration from environment
  const cyrusTokenAddress = process.env.CYRUS_TOKEN;
  const usdtAddress = process.env.USDT_ADDRESS || USDC_BASE;

  if (!cyrusTokenAddress) {
    throw new Error("CYRUS_TOKEN environment variable required. Set to deployed token address.");
  }

  console.log("=".repeat(60));
  console.log("CYRUS/USDT Uniswap V3 Liquidity Pool Setup");
  console.log("=".repeat(60));
  console.log("\nAccount:", deployer.address);
  console.log("CYRUS Token:", cyrusTokenAddress);
  console.log("USDT/USDC:", usdtAddress);

  // Get token contracts
  const cyrusContract = new hre.ethers.Contract(cyrusTokenAddress, ERC20_ABI, deployer);
  const usdtContract = new hre.ethers.Contract(usdtAddress, ERC20_ABI, deployer);

  // Get balances
  const ethBalance = await provider.getBalance(deployer.address);
  const cyrusBalance = await cyrusContract.balanceOf(deployer.address);
  const usdtBalance = await usdtContract.balanceOf(deployer.address);
  const cyrusSymbol = await cyrusContract.symbol();
  const usdtSymbol = await usdtContract.symbol();

  console.log("\n" + "-".repeat(60));
  console.log("Balances:");
  console.log("-".repeat(60));
  console.log("ETH:", hre.ethers.formatEther(ethBalance));
  console.log(cyrusSymbol + ":", hre.ethers.formatUnits(cyrusBalance, 18));
  console.log(usdtSymbol + ":", hre.ethers.formatUnits(usdtBalance, 6));

  // Determine token ordering (Uniswap requires token0 < token1 by address)
  const cyrusAddr = cyrusTokenAddress.toLowerCase();
  const usdtAddr = usdtAddress.toLowerCase();
  const cyrusIsToken0 = cyrusAddr < usdtAddr;

  const token0 = cyrusIsToken0 ? cyrusTokenAddress : usdtAddress;
  const token1 = cyrusIsToken0 ? usdtAddress : cyrusTokenAddress;

  console.log("\n" + "-".repeat(60));
  console.log("Token Ordering (Uniswap V3):");
  console.log("-".repeat(60));
  console.log("token0:", token0, cyrusIsToken0 ? "(CYRUS)" : "(USDT)");
  console.log("token1:", token1, cyrusIsToken0 ? "(USDT)" : "(CYRUS)");

  // Connect to Uniswap contracts
  const npm = new hre.ethers.Contract(UNISWAP_V3_NPM, NPM_ABI, deployer);
  const factory = new hre.ethers.Contract(UNISWAP_V3_FACTORY, FACTORY_ABI, provider);

  // Price configuration
  // Starting price: $0.01 per CYRUS (1 CYRUS = 0.01 USDT)
  // We want a wide range for the LP position
  const priceStart = 0.01;     // $0.01 per CYRUS
  const priceLower = 0.001;    // $0.001 per CYRUS (10x below start)
  const priceUpper = 1.0;      // $1.00 per CYRUS (100x above start)

  console.log("\n" + "-".repeat(60));
  console.log("Price Configuration:");
  console.log("-".repeat(60));
  console.log("Initial Price: $" + priceStart + " per CYRUS");
  console.log("Price Range: $" + priceLower + " - $" + priceUpper + " per CYRUS");

  // In Uniswap V3, price = token1/token0
  // If CYRUS is token0 and USDT is token1:
  //   price = USDT/CYRUS (how much USDT for 1 CYRUS)
  //   At $0.01 per CYRUS: price = 0.01
  // If USDT is token0 and CYRUS is token1:
  //   price = CYRUS/USDT (how much CYRUS for 1 USDT)
  //   At $0.01 per CYRUS: price = 100 (100 CYRUS per USDT)

  // Adjust for decimal difference: CYRUS has 18 decimals, USDT has 6
  // Raw price ratio accounts for this: price = (token1_amount * 10^token0_decimals) / (token0_amount * 10^token1_decimals)
  const decimalAdjustment = 1e12; // 10^(18-6) = 10^12

  let rawPriceStart, rawPriceLower, rawPriceUpper;

  if (cyrusIsToken0) {
    // price = USDT/CYRUS in raw terms = 0.01 * 10^(-12) due to decimal diff
    rawPriceStart = priceStart / decimalAdjustment;
    rawPriceLower = priceLower / decimalAdjustment;
    rawPriceUpper = priceUpper / decimalAdjustment;
  } else {
    // price = CYRUS/USDT in raw terms = (1/0.01) * 10^12 = 100 * 10^12
    rawPriceStart = (1 / priceStart) * decimalAdjustment;
    rawPriceLower = (1 / priceUpper) * decimalAdjustment; // Lower price = more CYRUS per USDT
    rawPriceUpper = (1 / priceLower) * decimalAdjustment; // Upper price = less CYRUS per USDT
  }

  const sqrtPriceX96Start = priceToSqrtPriceX96(rawPriceStart);
  let tickLower = nearestUsableTick(priceToTick(rawPriceLower), TICK_SPACING);
  let tickUpper = nearestUsableTick(priceToTick(rawPriceUpper), TICK_SPACING);

  // Ensure tickLower < tickUpper
  if (tickLower >= tickUpper) {
    [tickLower, tickUpper] = [tickUpper, tickLower];
  }

  console.log("\nUniswap V3 Parameters:");
  console.log("sqrtPriceX96:", sqrtPriceX96Start.toString());
  console.log("tickLower:", tickLower);
  console.log("tickUpper:", tickUpper);

  // Check if pool exists
  const existingPool = await factory.getPool(token0, token1, FEE_TIER);
  console.log("\nExisting pool:", existingPool);

  // Liquidity amounts
  // 100M CYRUS at $0.01 = $1M worth
  // Need equivalent USDT for balanced position
  const cyrusAmount = hre.ethers.parseUnits("100000000", 18); // 100M CYRUS
  const usdtAmount = hre.ethers.parseUnits("1000000", 6);     // $1M USDT (for balanced LP)

  // Check if we have enough tokens
  if (cyrusBalance < cyrusAmount) {
    throw new Error(`Insufficient CYRUS. Have: ${hre.ethers.formatUnits(cyrusBalance, 18)}, Need: 100000000`);
  }
  if (usdtBalance < usdtAmount) {
    console.log("\nWARNING: Insufficient USDT for balanced position.");
    console.log("Have:", hre.ethers.formatUnits(usdtBalance, 6), "USDT");
    console.log("Recommended: 1,000,000 USDT for balanced LP");
    console.log("\nProceeding with single-sided CYRUS liquidity...");
  }

  // Set amounts based on token ordering
  let amount0Desired, amount1Desired;
  if (cyrusIsToken0) {
    amount0Desired = cyrusAmount;
    amount1Desired = usdtBalance < usdtAmount ? usdtBalance : usdtAmount;
  } else {
    amount0Desired = usdtBalance < usdtAmount ? usdtBalance : usdtAmount;
    amount1Desired = cyrusAmount;
  }

  console.log("\n" + "-".repeat(60));
  console.log("Liquidity Amounts:");
  console.log("-".repeat(60));
  console.log("CYRUS:", hre.ethers.formatUnits(cyrusIsToken0 ? amount0Desired : amount1Desired, 18));
  console.log("USDT:", hre.ethers.formatUnits(cyrusIsToken0 ? amount1Desired : amount0Desired, 6));

  // Approve tokens
  console.log("\n" + "-".repeat(60));
  console.log("Token Approvals:");
  console.log("-".repeat(60));

  // Check and approve CYRUS
  const cyrusAllowance = await cyrusContract.allowance(deployer.address, UNISWAP_V3_NPM);
  if (cyrusAllowance < cyrusAmount) {
    console.log("Approving CYRUS...");
    const approveTx = await cyrusContract.approve(UNISWAP_V3_NPM, cyrusAmount);
    await approveTx.wait();
    console.log("CYRUS approved:", approveTx.hash);
  } else {
    console.log("CYRUS already approved");
  }

  // Check and approve USDT if we have any
  const usdtAmountToApprove = cyrusIsToken0 ? amount1Desired : amount0Desired;
  if (usdtAmountToApprove > 0n) {
    const usdtAllowance = await usdtContract.allowance(deployer.address, UNISWAP_V3_NPM);
    if (usdtAllowance < usdtAmountToApprove) {
      console.log("Approving USDT...");
      const approveTx = await usdtContract.approve(UNISWAP_V3_NPM, usdtAmountToApprove);
      await approveTx.wait();
      console.log("USDT approved:", approveTx.hash);
    } else {
      console.log("USDT already approved");
    }
  }

  // Create pool if needed
  let poolAddress = await factory.getPool(token0, token1, FEE_TIER);

  if (poolAddress === "0x0000000000000000000000000000000000000000") {
    console.log("\n" + "-".repeat(60));
    console.log("Creating Pool:");
    console.log("-".repeat(60));
    console.log("Initializing pool at $" + priceStart + " per CYRUS...");

    const createPoolTx = await npm.createAndInitializePoolIfNecessary(
      token0,
      token1,
      FEE_TIER,
      sqrtPriceX96Start,
      { gasLimit: 5000000 }
    );
    const createPoolReceipt = await createPoolTx.wait();
    console.log("Pool creation tx:", createPoolTx.hash);
    console.log("Gas used:", createPoolReceipt.gasUsed.toString());

    poolAddress = await factory.getPool(token0, token1, FEE_TIER);
  } else {
    console.log("\nPool already exists at:", poolAddress);
  }

  console.log("Pool address:", poolAddress);

  // Mint liquidity position
  console.log("\n" + "-".repeat(60));
  console.log("Minting Liquidity Position:");
  console.log("-".repeat(60));

  const deadline = Math.floor(Date.now() / 1000) + 60 * 20; // 20 minutes

  const mintParams = {
    token0: token0,
    token1: token1,
    fee: FEE_TIER,
    tickLower: tickLower,
    tickUpper: tickUpper,
    amount0Desired: amount0Desired,
    amount1Desired: amount1Desired,
    amount0Min: 0n, // Accept any amount (slippage protection disabled for initial LP)
    amount1Min: 0n,
    recipient: deployer.address,
    deadline: deadline
  };

  console.log("Minting position...");

  const mintTx = await npm.mint(mintParams, { gasLimit: 1000000 });
  const mintReceipt = await mintTx.wait();

  console.log("Mint tx:", mintTx.hash);
  console.log("Gas used:", mintReceipt.gasUsed.toString());

  // Summary
  console.log("\n" + "=".repeat(60));
  console.log("LIQUIDITY POOL CREATED SUCCESSFULLY");
  console.log("=".repeat(60));
  console.log("\nPool Address:", poolAddress);
  console.log("CYRUS Token:", cyrusTokenAddress);
  console.log("USDT Token:", usdtAddress);
  console.log("Initial Price: $0.01 per CYRUS");
  console.log("Fee Tier: 1%");

  console.log("\n" + "-".repeat(60));
  console.log("Links:");
  console.log("-".repeat(60));
  console.log("Uniswap Pool: https://app.uniswap.org/pools");
  console.log("Pool on Basescan: https://basescan.org/address/" + poolAddress);
  console.log("CYRUS on Basescan: https://basescan.org/token/" + cyrusTokenAddress);
  console.log("\n" + "=".repeat(60));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
