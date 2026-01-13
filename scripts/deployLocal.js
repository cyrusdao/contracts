const hre = require("hardhat");

/**
 * Local Development Deployment Script for Cyrus Governance Stack
 *
 * Deploys the complete Cyrus ecosystem to a local Hardhat node:
 * 1. MockUSDT - Test stablecoin for bonding curve
 * 2. CYRUS - Main governance token with ERC20Votes
 * 3. CyrusDAO - Governance contract
 * 4. PARS - Emissions/reward token
 * 5. sPARS - Staked PARS (rebasing)
 * 6. CyrusGaugeController - Epoch-based emission distribution
 * 7. CyrusRewardsGauge - LP staking rewards (with mock LP token)
 *
 * Run with: npx hardhat run scripts/deployLocal.js --network localhost
 */

async function main() {
  const [deployer, user1, user2, user3, user4] = await hre.ethers.getSigners();
  const network = hre.network.name;

  console.log("=".repeat(70));
  console.log("CYRUS ECOSYSTEM LOCAL DEPLOYMENT");
  console.log("=".repeat(70));
  console.log("\nNetwork:", network);
  console.log("Deployer:", deployer.address);
  console.log("Balance:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)), "ETH");

  const deployedContracts = {};

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 1: Deploy MockUSDT
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 1: Deploying MockUSDT");
  console.log("=".repeat(70));

  const MockERC20 = await hre.ethers.getContractFactory("MockERC20");
  const mockUSDT = await MockERC20.deploy("Mock USDT", "USDT", 6);
  await mockUSDT.waitForDeployment();
  deployedContracts.mockUSDT = await mockUSDT.getAddress();
  console.log("✓ MockUSDT deployed at:", deployedContracts.mockUSDT);

  // Mint USDT to deployer and test users
  const usdtAmount = hre.ethers.parseUnits("1000000", 6); // 1M USDT each
  await mockUSDT.mint(deployer.address, usdtAmount);
  await mockUSDT.mint(user1.address, usdtAmount);
  await mockUSDT.mint(user2.address, usdtAmount);
  console.log("✓ Minted 1M USDT to deployer and test users");

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 2: Deploy CYRUS Token
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 2: Deploying CYRUS Token");
  console.log("=".repeat(70));

  const Cyrus = await hre.ethers.getContractFactory("Cyrus");
  const cyrus = await Cyrus.deploy(
    deployer.address,         // initialOwner
    deployedContracts.mockUSDT, // USDT address
    deployer.address          // lpWallet (receives LP reserve - 100M CYRUS)
  );
  await cyrus.waitForDeployment();
  deployedContracts.cyrus = await cyrus.getAddress();
  console.log("✓ CYRUS deployed at:", deployedContracts.cyrus);

  // Deployer receives LP reserve (100M CYRUS) automatically
  const cyrusBalance = await cyrus.balanceOf(deployer.address);
  console.log("✓ Deployer received LP reserve:", hre.ethers.formatEther(cyrusBalance), "CYRUS");

  // Transfer some CYRUS to test users for governance testing
  const transferAmount = hre.ethers.parseEther("1000000"); // 1M CYRUS each
  await cyrus.transfer(user1.address, transferAmount);
  await cyrus.transfer(user2.address, transferAmount);
  console.log("✓ Transferred 1M CYRUS to test users");

  // Delegate votes to self for governance
  await cyrus.delegate(deployer.address);
  console.log("✓ Deployer delegated votes to self");

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 3: Deploy CyrusDAO
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 3: Deploying CyrusDAO");
  console.log("=".repeat(70));

  const CyrusDAO = await hre.ethers.getContractFactory("CyrusDAO");
  const boardMembers = [deployer.address, user1.address, user2.address]; // Initial board
  const cyrusDAO = await CyrusDAO.deploy(
    deployedContracts.cyrus,  // CYRUS token (implements IVotes)
    deployer.address,         // guardian (steward)
    deployer.address,         // treasury
    boardMembers              // initial board members
  );
  await cyrusDAO.waitForDeployment();
  deployedContracts.cyrusDAO = await cyrusDAO.getAddress();
  console.log("✓ CyrusDAO deployed at:", deployedContracts.cyrusDAO);

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 4: Deploy PARS Token
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 4: Deploying PARS Token");
  console.log("=".repeat(70));

  const PARS = await hre.ethers.getContractFactory("PARS");
  const pars = await PARS.deploy(
    deployer.address,  // initialOwner (governance)
    deployer.address   // initialMinter (will be updated to GaugeController)
  );
  await pars.waitForDeployment();
  deployedContracts.pars = await pars.getAddress();
  console.log("✓ PARS deployed at:", deployedContracts.pars);

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 5: Deploy sPARS (Staked PARS)
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 5: Deploying sPARS (Staked PARS)");
  console.log("=".repeat(70));

  const SPARS = await hre.ethers.getContractFactory("sPARS");
  const spars = await SPARS.deploy(
    deployedContracts.pars,  // PARS token
    deployer.address         // initialOwner (governance)
  );
  await spars.waitForDeployment();
  deployedContracts.spars = await spars.getAddress();
  console.log("✓ sPARS deployed at:", deployedContracts.spars);

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 6: Deploy CyrusGaugeController
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 6: Deploying CyrusGaugeController");
  console.log("=".repeat(70));

  const emissionsPerEpoch = hre.ethers.parseEther("1000000"); // 1M PARS per week

  const GaugeController = await hre.ethers.getContractFactory("CyrusGaugeController");
  const gaugeController = await GaugeController.deploy(
    deployedContracts.cyrus,      // CYRUS governance token for voting
    deployedContracts.pars,       // PARS emissions token
    emissionsPerEpoch,            // PARS per epoch
    deployer.address              // initialOwner (governance)
  );
  await gaugeController.waitForDeployment();
  deployedContracts.gaugeController = await gaugeController.getAddress();
  console.log("✓ CyrusGaugeController deployed at:", deployedContracts.gaugeController);

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 7: Deploy Mock LP Token and CyrusRewardsGauge
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 7: Deploying Mock LP Token and CyrusRewardsGauge");
  console.log("=".repeat(70));

  // Deploy mock LP token for testing
  const mockLP = await MockERC20.deploy("CYRUS-USDT LP", "CYRUS-USDT-LP", 18);
  await mockLP.waitForDeployment();
  deployedContracts.mockLP = await mockLP.getAddress();
  console.log("✓ Mock LP Token deployed at:", deployedContracts.mockLP);

  // Mint LP tokens to test users
  const lpAmount = hre.ethers.parseEther("10000"); // 10K LP each
  await mockLP.mint(deployer.address, lpAmount);
  await mockLP.mint(user1.address, lpAmount);
  await mockLP.mint(user2.address, lpAmount);
  console.log("✓ Minted 10K LP tokens to deployer and test users");

  // Deploy RewardsGauge
  const RewardsGauge = await hre.ethers.getContractFactory("CyrusRewardsGauge");
  const rewardsGauge = await RewardsGauge.deploy(
    deployedContracts.mockLP,   // LP token to stake
    deployedContracts.pars,     // PARS reward token
    "CYRUS/USDT LP Gauge",      // Name
    deployer.address            // initialOwner (governance)
  );
  await rewardsGauge.waitForDeployment();
  deployedContracts.rewardsGauge = await rewardsGauge.getAddress();
  console.log("✓ CyrusRewardsGauge deployed at:", deployedContracts.rewardsGauge);

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 8: Configure Contracts
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 8: Configuring Contracts");
  console.log("=".repeat(70));

  // 1. Set GaugeController as PARS minter
  console.log("\n1. Setting GaugeController as PARS minter...");
  const parsContract = await hre.ethers.getContractAt("PARS", deployedContracts.pars);
  await parsContract.setMinter(deployedContracts.gaugeController);
  console.log("✓ GaugeController is now PARS minter");

  // 2. Set GaugeController on RewardsGauge
  console.log("\n2. Setting GaugeController on RewardsGauge...");
  const rewardsGaugeContract = await hre.ethers.getContractAt("CyrusRewardsGauge", deployedContracts.rewardsGauge);
  await rewardsGaugeContract.setGaugeController(deployedContracts.gaugeController);
  console.log("✓ GaugeController set on RewardsGauge");

  // 3. Add RewardsGauge to GaugeController
  console.log("\n3. Adding RewardsGauge to GaugeController...");
  const gcContract = await hre.ethers.getContractAt("CyrusGaugeController", deployedContracts.gaugeController);
  const addGaugeTx = await gcContract.addGauge(deployedContracts.rewardsGauge, "CYRUS/USDT LP");
  await addGaugeTx.wait();
  const gaugeId = await gcContract.gaugeIds(deployedContracts.rewardsGauge);
  console.log("✓ RewardsGauge added with ID:", gaugeId.toString());

  // 4. Mint some PARS for initial distribution testing
  console.log("\n4. Minting initial PARS for testing...");
  // First, temporarily set deployer as minter to mint test tokens
  // Note: In production, only GaugeController can mint
  // For testing, we'll transfer some PARS to the GaugeController for distribution
  const initialPars = hre.ethers.parseEther("10000000"); // 10M PARS for testing
  await parsContract.setMinter(deployer.address);
  await parsContract.mint(deployedContracts.gaugeController, initialPars);
  await parsContract.setMinter(deployedContracts.gaugeController); // Reset to GaugeController
  console.log("✓ Minted 10M PARS to GaugeController for distribution");

  // ═══════════════════════════════════════════════════════════════════════
  // SUMMARY
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("DEPLOYMENT SUMMARY");
  console.log("=".repeat(70));
  console.log("\nContract Addresses:");
  console.log("-".repeat(70));
  console.log("MockUSDT:           ", deployedContracts.mockUSDT);
  console.log("CYRUS:              ", deployedContracts.cyrus);
  console.log("CyrusDAO:           ", deployedContracts.cyrusDAO);
  console.log("PARS:               ", deployedContracts.pars);
  console.log("sPARS:              ", deployedContracts.spars);
  console.log("GaugeController:    ", deployedContracts.gaugeController);
  console.log("MockLP:             ", deployedContracts.mockLP);
  console.log("RewardsGauge:       ", deployedContracts.rewardsGauge);

  console.log("\n" + "-".repeat(70));
  console.log("Test Accounts:");
  console.log("-".repeat(70));
  console.log("Deployer:  ", deployer.address);
  console.log("User 1:    ", user1.address);
  console.log("User 2:    ", user2.address);
  console.log("User 3:    ", user3.address);
  console.log("User 4:    ", user4.address);

  console.log("\n" + "-".repeat(70));
  console.log("Configuration Status:");
  console.log("-".repeat(70));
  console.log("✓ MockUSDT minted to test accounts");
  console.log("✓ CYRUS tokens purchased by deployer");
  console.log("✓ Deployer delegated votes to self");
  console.log("✓ PARS minter set to GaugeController");
  console.log("✓ sPARS ready for staking");
  console.log("✓ GaugeController has RewardsGauge registered");
  console.log("✓ RewardsGauge configured with GaugeController");
  console.log("✓ Initial PARS minted to GaugeController");

  console.log("\n" + "-".repeat(70));
  console.log("JSON Output (for app config):");
  console.log("-".repeat(70));
  console.log(JSON.stringify(deployedContracts, null, 2));

  // Write addresses to file for app integration
  const fs = require("fs");
  const addressesPath = "./deployments/localhost.json";

  // Ensure deployments directory exists
  if (!fs.existsSync("./deployments")) {
    fs.mkdirSync("./deployments", { recursive: true });
  }

  fs.writeFileSync(addressesPath, JSON.stringify({
    network: "localhost",
    chainId: 31337,
    timestamp: new Date().toISOString(),
    contracts: deployedContracts,
    testAccounts: {
      deployer: deployer.address,
      user1: user1.address,
      user2: user2.address,
      user3: user3.address,
      user4: user4.address
    }
  }, null, 2));
  console.log("\n✓ Addresses written to:", addressesPath);

  console.log("\n" + "=".repeat(70));
  console.log("DEPLOYMENT COMPLETE");
  console.log("=".repeat(70));

  return deployedContracts;
}

main()
  .then((addresses) => {
    console.log("\nDeployed addresses:", addresses);
    process.exit(0);
  })
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
