const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();

  console.log("=".repeat(60));
  console.log("LOCAL DEPLOYMENT - Anvil");
  console.log("=".repeat(60));
  console.log("\nDeployer:", deployer.address);
  console.log("Balance:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)), "ETH");

  // 1. Deploy Mock USDT
  console.log("\n1. Deploying Mock USDT...");
  const MockUSDT = await hre.ethers.getContractFactory("MockUSDT");
  const usdt = await MockUSDT.deploy();
  await usdt.waitForDeployment();
  const usdtAddress = await usdt.getAddress();
  console.log("   Mock USDT deployed to:", usdtAddress);

  // Mint some USDT to deployer for testing
  await usdt.faucet();
  console.log("   Minted 10,000 USDT to deployer");

  // 2. Deploy Cyrus
  console.log("\n2. Deploying Cyrus...");
  const Cyrus = await hre.ethers.getContractFactory("Cyrus");
  const cyrus = await Cyrus.deploy(deployer.address, usdtAddress, deployer.address);
  await cyrus.waitForDeployment();
  const cyrusAddress = await cyrus.getAddress();
  console.log("   Cyrus deployed to:", cyrusAddress);

  // Display token info
  const startPrice = await cyrus.START_PRICE();
  const endPrice = await cyrus.END_PRICE();
  const lpReserve = await cyrus.LP_RESERVE();
  const saleSupply = await cyrus.SALE_SUPPLY();

  console.log("\n" + "=".repeat(60));
  console.log("DEPLOYMENT COMPLETE");
  console.log("=".repeat(60));
  console.log("\nContract Addresses (for wagmi.ts):");
  console.log("-".repeat(60));
  console.log(`export const USDT_ADDRESS = '${usdtAddress}' as const`);
  console.log(`export const CYRUS_ADDRESS = '${cyrusAddress}' as const`);
  console.log("\nBonding Curve:");
  console.log("-".repeat(60));
  console.log("Start Price: $" + (Number(startPrice) / 1e6).toFixed(4));
  console.log("End Price: $" + (Number(endPrice) / 1e6).toFixed(2));
  console.log("LP Reserve:", hre.ethers.formatUnits(lpReserve, 18), "CYRUS");
  console.log("Sale Supply:", hre.ethers.formatUnits(saleSupply, 18), "CYRUS");

  // Test accounts (Anvil default accounts with 10000 ETH each)
  console.log("\n" + "=".repeat(60));
  console.log("TEST ACCOUNTS (Anvil defaults)");
  console.log("=".repeat(60));
  console.log("\nAccount 0 (deployer):");
  console.log("Address:", deployer.address);
  console.log("Private Key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
  console.log("\nImport this private key into MetaMask to test!");
  console.log("\n" + "=".repeat(60));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
