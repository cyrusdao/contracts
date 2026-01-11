const hre = require("hardhat");

// USDbC on Base (Bridged USDC from Ethereum - 6 decimals)
// Note: This is USDbC, not native USDC. For native USDC use 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
const USDC_BASE = "0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA";

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const network = hre.network.name;

  console.log("=".repeat(60));
  console.log("CYRUS Token Deployment");
  console.log("=".repeat(60));
  console.log("\nNetwork:", network);
  console.log("Deployer:", deployer.address);
  console.log("Balance:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)), "ETH");
  console.log("Chain ID:", (await hre.ethers.provider.getNetwork()).chainId);

  // Deploy parameters
  const initialOwner = deployer.address;
  const usdtAddress = process.env.USDT_ADDRESS || USDC_BASE;
  const lpWallet = process.env.LP_WALLET || deployer.address;

  console.log("\n" + "-".repeat(60));
  console.log("Deployment Parameters:");
  console.log("-".repeat(60));
  console.log("Initial Owner:", initialOwner);
  console.log("USDT/USDC Address:", usdtAddress);
  console.log("LP Wallet:", lpWallet);

  // Validate addresses
  if (!hre.ethers.isAddress(usdtAddress)) {
    throw new Error("Invalid USDT address");
  }
  if (!hre.ethers.isAddress(lpWallet)) {
    throw new Error("Invalid LP wallet address");
  }

  console.log("\nDeploying Cyrus contract...");

  // Deploy the Cyrus contract with 3 constructor arguments
  const Cyrus = await hre.ethers.getContractFactory("Cyrus");
  const token = await Cyrus.deploy(initialOwner, usdtAddress, lpWallet);

  await token.waitForDeployment();

  const tokenAddress = await token.getAddress();

  // Get token details
  const name = await token.name();
  const symbol = await token.symbol();
  const totalSupply = await token.totalSupply();
  const decimals = await token.decimals();
  const lpReserve = await token.LP_RESERVE();
  const saleSupply = await token.SALE_SUPPLY();
  const startPrice = await token.START_PRICE();
  const endPrice = await token.END_PRICE();

  console.log("\n" + "=".repeat(60));
  console.log("DEPLOYMENT SUCCESSFUL");
  console.log("=".repeat(60));
  console.log("\nContract Address:", tokenAddress);

  console.log("\n" + "-".repeat(60));
  console.log("Token Details:");
  console.log("-".repeat(60));
  console.log("Name:", name);
  console.log("Symbol:", symbol);
  console.log("Decimals:", decimals);
  console.log("Total Supply:", hre.ethers.formatUnits(totalSupply, decimals), symbol);
  console.log("LP Reserve:", hre.ethers.formatUnits(lpReserve, decimals), symbol, "(minted to LP wallet)");
  console.log("Sale Supply:", hre.ethers.formatUnits(saleSupply, decimals), symbol, "(bonding curve)");

  console.log("\n" + "-".repeat(60));
  console.log("Bonding Curve:");
  console.log("-".repeat(60));
  console.log("Start Price: $" + (Number(startPrice) / 1e6).toFixed(4), "(USDT)");
  console.log("End Price: $" + (Number(endPrice) / 1e6).toFixed(2), "(USDT)");
  console.log("Price Multiplier: 100x");

  console.log("\n" + "-".repeat(60));
  console.log("Contract Verification:");
  console.log("-".repeat(60));
  console.log("Run the following command to verify:");
  console.log(`\nnpx hardhat verify --network ${network} ${tokenAddress} "${initialOwner}" "${usdtAddress}" "${lpWallet}"`);

  console.log("\n" + "-".repeat(60));
  console.log("Links:");
  console.log("-".repeat(60));
  if (network === "base") {
    console.log("Basescan:", `https://basescan.org/address/${tokenAddress}`);
  } else if (network === "baseSepolia") {
    console.log("Basescan:", `https://sepolia.basescan.org/address/${tokenAddress}`);
  }
  console.log("\n" + "=".repeat(60));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
