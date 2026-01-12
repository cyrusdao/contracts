const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const network = hre.network.name;

  console.log("=".repeat(60));
  console.log("CYRUS DAO Deployment");
  console.log("=".repeat(60));
  console.log("\nNetwork:", network);
  console.log("Deployer:", deployer.address);
  console.log("Balance:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)), "ETH");
  console.log("Chain ID:", (await hre.ethers.provider.getNetwork()).chainId);

  // Get the CYRUS token address - must be deployed first
  const cyrusTokenAddress = process.env.CYRUS_TOKEN_ADDRESS;
  if (!cyrusTokenAddress) {
    throw new Error("CYRUS_TOKEN_ADDRESS environment variable not set. Deploy the token first.");
  }

  // Guardian: Cyrus Pahlavi multisig (Safe)
  // This should be a Gnosis Safe multisig with the founding board members
  const guardianAddress = process.env.GUARDIAN_ADDRESS || deployer.address;

  // Treasury: DAO treasury for community funds
  const treasuryAddress = process.env.TREASURY_ADDRESS || deployer.address;

  // Board members: Initial founding board
  // Cyrus Pahlavi, Kamran Pahlavi, Dara Gallopin
  const boardMemberAddresses = process.env.BOARD_MEMBERS
    ? process.env.BOARD_MEMBERS.split(",").map(addr => addr.trim())
    : [deployer.address];

  console.log("\n" + "-".repeat(60));
  console.log("Deployment Parameters:");
  console.log("-".repeat(60));
  console.log("CYRUS Token:", cyrusTokenAddress);
  console.log("Guardian (Multisig):", guardianAddress);
  console.log("Treasury:", treasuryAddress);
  console.log("Board Members:", boardMemberAddresses.length);
  boardMemberAddresses.forEach((addr, i) => {
    console.log(`  ${i + 1}. ${addr}`);
  });

  // Validate addresses
  if (!hre.ethers.isAddress(cyrusTokenAddress)) {
    throw new Error("Invalid CYRUS token address");
  }
  if (!hre.ethers.isAddress(guardianAddress)) {
    throw new Error("Invalid guardian address");
  }
  if (!hre.ethers.isAddress(treasuryAddress)) {
    throw new Error("Invalid treasury address");
  }
  for (const addr of boardMemberAddresses) {
    if (!hre.ethers.isAddress(addr)) {
      throw new Error(`Invalid board member address: ${addr}`);
    }
  }

  console.log("\nDeploying CyrusDAO contract...");

  // Deploy the CyrusDAO contract
  const CyrusDAO = await hre.ethers.getContractFactory("CyrusDAO");
  const dao = await CyrusDAO.deploy(
    cyrusTokenAddress,
    guardianAddress,
    treasuryAddress,
    boardMemberAddresses
  );

  await dao.waitForDeployment();

  const daoAddress = await dao.getAddress();

  // Get DAO details
  const guardian = await dao.guardian();
  const treasury = await dao.treasury();
  const publicGovernance = await dao.publicGovernance();
  const proposalThreshold = await dao.PROPOSAL_THRESHOLD();
  const quorumVotes = await dao.QUORUM_VOTES();
  const votingPeriod = await dao.VOTING_PERIOD();
  const timelockDelay = await dao.TIMELOCK_DELAY();
  const nowruz2026 = await dao.NOWRUZ_2026();

  console.log("\n" + "=".repeat(60));
  console.log("DEPLOYMENT SUCCESSFUL");
  console.log("=".repeat(60));
  console.log("\nDAO Contract Address:", daoAddress);

  console.log("\n" + "-".repeat(60));
  console.log("DAO Configuration:");
  console.log("-".repeat(60));
  console.log("Guardian:", guardian);
  console.log("Treasury:", treasury);
  console.log("Public Governance:", publicGovernance ? "Active" : "Stewardship Phase");
  console.log("Proposal Threshold:", hre.ethers.formatEther(proposalThreshold), "CYRUS");
  console.log("Quorum Votes:", hre.ethers.formatEther(quorumVotes), "CYRUS");
  console.log("Voting Period:", Number(votingPeriod) / 86400, "days");
  console.log("Timelock Delay:", Number(timelockDelay) / 86400, "days");
  console.log("Public Governance Unlock:", new Date(Number(nowruz2026) * 1000).toISOString());

  // Check board member status
  console.log("\n" + "-".repeat(60));
  console.log("Board Members:");
  console.log("-".repeat(60));
  for (let i = 0; i < boardMemberAddresses.length; i++) {
    const addr = boardMemberAddresses[i];
    const isMember = await dao.isBoardMember(addr);
    console.log(`  ${i + 1}. ${addr}: ${isMember ? "✓ Active" : "✗ Not Active"}`);
  }

  console.log("\n" + "-".repeat(60));
  console.log("Contract Verification:");
  console.log("-".repeat(60));
  const boardMembersArg = `"[${boardMemberAddresses.map(a => `\\"${a}\\"`).join(",")}]"`;
  console.log("Run the following command to verify:");
  console.log(`\nnpx hardhat verify --network ${network} ${daoAddress} "${cyrusTokenAddress}" "${guardianAddress}" "${treasuryAddress}" ${boardMembersArg}`);

  console.log("\n" + "-".repeat(60));
  console.log("Links:");
  console.log("-".repeat(60));
  if (network === "base") {
    console.log("Basescan:", `https://basescan.org/address/${daoAddress}`);
  } else if (network === "baseSepolia") {
    console.log("Basescan:", `https://sepolia.basescan.org/address/${daoAddress}`);
  }

  console.log("\n" + "-".repeat(60));
  console.log("Governance Timeline:");
  console.log("-".repeat(60));
  console.log("1. CURRENT: Stewardship Phase - Board members can create proposals");
  console.log("2. NOW until Nowruz 2026: Transfers locked, community building");
  console.log("3. After Nowruz 2026 (March 21, 2026): Guardian can activate public governance");
  console.log("4. FUTURE: Full public governance - token holders can propose");
  console.log("5. OPTIONAL: Guardian can abdicate for full decentralization");

  console.log("\n" + "=".repeat(60));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
