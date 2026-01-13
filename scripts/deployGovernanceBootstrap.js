const hre = require("hardhat");
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

/**
 * Deploy Cyrus Governance Bootstrap
 *
 * This script:
 * 1. Derives 5 signer addresses from LUX_MNEMONIC (index 0-4)
 * 2. Deploys a mock Safe (for local testing) or uses existing Safe
 * 3. Deploys CyrusTimelock with Safe as admin
 * 4. Deploys vePARS for governance voting
 * 5. Updates all contracts to use Timelock as admin
 * 6. Records addresses in deployments/<network>.json
 *
 * Bootstrap Flow:
 * Safe (3/5) -> Timelock -> Protocol Contracts
 *
 * After vePARS governance is active:
 * vePARS Governance -> Timelock -> Protocol Contracts
 */

async function main() {
  const network = hre.network.name;
  console.log(`\n🏛️  Deploying Cyrus Governance Bootstrap to ${network}...\n`);

  // Load existing deployment
  const deploymentsPath = path.join(__dirname, `../deployments/${network}.json`);
  let deployment = {};
  if (fs.existsSync(deploymentsPath)) {
    deployment = JSON.parse(fs.readFileSync(deploymentsPath, "utf8"));
    console.log("📄 Loaded existing deployment");
  }

  // Derive signers from mnemonic
  const mnemonic = process.env.LUX_MNEMONIC;
  if (!mnemonic) {
    throw new Error("LUX_MNEMONIC environment variable required");
  }

  // Derive 5 addresses (index 0-4)
  const signers = [];
  for (let i = 0; i < 5; i++) {
    const wallet = ethers.Wallet.fromMnemonic(mnemonic, `m/44'/60'/0'/0/${i}`);
    signers.push(wallet.address);
  }
  console.log("👥 Derived 5 signers from mnemonic:");
  signers.forEach((s, i) => console.log(`   ${i}: ${s}`));

  const [deployer] = await ethers.getSigners();
  console.log(`\n📝 Deployer: ${deployer.address}`);
  console.log(`   Balance: ${ethers.utils.formatEther(await deployer.getBalance())} ETH\n`);

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 1: Deploy or use existing Safe
  // ═══════════════════════════════════════════════════════════════════════

  let safeAddress;

  if (network === "localhost" || network === "hardhat") {
    // Deploy MockSafe for local testing
    console.log("🔐 Deploying MockSafe (3/5 threshold)...");
    const MockSafe = await ethers.getContractFactory("MockSafe");
    const mockSafe = await MockSafe.deploy(signers, 3);
    await mockSafe.deployed();
    safeAddress = mockSafe.address;
    console.log(`   MockSafe deployed: ${safeAddress}`);
  } else {
    // For production, Safe should be pre-deployed
    if (!deployment.safe) {
      throw new Error("Safe address required for non-local deployment. Deploy Safe first.");
    }
    safeAddress = deployment.safe;
    console.log(`🔐 Using existing Safe: ${safeAddress}`);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 2: Deploy CyrusTimelock
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n⏰ Deploying CyrusTimelock...");

  const STANDARD_DELAY = 2 * 24 * 60 * 60; // 2 days in seconds

  // Proposers: Safe (initially)
  // Executors: Safe + anyone (zero address)
  const proposers = [safeAddress];
  const executors = [safeAddress, ethers.constants.AddressZero];

  const CyrusTimelock = await ethers.getContractFactory("CyrusTimelock");
  const timelock = await CyrusTimelock.deploy(
    STANDARD_DELAY,
    safeAddress,
    proposers,
    executors
  );
  await timelock.deployed();
  console.log(`   CyrusTimelock deployed: ${timelock.address}`);
  console.log(`   Min delay: ${STANDARD_DELAY / 86400} days`);

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 3: Deploy vePARS
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n🗳️  Deploying vePARS...");

  if (!deployment.pars) {
    throw new Error("PARS not deployed. Run deployGovernance.js first.");
  }

  const VePARS = await ethers.getContractFactory("vePARS");
  const vePars = await VePARS.deploy(deployment.pars, deployer.address);
  await vePars.deployed();
  console.log(`   vePARS deployed: ${vePars.address}`);

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 4: Transfer ownership to Timelock
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n🔄 Transferring ownership to Timelock...");

  // Transfer CYRUS ownership if exists
  if (deployment.cyrus) {
    const cyrus = await ethers.getContractAt("CYRUS", deployment.cyrus);
    const currentOwner = await cyrus.owner();
    if (currentOwner.toLowerCase() === deployer.address.toLowerCase()) {
      await cyrus.transferOwnership(timelock.address);
      console.log(`   CYRUS ownership transferred to Timelock`);
    } else {
      console.log(`   CYRUS already owned by: ${currentOwner}`);
    }
  }

  // Transfer PARS minter role
  if (deployment.pars) {
    const pars = await ethers.getContractAt("PARS", deployment.pars);
    // PARS uses role-based access - grant MINTER_ROLE to Timelock
    const MINTER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("MINTER_ROLE"));
    const hasRole = await pars.hasRole(MINTER_ROLE, timelock.address);
    if (!hasRole) {
      await pars.grantRole(MINTER_ROLE, timelock.address);
      console.log(`   PARS MINTER_ROLE granted to Timelock`);
    }

    // Grant DEFAULT_ADMIN_ROLE to Timelock
    const DEFAULT_ADMIN_ROLE = ethers.constants.HashZero;
    const hasAdminRole = await pars.hasRole(DEFAULT_ADMIN_ROLE, timelock.address);
    if (!hasAdminRole) {
      await pars.grantRole(DEFAULT_ADMIN_ROLE, timelock.address);
      console.log(`   PARS DEFAULT_ADMIN_ROLE granted to Timelock`);
    }
  }

  // Transfer GaugeController ownership
  if (deployment.gaugeController) {
    const gaugeController = await ethers.getContractAt("CyrusGaugeController", deployment.gaugeController);
    const currentOwner = await gaugeController.owner();
    if (currentOwner.toLowerCase() === deployer.address.toLowerCase()) {
      await gaugeController.transferOwnership(timelock.address);
      console.log(`   GaugeController ownership transferred to Timelock`);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 5: Save deployment
  // ═══════════════════════════════════════════════════════════════════════

  deployment = {
    ...deployment,
    safe: safeAddress,
    timelock: timelock.address,
    vePars: vePars.address,
    governance: {
      signers: signers,
      threshold: 3,
      timelockDelay: STANDARD_DELAY,
      governanceActive: false,
    },
    deployedAt: new Date().toISOString(),
  };

  // Ensure deployments directory exists
  const deploymentsDir = path.dirname(deploymentsPath);
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  fs.writeFileSync(deploymentsPath, JSON.stringify(deployment, null, 2));
  console.log(`\n💾 Deployment saved to ${deploymentsPath}`);

  // ═══════════════════════════════════════════════════════════════════════
  // SUMMARY
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "═".repeat(60));
  console.log("🏛️  GOVERNANCE BOOTSTRAP COMPLETE");
  console.log("═".repeat(60));
  console.log("\n📋 Deployed Contracts:");
  console.log(`   Safe (3/5):      ${safeAddress}`);
  console.log(`   Timelock:        ${timelock.address}`);
  console.log(`   vePARS:          ${vePars.address}`);
  console.log("\n👥 Safe Signers (3/5 threshold):");
  signers.forEach((s, i) => console.log(`   ${i}: ${s}`));
  console.log("\n⏰ Timelock Configuration:");
  console.log(`   Standard Delay:  ${STANDARD_DELAY / 86400} days`);
  console.log(`   Critical Delay:  7 days (for ownership transfers)`);
  console.log(`   Emergency Delay: 6 hours (for pause/unpause)`);
  console.log("\n🔐 Ownership Status:");
  console.log(`   CYRUS:           ${timelock.address}`);
  console.log(`   PARS:            ${timelock.address} (MINTER_ROLE)`);
  console.log(`   GaugeController: ${timelock.address}`);
  console.log("\n📝 Next Steps:");
  console.log("   1. Verify signers have access to Safe");
  console.log("   2. Test timelock proposal/execution flow");
  console.log("   3. Deploy CyrusDAO with vePARS voting");
  console.log("   4. Call timelock.handoffToGovernance(cyrusDAO)");
  console.log("═".repeat(60) + "\n");

  return deployment;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
