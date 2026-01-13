const hre = require("hardhat");

/**
 * Deployment script for Cyrus Governance Stack
 *
 * Deploys:
 * 1. PARS - Emissions/reward token
 * 2. sPARS - Staked PARS (rebasing)
 * 3. CyrusGaugeController - Epoch-based emission distribution
 * 4. CyrusRewardsGauge - LP staking rewards
 *
 * Requires:
 * - CYRUS token deployed
 * - CyrusDAO deployed
 * - 3/5 multisig accounts (from LUX_MNEMONIC or MULTISIG_SIGNERS)
 */

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const network = hre.network.name;

  console.log("=".repeat(70));
  console.log("CYRUS GOVERNANCE STACK DEPLOYMENT");
  console.log("=".repeat(70));
  console.log("\nNetwork:", network);
  console.log("Deployer:", deployer.address);
  console.log("Balance:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)), "ETH");
  console.log("Chain ID:", (await hre.ethers.provider.getNetwork()).chainId);

  // ═══════════════════════════════════════════════════════════════════════
  // CONFIGURATION
  // ═══════════════════════════════════════════════════════════════════════

  // Required: CYRUS token address
  const cyrusTokenAddress = process.env.CYRUS_TOKEN_ADDRESS;
  if (!cyrusTokenAddress) {
    throw new Error("CYRUS_TOKEN_ADDRESS not set. Deploy CYRUS token first.");
  }

  // Required: CyrusDAO address
  const cyrusDAOAddress = process.env.CYRUS_DAO_ADDRESS;
  if (!cyrusDAOAddress) {
    throw new Error("CYRUS_DAO_ADDRESS not set. Deploy CyrusDAO first.");
  }

  // 3/5 Multisig signers (from LUX_MNEMONIC or explicit addresses)
  // These will be the initial governance multisig
  let multisigSigners;
  if (process.env.MULTISIG_SIGNERS) {
    multisigSigners = process.env.MULTISIG_SIGNERS.split(",").map(addr => addr.trim());
  } else if (process.env.LUX_MNEMONIC) {
    // Derive 5 accounts from LUX_MNEMONIC
    const hdNode = hre.ethers.HDNodeWallet.fromPhrase(process.env.LUX_MNEMONIC);
    multisigSigners = [];
    for (let i = 0; i < 5; i++) {
      const derived = hdNode.derivePath(`m/44'/60'/0'/0/${i}`);
      multisigSigners.push(derived.address);
    }
    console.log("\n[INFO] Using 5 accounts derived from LUX_MNEMONIC for 3/5 multisig");
  } else {
    // Fallback: use deployer for all roles (not recommended for production)
    console.log("\n[WARN] No MULTISIG_SIGNERS or LUX_MNEMONIC set. Using deployer address.");
    multisigSigners = [deployer.address];
  }

  // Governance owner (initially deployer, will transfer to DAO/multisig)
  const governanceOwner = process.env.GOVERNANCE_OWNER || cyrusDAOAddress;

  // LP token for rewards gauge (e.g., CYRUS/USDT LP)
  const lpTokenAddress = process.env.LP_TOKEN_ADDRESS;

  // Initial PARS emissions per epoch (default: 1M PARS per week)
  const emissionsPerEpoch = process.env.EMISSIONS_PER_EPOCH
    ? hre.ethers.parseEther(process.env.EMISSIONS_PER_EPOCH)
    : hre.ethers.parseEther("1000000");

  console.log("\n" + "-".repeat(70));
  console.log("Deployment Parameters:");
  console.log("-".repeat(70));
  console.log("CYRUS Token:", cyrusTokenAddress);
  console.log("CyrusDAO:", cyrusDAOAddress);
  console.log("Governance Owner:", governanceOwner);
  console.log("Emissions Per Epoch:", hre.ethers.formatEther(emissionsPerEpoch), "PARS");
  console.log("Multisig Signers:", multisigSigners.length, "(3/5 threshold)");
  multisigSigners.forEach((addr, i) => {
    console.log(`  ${i + 1}. ${addr}`);
  });
  if (lpTokenAddress) {
    console.log("LP Token:", lpTokenAddress);
  }

  // Validate addresses
  const validateAddress = (addr, name) => {
    if (!hre.ethers.isAddress(addr)) {
      throw new Error(`Invalid ${name}: ${addr}`);
    }
  };

  validateAddress(cyrusTokenAddress, "CYRUS token address");
  validateAddress(cyrusDAOAddress, "CyrusDAO address");
  validateAddress(governanceOwner, "governance owner address");
  multisigSigners.forEach((addr, i) => validateAddress(addr, `multisig signer ${i + 1}`));
  if (lpTokenAddress) validateAddress(lpTokenAddress, "LP token address");

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 1: Deploy PARS Token
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 1: Deploying PARS Token (Rebasing Governance Token)");
  console.log("=".repeat(70));

  const PARS = await hre.ethers.getContractFactory("PARS");

  // PARS constructor: (treasury, timelock)
  // - treasury: receives protocol fees
  // - timelock: gets GOVERNANCE_ROLE
  // MINTER_ROLE is granted separately after deployment
  const treasury = process.env.TREASURY_ADDRESS || deployer.address;
  const pars = await PARS.deploy(
    treasury,         // treasury address
    governanceOwner   // timelock (gets GOVERNANCE_ROLE)
  );
  await pars.waitForDeployment();
  const parsAddress = await pars.getAddress();
  console.log("✓ PARS deployed at:", parsAddress);
  console.log("  - Treasury:", treasury);
  console.log("  - Timelock:", governanceOwner);

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 2: Deploy sPARS (Staked PARS)
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 2: Deploying sPARS (Staked PARS)");
  console.log("=".repeat(70));

  const SPARS = await hre.ethers.getContractFactory("sPARS");
  const spars = await SPARS.deploy(
    parsAddress,      // PARS token
    governanceOwner   // initialOwner (governance)
  );
  await spars.waitForDeployment();
  const sparsAddress = await spars.getAddress();
  console.log("✓ sPARS deployed at:", sparsAddress);

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 3: Deploy CyrusGaugeController
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 3: Deploying CyrusGaugeController");
  console.log("=".repeat(70));

  const GaugeController = await hre.ethers.getContractFactory("CyrusGaugeController");
  const gaugeController = await GaugeController.deploy(
    cyrusTokenAddress,    // CYRUS governance token for voting
    parsAddress,          // PARS emissions token
    emissionsPerEpoch,    // PARS per epoch
    governanceOwner       // initialOwner (governance)
  );
  await gaugeController.waitForDeployment();
  const gaugeControllerAddress = await gaugeController.getAddress();
  console.log("✓ CyrusGaugeController deployed at:", gaugeControllerAddress);

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 4: Deploy CyrusRewardsGauge (if LP token provided)
  // ═══════════════════════════════════════════════════════════════════════

  let rewardsGaugeAddress = null;
  if (lpTokenAddress) {
    console.log("\n" + "=".repeat(70));
    console.log("PHASE 4: Deploying CyrusRewardsGauge");
    console.log("=".repeat(70));

    const RewardsGauge = await hre.ethers.getContractFactory("CyrusRewardsGauge");
    const rewardsGauge = await RewardsGauge.deploy(
      lpTokenAddress,       // LP token to stake
      parsAddress,          // PARS reward token
      "CYRUS/USDT LP Gauge", // Name
      governanceOwner       // initialOwner (governance)
    );
    await rewardsGauge.waitForDeployment();
    rewardsGaugeAddress = await rewardsGauge.getAddress();
    console.log("✓ CyrusRewardsGauge deployed at:", rewardsGaugeAddress);

    // Set GaugeController on RewardsGauge
    console.log("\nConfiguring RewardsGauge...");
    const rewardsGaugeContract = await hre.ethers.getContractAt("CyrusRewardsGauge", rewardsGaugeAddress);
    await rewardsGaugeContract.setGaugeController(gaugeControllerAddress);
    console.log("✓ GaugeController set on RewardsGauge");
  } else {
    console.log("\n[INFO] LP_TOKEN_ADDRESS not set. Skipping RewardsGauge deployment.");
    console.log("[INFO] Deploy RewardsGauge separately for each LP pair.");
  }

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 4b: Deploy CYRUSStakingRewards (xCYRUS staking for PARS rewards)
  // ═══════════════════════════════════════════════════════════════════════

  // Optional: xCYRUS (LiquidCYRUS) address for staking rewards
  const xCyrusAddress = process.env.XCYRUS_ADDRESS;
  let stakingRewardsAddress = null;

  if (xCyrusAddress) {
    console.log("\n" + "=".repeat(70));
    console.log("PHASE 4b: Deploying CYRUSStakingRewards");
    console.log("=".repeat(70));

    validateAddress(xCyrusAddress, "xCYRUS address");

    const StakingRewards = await hre.ethers.getContractFactory("CYRUSStakingRewards");
    const stakingRewards = await StakingRewards.deploy(
      xCyrusAddress,      // xCYRUS token (stake this to earn PARS)
      parsAddress,        // PARS reward token (minted)
      governanceOwner     // timelock (governance)
    );
    await stakingRewards.waitForDeployment();
    stakingRewardsAddress = await stakingRewards.getAddress();
    console.log("✓ CYRUSStakingRewards deployed at:", stakingRewardsAddress);
    console.log("  - xCYRUS (stake token):", xCyrusAddress);
    console.log("  - PARS (reward token):", parsAddress);
  } else {
    console.log("\n[INFO] XCYRUS_ADDRESS not set. Skipping CYRUSStakingRewards deployment.");
    console.log("[INFO] Deploy xCYRUS (LiquidCYRUS) first, then deploy CYRUSStakingRewards.");
  }

  // ═══════════════════════════════════════════════════════════════════════
  // PHASE 5: Configure Contracts
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("PHASE 5: Configuring Contracts");
  console.log("=".repeat(70));

  // 1. Grant MINTER_ROLE to GaugeController (for LP gauge emissions)
  console.log("\n1. Granting MINTER_ROLE to GaugeController...");
  const parsContract = await hre.ethers.getContractAt("PARS", parsAddress);
  const MINTER_ROLE = await parsContract.MINTER_ROLE();
  await parsContract.grantRole(MINTER_ROLE, gaugeControllerAddress);
  console.log("✓ GaugeController granted MINTER_ROLE");

  // 1b. Grant MINTER_ROLE to CYRUSStakingRewards (for xCYRUS staking rewards)
  if (stakingRewardsAddress) {
    console.log("\n1b. Granting MINTER_ROLE to CYRUSStakingRewards...");
    await parsContract.grantRole(MINTER_ROLE, stakingRewardsAddress);
    console.log("✓ CYRUSStakingRewards granted MINTER_ROLE");
  }

  // 2. Add RewardsGauge to GaugeController (if deployed)
  if (rewardsGaugeAddress) {
    console.log("\n2. Adding RewardsGauge to GaugeController...");
    const gcContract = await hre.ethers.getContractAt("CyrusGaugeController", gaugeControllerAddress);
    const tx = await gcContract.addGauge(rewardsGaugeAddress, "CYRUS/USDT LP");
    await tx.wait();
    const gaugeId = await gcContract.gaugeIds(rewardsGaugeAddress);
    console.log("✓ RewardsGauge added with ID:", gaugeId.toString());
  }

  // 3. Set staking contract on sPARS (optional - for profit distribution)
  console.log("\n3. sPARS staking contract can be set later for profit distribution");

  // ═══════════════════════════════════════════════════════════════════════
  // SUMMARY
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("DEPLOYMENT SUMMARY");
  console.log("=".repeat(70));
  console.log("\nContract Addresses:");
  console.log("-".repeat(70));
  console.log("CYRUS (existing):", cyrusTokenAddress);
  console.log("CyrusDAO (existing):", cyrusDAOAddress);
  console.log("PARS:", parsAddress);
  console.log("sPARS:", sparsAddress);
  console.log("CyrusGaugeController:", gaugeControllerAddress);
  if (rewardsGaugeAddress) {
    console.log("CyrusRewardsGauge:", rewardsGaugeAddress);
  }

  if (stakingRewardsAddress) {
    console.log("CYRUSStakingRewards:", stakingRewardsAddress);
  }

  console.log("\n" + "-".repeat(70));
  console.log("Configuration Status:");
  console.log("-".repeat(70));
  console.log("✓ GaugeController granted MINTER_ROLE on PARS");
  if (stakingRewardsAddress) {
    console.log("✓ CYRUSStakingRewards granted MINTER_ROLE on PARS");
  }
  console.log("✓ sPARS ready for staking (stake PARS → receive sPARS)");
  console.log("✓ GaugeController ready for gauge voting");
  if (rewardsGaugeAddress) {
    console.log("✓ RewardsGauge registered in GaugeController");
    console.log("✓ RewardsGauge configured with GaugeController");
  }

  console.log("\n" + "-".repeat(70));
  console.log("Governance (3/5 Multisig):");
  console.log("-".repeat(70));
  console.log("Owner of all contracts:", governanceOwner);
  console.log("Multisig Signers:");
  multisigSigners.forEach((addr, i) => {
    console.log(`  ${i + 1}. ${addr}`);
  });
  console.log("\n[NOTE] Transfer ownership to Gnosis Safe 3/5 multisig for production");

  console.log("\n" + "-".repeat(70));
  console.log("Next Steps:");
  console.log("-".repeat(70));
  console.log("1. Create Gnosis Safe 3/5 multisig with signers above");
  console.log("2. Transfer ownership of all contracts to Safe");
  console.log("3. Deploy additional RewardsGauges for each LP pair");
  console.log("4. Add gauges to GaugeController via governance");
  console.log("5. Users can vote for gauges using CYRUS tokens");
  console.log("6. Claim emissions for gauges at epoch end");

  console.log("\n" + "-".repeat(70));
  console.log("Environment Variables for .env:");
  console.log("-".repeat(70));
  console.log(`PARS_ADDRESS=${parsAddress}`);
  console.log(`SPARS_ADDRESS=${sparsAddress}`);
  console.log(`GAUGE_CONTROLLER_ADDRESS=${gaugeControllerAddress}`);
  if (rewardsGaugeAddress) {
    console.log(`REWARDS_GAUGE_ADDRESS=${rewardsGaugeAddress}`);
  }
  if (stakingRewardsAddress) {
    console.log(`STAKING_REWARDS_ADDRESS=${stakingRewardsAddress}`);
  }

  console.log("\n" + "-".repeat(70));
  console.log("Verification Commands:");
  console.log("-".repeat(70));
  console.log(`\n# PARS`);
  console.log(`npx hardhat verify --network ${network} ${parsAddress} "${treasury}" "${governanceOwner}"`);
  console.log(`\n# sPARS`);
  console.log(`npx hardhat verify --network ${network} ${sparsAddress} "${parsAddress}" "${governanceOwner}"`);
  console.log(`\n# GaugeController`);
  console.log(`npx hardhat verify --network ${network} ${gaugeControllerAddress} "${cyrusTokenAddress}" "${parsAddress}" "${emissionsPerEpoch}" "${governanceOwner}"`);
  if (rewardsGaugeAddress) {
    console.log(`\n# RewardsGauge`);
    console.log(`npx hardhat verify --network ${network} ${rewardsGaugeAddress} "${lpTokenAddress}" "${parsAddress}" "CYRUS/USDT LP Gauge" "${governanceOwner}"`);
  }
  if (stakingRewardsAddress) {
    console.log(`\n# CYRUSStakingRewards`);
    console.log(`npx hardhat verify --network ${network} ${stakingRewardsAddress} "${xCyrusAddress}" "${parsAddress}" "${governanceOwner}"`);
  }

  console.log("\n" + "=".repeat(70));
  console.log("DEPLOYMENT COMPLETE");
  console.log("=".repeat(70));

  return {
    pars: parsAddress,
    spars: sparsAddress,
    gaugeController: gaugeControllerAddress,
    rewardsGauge: rewardsGaugeAddress,
    stakingRewards: stakingRewardsAddress
  };
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
