const hre = require("hardhat");

/**
 * Deploy Default Sub-DAOs for Cyrus Community Governance
 *
 * Creates decentralized governance structure with specialized sub-DAOs:
 * 1. Treasury SubDAO - Fund management
 * 2. Grants SubDAO - Community grants
 * 3. Development SubDAO - Protocol development
 * 4. Community SubDAO - Community initiatives
 * 5. Regional SubDAOs - Geographic chapters
 *
 * Each SubDAO has GitHub Discussions integration for transparent governance.
 */

// SubDAO Category enum (must match contract)
const SubDAOCategory = {
  Treasury: 0,
  Grants: 1,
  Development: 2,
  Community: 3,
  Marketing: 4,
  Research: 5,
  Regional: 6,
  Custom: 7
};

// Default sub-DAO configurations
const DEFAULT_SUBDAOS = [
  {
    name: "Treasury SubDAO",
    description: "Manages protocol treasury funds, investments, and financial operations. Responsible for diversification, yield strategies, and budget allocation.",
    category: SubDAOCategory.Treasury,
    githubRepo: "cyrus-pahlavi/cyrus-governance",
    votingPeriod: 7 * 24 * 60 * 60, // 7 days
    votingDelay: 1 * 24 * 60 * 60,  // 1 day
    proposalThresholdPct: 0.1,      // 0.1% of total supply
    quorumBps: 400,                 // 4% quorum
    budgetAllocation: "10000000",   // 10M PARS
    discussionCategory: "treasury"
  },
  {
    name: "Grants SubDAO",
    description: "Funds community projects, ecosystem development, and builder grants. Supports developers, artists, and community contributors.",
    category: SubDAOCategory.Grants,
    githubRepo: "cyrus-pahlavi/cyrus-governance",
    votingPeriod: 5 * 24 * 60 * 60, // 5 days
    votingDelay: 1 * 24 * 60 * 60,  // 1 day
    proposalThresholdPct: 0.05,     // 0.05% of total supply
    quorumBps: 200,                 // 2% quorum
    budgetAllocation: "5000000",    // 5M PARS
    discussionCategory: "grants"
  },
  {
    name: "Development SubDAO",
    description: "Oversees protocol development, smart contract upgrades, security audits, and technical roadmap. Coordinates with core developers.",
    category: SubDAOCategory.Development,
    githubRepo: "cyrus-pahlavi/cyrus-governance",
    votingPeriod: 7 * 24 * 60 * 60, // 7 days
    votingDelay: 2 * 24 * 60 * 60,  // 2 days (more review time)
    proposalThresholdPct: 0.1,      // 0.1% of total supply
    quorumBps: 300,                 // 3% quorum
    budgetAllocation: "8000000",    // 8M PARS
    discussionCategory: "development"
  },
  {
    name: "Community SubDAO",
    description: "Drives community initiatives, events, education, and social activities. Fosters cultural connections and diaspora engagement.",
    category: SubDAOCategory.Community,
    githubRepo: "cyrus-pahlavi/cyrus-governance",
    votingPeriod: 5 * 24 * 60 * 60, // 5 days
    votingDelay: 12 * 60 * 60,      // 12 hours
    proposalThresholdPct: 0.02,     // 0.02% (more accessible)
    quorumBps: 100,                 // 1% quorum
    budgetAllocation: "3000000",    // 3M PARS
    discussionCategory: "community"
  },
  {
    name: "Marketing SubDAO",
    description: "Manages marketing campaigns, partnerships, brand development, and growth strategies. Expands global reach and adoption.",
    category: SubDAOCategory.Marketing,
    githubRepo: "cyrus-pahlavi/cyrus-governance",
    votingPeriod: 5 * 24 * 60 * 60, // 5 days
    votingDelay: 1 * 24 * 60 * 60,  // 1 day
    proposalThresholdPct: 0.05,     // 0.05%
    quorumBps: 200,                 // 2% quorum
    budgetAllocation: "4000000",    // 4M PARS
    discussionCategory: "marketing"
  },
  {
    name: "Research SubDAO",
    description: "Funds research initiatives, academic partnerships, and innovation experiments. Explores new DeFi primitives and protocol improvements.",
    category: SubDAOCategory.Research,
    githubRepo: "cyrus-pahlavi/cyrus-governance",
    votingPeriod: 10 * 24 * 60 * 60, // 10 days (longer for research)
    votingDelay: 2 * 24 * 60 * 60,   // 2 days
    proposalThresholdPct: 0.1,       // 0.1%
    quorumBps: 200,                  // 2% quorum
    budgetAllocation: "2000000",     // 2M PARS
    discussionCategory: "research"
  }
];

// Regional SubDAOs for global community chapters
const REGIONAL_SUBDAOS = [
  {
    name: "North America Chapter",
    description: "Coordinates Persian diaspora community in USA and Canada. Hosts events, meetups, and local initiatives.",
    region: "north-america",
    budgetAllocation: "1000000"  // 1M PARS
  },
  {
    name: "Europe Chapter",
    description: "Serves the European Persian community across UK, Germany, France, Sweden, and beyond.",
    region: "europe",
    budgetAllocation: "1000000"  // 1M PARS
  },
  {
    name: "Middle East Chapter",
    description: "Connects communities in UAE, Turkey, and neighboring regions. Supports cross-border initiatives.",
    region: "middle-east",
    budgetAllocation: "1000000"  // 1M PARS
  },
  {
    name: "Asia Pacific Chapter",
    description: "Engages diaspora in Australia, Southeast Asia, and East Asia. Builds bridges across cultures.",
    region: "asia-pacific",
    budgetAllocation: "500000"   // 500K PARS
  },
  {
    name: "Latin America Chapter",
    description: "Supports communities in Brazil, Argentina, and across Latin America.",
    region: "latin-america",
    budgetAllocation: "500000"   // 500K PARS
  }
];

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const network = hre.network.name;

  console.log("=".repeat(70));
  console.log("CYRUS SUB-DAO DEPLOYMENT");
  console.log("=".repeat(70));
  console.log("\nNetwork:", network);
  console.log("Deployer:", deployer.address);

  // ═══════════════════════════════════════════════════════════════════════
  // CONFIGURATION
  // ═══════════════════════════════════════════════════════════════════════

  // Required: Governance token (PARS or CYRUS)
  const governanceTokenAddress = process.env.GOVERNANCE_TOKEN_ADDRESS || process.env.PARS_ADDRESS;
  if (!governanceTokenAddress) {
    throw new Error("GOVERNANCE_TOKEN_ADDRESS or PARS_ADDRESS not set");
  }

  // Required: Parent DAO address
  const parentDAOAddress = process.env.CYRUS_DAO_ADDRESS;
  if (!parentDAOAddress) {
    throw new Error("CYRUS_DAO_ADDRESS not set");
  }

  // Get governance token total supply for threshold calculations
  const governanceToken = await hre.ethers.getContractAt("IERC20", governanceTokenAddress);
  const totalSupply = await governanceToken.totalSupply();

  console.log("\nConfiguration:");
  console.log("-".repeat(70));
  console.log("Governance Token:", governanceTokenAddress);
  console.log("Parent DAO:", parentDAOAddress);
  console.log("Total Supply:", hre.ethers.formatEther(totalSupply), "tokens");

  // ═══════════════════════════════════════════════════════════════════════
  // DEPLOY MAIN SUB-DAOS
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("DEPLOYING MAIN SUB-DAOS");
  console.log("=".repeat(70));

  const SubDAO = await hre.ethers.getContractFactory("CyrusSubDAO");
  const deployedSubDAOs = [];

  for (const config of DEFAULT_SUBDAOS) {
    console.log(`\nDeploying ${config.name}...`);

    // Calculate proposal threshold based on total supply
    const proposalThreshold = (totalSupply * BigInt(Math.floor(config.proposalThresholdPct * 100))) / 10000n;

    const subDAOConfig = {
      name: config.name,
      description: config.description,
      category: config.category,
      githubRepo: config.githubRepo,
      votingPeriod: config.votingPeriod,
      votingDelay: config.votingDelay,
      proposalThreshold: proposalThreshold,
      quorumBps: config.quorumBps,
      budgetAllocation: hre.ethers.parseEther(config.budgetAllocation)
    };

    const subDAO = await SubDAO.deploy(
      governanceTokenAddress,
      parentDAOAddress,
      subDAOConfig
    );
    await subDAO.waitForDeployment();
    const address = await subDAO.getAddress();

    deployedSubDAOs.push({
      name: config.name,
      category: config.discussionCategory,
      address: address,
      config: config
    });

    console.log(`✓ ${config.name} deployed at: ${address}`);
    console.log(`  Budget: ${config.budgetAllocation} PARS`);
    console.log(`  Quorum: ${config.quorumBps / 100}%`);
    console.log(`  Discussion: https://github.com/${config.githubRepo}/discussions/categories/${config.discussionCategory}`);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // DEPLOY REGIONAL SUB-DAOS
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("DEPLOYING REGIONAL SUB-DAOS");
  console.log("=".repeat(70));

  const regionalSubDAOs = [];

  for (const regional of REGIONAL_SUBDAOS) {
    console.log(`\nDeploying ${regional.name}...`);

    // Regional SubDAOs have lower thresholds for local participation
    const proposalThreshold = (totalSupply * 2n) / 10000n; // 0.02%

    const subDAOConfig = {
      name: regional.name,
      description: regional.description,
      category: SubDAOCategory.Regional,
      githubRepo: "cyrus-pahlavi/cyrus-governance",
      votingPeriod: 5 * 24 * 60 * 60,  // 5 days
      votingDelay: 12 * 60 * 60,        // 12 hours
      proposalThreshold: proposalThreshold,
      quorumBps: 50,                    // 0.5% quorum (easier for regional)
      budgetAllocation: hre.ethers.parseEther(regional.budgetAllocation)
    };

    const subDAO = await SubDAO.deploy(
      governanceTokenAddress,
      parentDAOAddress,
      subDAOConfig
    );
    await subDAO.waitForDeployment();
    const address = await subDAO.getAddress();

    regionalSubDAOs.push({
      name: regional.name,
      region: regional.region,
      address: address
    });

    console.log(`✓ ${regional.name} deployed at: ${address}`);
    console.log(`  Budget: ${regional.budgetAllocation} PARS`);
    console.log(`  Discussion: https://github.com/cyrus-pahlavi/cyrus-governance/discussions/categories/regional-${regional.region}`);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // SUMMARY
  // ═══════════════════════════════════════════════════════════════════════

  console.log("\n" + "=".repeat(70));
  console.log("DEPLOYMENT SUMMARY");
  console.log("=".repeat(70));

  console.log("\nMain SubDAOs:");
  console.log("-".repeat(70));
  for (const dao of deployedSubDAOs) {
    console.log(`${dao.name}: ${dao.address}`);
  }

  console.log("\nRegional SubDAOs:");
  console.log("-".repeat(70));
  for (const dao of regionalSubDAOs) {
    console.log(`${dao.name}: ${dao.address}`);
  }

  // Total budget allocation
  let totalBudget = 0n;
  for (const dao of deployedSubDAOs) {
    totalBudget += hre.ethers.parseEther(dao.config.budgetAllocation);
  }
  for (const regional of REGIONAL_SUBDAOS) {
    totalBudget += hre.ethers.parseEther(regional.budgetAllocation);
  }

  console.log("\n" + "-".repeat(70));
  console.log("Total Budget Allocation:", hre.ethers.formatEther(totalBudget), "PARS");

  console.log("\n" + "-".repeat(70));
  console.log("GitHub Discussion Categories to Create:");
  console.log("-".repeat(70));
  console.log("Navigate to: https://github.com/cyrus-pahlavi/cyrus-governance/discussions/categories");
  console.log("\nCreate the following categories:");
  for (const dao of deployedSubDAOs) {
    console.log(`  - ${dao.category}: ${dao.name} proposals and discussions`);
  }
  for (const regional of regionalSubDAOs) {
    console.log(`  - regional-${regional.region}: ${regional.name} discussions`);
  }

  console.log("\n" + "-".repeat(70));
  console.log("Environment Variables:");
  console.log("-".repeat(70));
  for (const dao of deployedSubDAOs) {
    const envName = dao.name.toUpperCase().replace(/\s+/g, "_").replace("SUBDAO", "SUBDAO_ADDRESS");
    console.log(`${envName}=${dao.address}`);
  }

  console.log("\n" + "=".repeat(70));
  console.log("DEPLOYMENT COMPLETE");
  console.log("=".repeat(70));
  console.log("\nNext Steps:");
  console.log("1. Create GitHub Discussion categories for each SubDAO");
  console.log("2. Transfer ownership of SubDAOs to parent DAO/multisig");
  console.log("3. Fund SubDAO budgets with PARS tokens");
  console.log("4. Announce SubDAOs to community");
  console.log("5. Onboard initial SubDAO coordinators");

  return {
    mainSubDAOs: deployedSubDAOs.map(d => ({ name: d.name, address: d.address })),
    regionalSubDAOs: regionalSubDAOs.map(d => ({ name: d.name, address: d.address }))
  };
}

main()
  .then((result) => {
    console.log("\nDeployed:", result);
    process.exit(0);
  })
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
