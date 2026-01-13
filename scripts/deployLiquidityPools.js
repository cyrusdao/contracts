const hre = require("hardhat");
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

/**
 * Deploy Liquidity Pools with ETH
 *
 * Creates:
 * - WETH contract
 * - MockFactory (Uniswap V2 style)
 * - MockRouter
 * - CYRUS/WETH pool with $5 ETH liquidity
 * - PARS/WETH pool with $5 ETH liquidity
 *
 * Assumes ETH price of ~$3000 for calculations
 * $5 ≈ 0.00167 ETH
 */

async function main() {
  const network = hre.network.name;
  console.log(`\n💧 Deploying Liquidity Pools to ${network}...\n`);

  // Load existing deployment
  const deploymentsPath = path.join(__dirname, `../deployments/${network}.json`);
  let deployment = {};
  if (fs.existsSync(deploymentsPath)) {
    deployment = JSON.parse(fs.readFileSync(deploymentsPath, "utf8"));
    console.log("📄 Loaded existing deployment");
  }

  const [deployer] = await ethers.getSigners();
  console.log(`📝 Deployer: ${deployer.address}`);
  console.log(`   Balance: ${ethers.utils.formatEther(await deployer.getBalance())} ETH\n`);

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 1: Deploy WETH
  // ═══════════════════════════════════════════════════════════════════════

  console.log("🔷 Deploying MockWETH...");
  const MockWETH = await ethers.getContractFactory("MockWETH");
  const weth = await MockWETH.deploy();
  await weth.deployed();
  console.log(`   WETH deployed: ${weth.address}`);

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 2: Deploy AMM Factory & Router
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n🏭 Deploying AMM Factory...");
  const MockFactory = await ethers.getContractFactory("MockFactory");
  const factory = await MockFactory.deploy();
  await factory.deployed();
  console.log(`   Factory deployed: ${factory.address}`);

  console.log("\n🛣️  Deploying AMM Router...");
  const MockRouter = await ethers.getContractFactory("MockRouter");
  const router = await MockRouter.deploy(factory.address);
  await router.deployed();
  console.log(`   Router deployed: ${router.address}`);

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 3: Calculate liquidity amounts
  // ═══════════════════════════════════════════════════════════════════════

  // Assuming ETH ≈ $3000
  // $5 ≈ 0.00167 ETH
  const ETH_PRICE = 3000;
  const USD_AMOUNT = 5;
  const ETH_AMOUNT = ethers.utils.parseEther((USD_AMOUNT / ETH_PRICE).toFixed(18));

  console.log(`\n💰 Liquidity Parameters:`);
  console.log(`   ETH price (assumed): $${ETH_PRICE}`);
  console.log(`   USD per pool: $${USD_AMOUNT}`);
  console.log(`   ETH per pool: ${ethers.utils.formatEther(ETH_AMOUNT)} ETH`);

  // Token prices (initial)
  // CYRUS: $0.01 (from bonding curve start)
  // PARS: $0.10 (initial emissions price)
  const CYRUS_PRICE = 0.01;
  const PARS_PRICE = 0.10;

  // Calculate token amounts for $5 worth
  const cyrusAmount = ethers.utils.parseEther((USD_AMOUNT / CYRUS_PRICE).toString());
  const parsAmount = ethers.utils.parseEther((USD_AMOUNT / PARS_PRICE).toString());

  console.log(`   CYRUS price: $${CYRUS_PRICE}`);
  console.log(`   CYRUS amount: ${ethers.utils.formatEther(cyrusAmount)} CYRUS`);
  console.log(`   PARS price: $${PARS_PRICE}`);
  console.log(`   PARS amount: ${ethers.utils.formatEther(parsAmount)} PARS`);

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 4: Wrap ETH
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n🔄 Wrapping ETH...");
  const totalEthNeeded = ETH_AMOUNT.mul(2); // For both pools
  await weth.deposit({ value: totalEthNeeded });
  console.log(`   Wrapped ${ethers.utils.formatEther(totalEthNeeded)} ETH`);

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 5: Get token contracts
  // ═══════════════════════════════════════════════════════════════════════

  if (!deployment.cyrus || !deployment.pars) {
    throw new Error("CYRUS and PARS must be deployed first. Run deployGovernance.js");
  }

  const cyrus = await ethers.getContractAt("CYRUS", deployment.cyrus);
  const pars = await ethers.getContractAt("PARS", deployment.pars);

  // Check balances
  const cyrusBalance = await cyrus.balanceOf(deployer.address);
  const parsBalance = await pars.balanceOf(deployer.address);

  console.log(`\n📊 Token Balances:`);
  console.log(`   CYRUS: ${ethers.utils.formatEther(cyrusBalance)}`);
  console.log(`   PARS: ${ethers.utils.formatEther(parsBalance)}`);

  // Mint PARS if needed (deployer should have MINTER_ROLE)
  if (parsBalance.lt(parsAmount)) {
    console.log(`\n🪙 Minting PARS for liquidity...`);
    const MINTER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("MINTER_ROLE"));
    const hasMinterRole = await pars.hasRole(MINTER_ROLE, deployer.address);
    if (hasMinterRole) {
      await pars.mint(deployer.address, parsAmount);
      console.log(`   Minted ${ethers.utils.formatEther(parsAmount)} PARS`);
    } else {
      console.log(`   ⚠️  Deployer doesn't have MINTER_ROLE. Skipping PARS mint.`);
    }
  }

  // For CYRUS, we need to use LP wallet or buy from curve
  // For now, let's assume lpWallet has tokens from deployment

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 6: Create and add liquidity to CYRUS/WETH pool
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n🏊 Creating CYRUS/WETH pool...");

  // Approve router
  await cyrus.approve(router.address, cyrusAmount);
  await weth.approve(router.address, ETH_AMOUNT);

  // Check if we have enough CYRUS (might need to use lpWallet tokens)
  const cyrusBalanceNow = await cyrus.balanceOf(deployer.address);
  if (cyrusBalanceNow.gte(cyrusAmount)) {
    try {
      const tx1 = await router.addLiquidity(
        cyrus.address,
        weth.address,
        cyrusAmount,
        ETH_AMOUNT,
        0, // min amounts (for testing)
        0,
        deployer.address,
        Math.floor(Date.now() / 1000) + 3600
      );
      await tx1.wait();

      const cyrusWethPair = await factory.getPair(cyrus.address, weth.address);
      console.log(`   CYRUS/WETH pair: ${cyrusWethPair}`);

      const pairContract = await ethers.getContractAt("MockPair", cyrusWethPair);
      const lpBalance = await pairContract.balanceOf(deployer.address);
      console.log(`   LP tokens received: ${ethers.utils.formatEther(lpBalance)}`);
    } catch (e) {
      console.log(`   ⚠️  Failed to add CYRUS liquidity: ${e.message}`);
      console.log(`   This may be due to transfer restrictions before Nowruz 2026`);
    }
  } else {
    console.log(`   ⚠️  Not enough CYRUS. Have: ${ethers.utils.formatEther(cyrusBalanceNow)}, Need: ${ethers.utils.formatEther(cyrusAmount)}`);
    console.log(`   CYRUS transfers may be restricted until Nowruz 2026`);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 7: Create and add liquidity to PARS/WETH pool
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n🏊 Creating PARS/WETH pool...");

  const parsBalanceNow = await pars.balanceOf(deployer.address);
  if (parsBalanceNow.gte(parsAmount)) {
    await pars.approve(router.address, parsAmount);
    await weth.approve(router.address, ETH_AMOUNT);

    const tx2 = await router.addLiquidity(
      pars.address,
      weth.address,
      parsAmount,
      ETH_AMOUNT,
      0,
      0,
      deployer.address,
      Math.floor(Date.now() / 1000) + 3600
    );
    await tx2.wait();

    const parsWethPair = await factory.getPair(pars.address, weth.address);
    console.log(`   PARS/WETH pair: ${parsWethPair}`);

    const pairContract = await ethers.getContractAt("MockPair", parsWethPair);
    const lpBalance = await pairContract.balanceOf(deployer.address);
    console.log(`   LP tokens received: ${ethers.utils.formatEther(lpBalance)}`);
  } else {
    console.log(`   ⚠️  Not enough PARS. Have: ${ethers.utils.formatEther(parsBalanceNow)}, Need: ${ethers.utils.formatEther(parsAmount)}`);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 8: Save deployment
  // ═══════════════════════════════════════════════════════════════════════

  const cyrusWethPair = await factory.getPair(cyrus.address, weth.address);
  const parsWethPair = await factory.getPair(pars.address, weth.address);

  deployment = {
    ...deployment,
    weth: weth.address,
    ammFactory: factory.address,
    ammRouter: router.address,
    pools: {
      cyrusWeth: cyrusWethPair !== ethers.constants.AddressZero ? cyrusWethPair : null,
      parsWeth: parsWethPair !== ethers.constants.AddressZero ? parsWethPair : null,
    },
    liquidityParams: {
      ethPriceUsd: ETH_PRICE,
      usdPerPool: USD_AMOUNT,
      cyrusPriceUsd: CYRUS_PRICE,
      parsPriceUsd: PARS_PRICE,
    },
    updatedAt: new Date().toISOString(),
  };

  fs.writeFileSync(deploymentsPath, JSON.stringify(deployment, null, 2));
  console.log(`\n💾 Deployment saved to ${deploymentsPath}`);

  // ═══════════════════════════════════════════════════════════════════════
  // SUMMARY
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "═".repeat(60));
  console.log("💧 LIQUIDITY POOLS DEPLOYMENT COMPLETE");
  console.log("═".repeat(60));
  console.log("\n📋 Deployed Contracts:");
  console.log(`   WETH:        ${weth.address}`);
  console.log(`   Factory:     ${factory.address}`);
  console.log(`   Router:      ${router.address}`);
  console.log("\n🏊 Liquidity Pools:");
  console.log(`   CYRUS/WETH:  ${cyrusWethPair || "Not created (transfer restriction)"}`);
  console.log(`   PARS/WETH:   ${parsWethPair || "Not created"}`);
  console.log("\n💰 Initial Liquidity:");
  console.log(`   $${USD_AMOUNT} worth of ETH per pool`);
  console.log(`   ${ethers.utils.formatEther(ETH_AMOUNT)} ETH per pool`);
  console.log("═".repeat(60) + "\n");

  return deployment;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
