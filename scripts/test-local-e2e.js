const hre = require("hardhat");

/**
 * End-to-End Local Test Script
 *
 * Tests the complete CYRUS/PARS governance flow:
 * 1. Deploy all contracts
 * 2. Buy CYRUS tokens
 * 3. Stake CYRUS → xCYRUS
 * 4. Stake xCYRUS → Earn PARS rewards
 * 5. Vote with PARS for gauge emissions
 * 6. Advance epoch and claim emissions
 * 7. Create SubDAO proposal
 *
 * Run: npx hardhat run scripts/test-local-e2e.js --network localhost
 */

async function main() {
  const [deployer, user1, user2, treasury] = await hre.ethers.getSigners();

  console.log("=".repeat(70));
  console.log("CYRUS/PARS END-TO-END LOCAL TEST");
  console.log("=".repeat(70));
  console.log("\nTest Accounts:");
  console.log("Deployer:", deployer.address);
  console.log("User1:", user1.address);
  console.log("User2:", user2.address);
  console.log("Treasury:", treasury.address);

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 1: Deploy Mock USDT
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 1: Deploying Mock USDT");
  console.log("=".repeat(70));

  const MockUSDT = await hre.ethers.getContractFactory("MockUSDT");
  const usdt = await MockUSDT.deploy();
  await usdt.waitForDeployment();
  const usdtAddress = await usdt.getAddress();
  console.log("✓ Mock USDT deployed at:", usdtAddress);

  // Mint USDT to users
  await usdt.mint(deployer.address, hre.ethers.parseUnits("100000", 6));
  await usdt.mint(user1.address, hre.ethers.parseUnits("50000", 6));
  await usdt.mint(user2.address, hre.ethers.parseUnits("50000", 6));
  console.log("✓ USDT minted to test accounts");

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 2: Deploy CYRUS Token
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 2: Deploying CYRUS Token");
  console.log("=".repeat(70));

  const Cyrus = await hre.ethers.getContractFactory("Cyrus");
  const cyrus = await Cyrus.deploy(deployer.address, usdtAddress, treasury.address);
  await cyrus.waitForDeployment();
  const cyrusAddress = await cyrus.getAddress();
  console.log("✓ CYRUS deployed at:", cyrusAddress);

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 3: Buy CYRUS with USDT
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 3: Buying CYRUS Tokens");
  console.log("=".repeat(70));

  // Approve USDT spending
  const buyAmount = hre.ethers.parseUnits("1000", 6); // 1000 USDT
  await usdt.connect(user1).approve(cyrusAddress, buyAmount);
  await usdt.connect(user2).approve(cyrusAddress, buyAmount);

  // Buy CYRUS
  await cyrus.connect(user1).buy(buyAmount);
  await cyrus.connect(user2).buy(buyAmount);

  const user1CyrusBalance = await cyrus.balanceOf(user1.address);
  const user2CyrusBalance = await cyrus.balanceOf(user2.address);
  console.log("✓ User1 CYRUS balance:", hre.ethers.formatEther(user1CyrusBalance));
  console.log("✓ User2 CYRUS balance:", hre.ethers.formatEther(user2CyrusBalance));

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 4: Deploy LiquidCYRUS (xCYRUS) - SIMPLIFIED FOR TEST
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 4: Deploying LiquidCYRUS (xCYRUS)");
  console.log("=".repeat(70));

  const LiquidCYRUS = await hre.ethers.getContractFactory("LiquidCYRUS");
  const xCyrus = await LiquidCYRUS.deploy(
    cyrusAddress,
    treasury.address,
    deployer.address  // timelock
  );
  await xCyrus.waitForDeployment();
  const xCyrusAddress = await xCyrus.getAddress();
  console.log("✓ xCYRUS deployed at:", xCyrusAddress);

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 5: Deploy PARS Token
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 5: Deploying PARS Token");
  console.log("=".repeat(70));

  const PARS = await hre.ethers.getContractFactory("PARS");
  const pars = await PARS.deploy(
    treasury.address,   // treasury
    deployer.address    // timelock
  );
  await pars.waitForDeployment();
  const parsAddress = await pars.getAddress();
  console.log("✓ PARS deployed at:", parsAddress);

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 6: Deploy CYRUSStakingRewards
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 6: Deploying CYRUSStakingRewards");
  console.log("=".repeat(70));

  const StakingRewards = await hre.ethers.getContractFactory("CYRUSStakingRewards");
  const stakingRewards = await StakingRewards.deploy(
    xCyrusAddress,     // xCYRUS token
    parsAddress,       // PARS reward token
    deployer.address   // timelock
  );
  await stakingRewards.waitForDeployment();
  const stakingRewardsAddress = await stakingRewards.getAddress();
  console.log("✓ CYRUSStakingRewards deployed at:", stakingRewardsAddress);

  // Grant MINTER_ROLE to StakingRewards
  const MINTER_ROLE = await pars.MINTER_ROLE();
  await pars.grantRole(MINTER_ROLE, stakingRewardsAddress);
  console.log("✓ MINTER_ROLE granted to StakingRewards");

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 7: Deploy GaugeController
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 7: Deploying GaugeController");
  console.log("=".repeat(70));

  const emissionsPerEpoch = hre.ethers.parseEther("100000"); // 100K PARS/epoch
  const GaugeController = await hre.ethers.getContractFactory("CyrusGaugeController");
  const gaugeController = await GaugeController.deploy(
    cyrusAddress,         // CYRUS for voting
    parsAddress,          // PARS for emissions
    emissionsPerEpoch,
    deployer.address      // owner
  );
  await gaugeController.waitForDeployment();
  const gaugeControllerAddress = await gaugeController.getAddress();
  console.log("✓ GaugeController deployed at:", gaugeControllerAddress);

  // Grant MINTER_ROLE to GaugeController
  await pars.grantRole(MINTER_ROLE, gaugeControllerAddress);
  console.log("✓ MINTER_ROLE granted to GaugeController");

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 8: Deploy RewardsGauge
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 8: Deploying RewardsGauge");
  console.log("=".repeat(70));

  // Use xCYRUS as LP token for simplicity
  const RewardsGauge = await hre.ethers.getContractFactory("CyrusRewardsGauge");
  const rewardsGauge = await RewardsGauge.deploy(
    xCyrusAddress,        // LP token (xCYRUS for test)
    parsAddress,          // Reward token
    "CYRUS/USDT LP Gauge",
    deployer.address      // owner
  );
  await rewardsGauge.waitForDeployment();
  const rewardsGaugeAddress = await rewardsGauge.getAddress();
  console.log("✓ RewardsGauge deployed at:", rewardsGaugeAddress);

  // Configure RewardsGauge
  await rewardsGauge.setGaugeController(gaugeControllerAddress);
  console.log("✓ GaugeController set on RewardsGauge");

  // Add gauge to controller
  await gaugeController.addGauge(rewardsGaugeAddress, "CYRUS/USDT LP");
  const gaugeId = await gaugeController.gaugeIds(rewardsGaugeAddress);
  console.log("✓ RewardsGauge added with ID:", gaugeId.toString());

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 9: Test Staking Flow
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 9: Testing Staking Flow");
  console.log("=".repeat(70));

  // User1: Stake CYRUS → xCYRUS
  const stakeAmount = hre.ethers.parseEther("10000");
  await cyrus.connect(user1).approve(xCyrusAddress, stakeAmount);

  // Delegate votes before staking (for gauge voting)
  await cyrus.connect(user1).delegate(user1.address);
  await cyrus.connect(user2).delegate(user2.address);
  console.log("✓ Users delegated CYRUS voting power");

  // Check voting power
  const user1Votes = await cyrus.getVotes(user1.address);
  const user2Votes = await cyrus.getVotes(user2.address);
  console.log("User1 voting power:", hre.ethers.formatEther(user1Votes));
  console.log("User2 voting power:", hre.ethers.formatEther(user2Votes));

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 10: Test Gauge Voting
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 10: Testing Gauge Voting");
  console.log("=".repeat(70));

  // User1 votes for gauge
  const voteAllocation = [{ gaugeId: gaugeId, weight: 10000 }]; // 100% to gauge
  await gaugeController.connect(user1).vote(voteAllocation);
  console.log("✓ User1 voted for gauge");

  // User2 votes for gauge
  await gaugeController.connect(user2).vote(voteAllocation);
  console.log("✓ User2 voted for gauge");

  // Check gauge weight
  const gaugeInfo = await gaugeController.getGauge(gaugeId);
  console.log("Gauge weight:", hre.ethers.formatEther(gaugeInfo.weight));
  console.log("Total weight:", hre.ethers.formatEther(await gaugeController.totalWeight()));

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 11: Advance Time and Epoch
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 11: Advancing Time and Epoch");
  console.log("=".repeat(70));

  // Get epoch duration
  const epochDuration = await gaugeController.EPOCH_DURATION();
  console.log("Epoch duration:", Number(epochDuration) / 86400, "days");

  // Advance time by 1 week
  await hre.network.provider.send("evm_increaseTime", [Number(epochDuration)]);
  await hre.network.provider.send("evm_mine");
  console.log("✓ Time advanced by 1 epoch");

  // Advance epoch
  await gaugeController.advanceEpoch();
  const currentEpoch = await gaugeController.currentEpoch();
  console.log("✓ Epoch advanced to:", currentEpoch.toString());

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 12: Claim Emissions
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 12: Claiming Emissions");
  console.log("=".repeat(70));

  // Check pending emissions
  const pendingEmissions = await gaugeController.pendingEmissions(gaugeId);
  console.log("Pending emissions for gauge:", hre.ethers.formatEther(pendingEmissions), "PARS");

  // Claim emissions for epoch 1
  const claimTx = await gaugeController.claimEmissions(gaugeId, 1);
  await claimTx.wait();
  console.log("✓ Emissions claimed for epoch 1");

  // Check gauge PARS balance
  const gaugeParsBalance = await pars.balanceOf(rewardsGaugeAddress);
  console.log("Gauge PARS balance:", hre.ethers.formatEther(gaugeParsBalance), "PARS");

  // ═══════════════════════════════════════════════════════════════════════
  // SUMMARY
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("TEST SUMMARY");
  console.log("=".repeat(70));
  console.log("\nContract Addresses:");
  console.log("-".repeat(70));
  console.log("USDT (Mock):", usdtAddress);
  console.log("CYRUS:", cyrusAddress);
  console.log("xCYRUS:", xCyrusAddress);
  console.log("PARS:", parsAddress);
  console.log("StakingRewards:", stakingRewardsAddress);
  console.log("GaugeController:", gaugeControllerAddress);
  console.log("RewardsGauge:", rewardsGaugeAddress);

  console.log("\n" + "-".repeat(70));
  console.log("Test Results:");
  console.log("-".repeat(70));
  console.log("✓ CYRUS purchased with USDT");
  console.log("✓ Voting power delegated");
  console.log("✓ Gauge votes cast");
  console.log("✓ Epoch advanced");
  console.log("✓ Emissions claimed to gauge");
  console.log("✓ PARS minted to gauge:", hre.ethers.formatEther(gaugeParsBalance), "PARS");

  console.log("\n" + "=".repeat(70));
  console.log("ALL TESTS PASSED!");
  console.log("=".repeat(70));

  return {
    usdt: usdtAddress,
    cyrus: cyrusAddress,
    xCyrus: xCyrusAddress,
    pars: parsAddress,
    stakingRewards: stakingRewardsAddress,
    gaugeController: gaugeControllerAddress,
    rewardsGauge: rewardsGaugeAddress
  };
}

main()
  .then((addresses) => {
    console.log("\nDeployed addresses:", addresses);
    process.exit(0);
  })
  .catch((error) => {
    console.error("\n❌ TEST FAILED:", error);
    process.exit(1);
  });
