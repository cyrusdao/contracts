#!/usr/bin/env node
/**
 * CYRUS Auto-Mint Script
 *
 * Runs in background, continuously minting from new accounts derived from MNEMONIC.
 * Each account mints once, then transfers remaining ETH to next account.
 *
 * Usage:
 *   node scripts/auto-mint.js
 *
 * Environment variables (.env):
 *   MNEMONIC - BIP39 mnemonic phrase
 *   BASE_RPC_URL - Base mainnet RPC URL (default: https://mainnet.base.org)
 *
 * The script will:
 *   1. Start from account index 0
 *   2. Check if account has minted (hasMinted mapping)
 *   3. If not minted, call freeMint()
 *   4. Transfer remaining ETH (minus buffer) to next account
 *   5. Move to next account index
 *   6. Repeat forever
 */

require("dotenv").config();
const { ethers } = require("ethers");

// Contract details
const CYRUS_ADDRESS = "0xA7de8462a852eBA2C9b4A3464C8fC577cb7090b8";
const CYRUS_ABI = [
  "function freeMint() external",
  "function hasMinted(address) view returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "event FreeMint(address indexed recipient, uint256 amount)"
];

// Configuration
const RPC_URL = process.env.BASE_RPC_URL || "https://mainnet.base.org";
const MNEMONIC = process.env.MNEMONIC;
const GAS_BUFFER = ethers.parseEther("0.000005"); // Minimal buffer - sweep nearly everything
const MIN_GAS_FOR_MINT = ethers.parseEther("0.00005"); // Minimum ETH needed to mint
const DELAY_BETWEEN_MINTS = 5000; // 5 seconds between operations (rate limit protection)

// State tracking - start from CLI arg or default
const START_INDEX = parseInt(process.argv[2]) || 12;
let currentIndex = START_INDEX;
let totalMinted = 0;
let startTime = Date.now();

// Statistics
const stats = {
  successful: 0,
  skipped: 0,
  failed: 0,
  totalGasUsed: BigInt(0)
};

function log(message, level = "INFO") {
  const timestamp = new Date().toISOString();
  const uptime = Math.floor((Date.now() - startTime) / 1000);
  console.log(`[${timestamp}] [${level}] [${uptime}s] ${message}`);
}

function getWallet(index, provider) {
  const path = `m/44'/60'/0'/0/${index}`;
  const hdNode = ethers.HDNodeWallet.fromPhrase(MNEMONIC, "", path);
  return hdNode.connect(provider);
}

async function checkAndMint(wallet, contract, index) {
  const address = wallet.address;

  // Check if already minted
  const hasMinted = await contract.hasMinted(address);
  if (hasMinted) {
    log(`Account ${index} (${address}) already minted, skipping`, "SKIP");
    stats.skipped++;
    return false;
  }

  // Check balance
  const balance = await wallet.provider.getBalance(address);
  if (balance < MIN_GAS_FOR_MINT) {
    log(`Account ${index} (${address}) has insufficient balance: ${ethers.formatEther(balance)} ETH`, "WARN");
    return null; // Signal to fund this account
  }

  // Estimate gas
  try {
    const gasEstimate = await contract.freeMint.estimateGas();
    const feeData = await wallet.provider.getFeeData();
    const gasPrice = feeData.gasPrice || ethers.parseUnits("0.1", "gwei");
    const estimatedCost = gasEstimate * gasPrice;

    log(`Account ${index} (${address}) - Balance: ${ethers.formatEther(balance)} ETH, Est. cost: ${ethers.formatEther(estimatedCost)} ETH`);

    // Execute mint
    log(`Minting for account ${index} (${address})...`);
    const tx = await contract.freeMint({
      gasLimit: gasEstimate * BigInt(120) / BigInt(100), // 20% buffer
    });

    log(`Transaction sent: ${tx.hash}`);
    const receipt = await tx.wait();

    if (receipt.status === 1) {
      const gasUsed = receipt.gasUsed * receipt.gasPrice;
      stats.successful++;
      stats.totalGasUsed += gasUsed;
      totalMinted++;

      log(`✅ Mint successful! Gas used: ${ethers.formatEther(gasUsed)} ETH | Total minted: ${totalMinted}`, "SUCCESS");
      return true;
    } else {
      log(`❌ Transaction failed for account ${index}`, "ERROR");
      stats.failed++;
      return false;
    }
  } catch (error) {
    if (error.message.includes("Already minted")) {
      log(`Account ${index} already minted (caught in tx)`, "SKIP");
      stats.skipped++;
      return false;
    }
    log(`Error minting for account ${index}: ${error.message}`, "ERROR");
    stats.failed++;
    return false;
  }
}

async function transferToNext(fromWallet, toAddress) {
  const balance = await fromWallet.provider.getBalance(fromWallet.address);

  if (balance <= GAS_BUFFER) {
    log(`No funds to transfer from ${fromWallet.address}`, "INFO");
    return;
  }

  // Estimate transfer cost
  const feeData = await fromWallet.provider.getFeeData();
  const gasPrice = feeData.gasPrice || ethers.parseUnits("0.1", "gwei");
  const gasLimit = BigInt(21000);
  const transferCost = gasLimit * gasPrice;

  const amountToSend = balance - transferCost - GAS_BUFFER;

  if (amountToSend <= 0) {
    log(`Insufficient balance to transfer after gas costs`, "WARN");
    return;
  }

  log(`Transferring ${ethers.formatEther(amountToSend)} ETH from account to ${toAddress}`);

  try {
    const tx = await fromWallet.sendTransaction({
      to: toAddress,
      value: amountToSend,
      gasLimit: gasLimit,
    });

    await tx.wait();
    log(`Transfer complete: ${tx.hash}`, "SUCCESS");
  } catch (error) {
    log(`Transfer failed: ${error.message}`, "ERROR");
  }
}

async function printStats() {
  const runtime = Math.floor((Date.now() - startTime) / 1000);
  const hours = Math.floor(runtime / 3600);
  const minutes = Math.floor((runtime % 3600) / 60);
  const seconds = runtime % 60;

  console.log("\n" + "=".repeat(60));
  console.log("📊 AUTO-MINT STATISTICS");
  console.log("=".repeat(60));
  console.log(`Runtime: ${hours}h ${minutes}m ${seconds}s`);
  console.log(`Started from index: ${START_INDEX} | Current: ${currentIndex}`);
  console.log(`Successful mints: ${stats.successful}`);
  console.log(`Skipped (already minted): ${stats.skipped}`);
  console.log(`Failed: ${stats.failed}`);
  console.log(`Total gas used: ${ethers.formatEther(stats.totalGasUsed)} ETH`);
  console.log(`Mint rate: ${(stats.successful / (runtime / 60)).toFixed(2)} mints/min`);
  console.log("=".repeat(60) + "\n");
}

async function main() {
  // Validate environment
  if (!MNEMONIC) {
    console.error("ERROR: MNEMONIC not set in .env file");
    process.exit(1);
  }

  log("🚀 Starting CYRUS Auto-Mint Script");
  log(`RPC: ${RPC_URL}`);
  log(`Contract: ${CYRUS_ADDRESS}`);
  log(`Starting from account index: ${START_INDEX}`);

  // Setup provider
  const provider = new ethers.JsonRpcProvider(RPC_URL);

  // Test connection
  try {
    const network = await provider.getNetwork();
    log(`Connected to chain ID: ${network.chainId}`);

    if (network.chainId !== BigInt(8453)) {
      log("WARNING: Not connected to Base mainnet (chain ID 8453)!", "WARN");
    }
  } catch (error) {
    console.error("Failed to connect to RPC:", error.message);
    process.exit(1);
  }

  // Check starting account balance
  const startWallet = getWallet(START_INDEX, provider);
  const startBalance = await provider.getBalance(startWallet.address);
  log(`Starting account ${START_INDEX} (${startWallet.address}) balance: ${ethers.formatEther(startBalance)} ETH`);

  if (startBalance < MIN_GAS_FOR_MINT) {
    log(`Account ${START_INDEX} needs funding! Send ETH to: ` + startWallet.address, "WARN");
  }

  // Print stats every 5 minutes
  setInterval(printStats, 5 * 60 * 1000);

  // Handle graceful shutdown
  process.on("SIGINT", () => {
    log("\n🛑 Shutting down...");
    printStats();
    process.exit(0);
  });

  // Main loop
  while (true) {
    try {
      const wallet = getWallet(currentIndex, provider);
      const contract = new ethers.Contract(CYRUS_ADDRESS, CYRUS_ABI, wallet);

      log(`\n--- Processing account ${currentIndex} (${wallet.address}) ---`);

      const result = await checkAndMint(wallet, contract, currentIndex);

      if (result === null) {
        // Need to fund this account from previous
        if (currentIndex > START_INDEX) {
          const prevWallet = getWallet(currentIndex - 1, provider);
          await transferToNext(prevWallet, wallet.address);

          // Retry mint after funding
          await new Promise(resolve => setTimeout(resolve, 2000));
          await checkAndMint(wallet, contract, currentIndex);
        } else {
          log(`Account ${START_INDEX} needs manual funding!`, "ERROR");
          await new Promise(resolve => setTimeout(resolve, 30000)); // Wait 30s before retry
          continue;
        }
      }

      // Transfer remaining funds to next account
      const nextWallet = getWallet(currentIndex + 1, provider);
      await transferToNext(wallet, nextWallet.address);

      // Move to next account
      currentIndex++;

      // Delay between operations
      await new Promise(resolve => setTimeout(resolve, DELAY_BETWEEN_MINTS));

    } catch (error) {
      // Handle rate limits gracefully
      if (error.message.includes("rate limit") || error.info?.error?.code === -32016) {
        log(`Rate limited, waiting 30s...`, "WARN");
        await new Promise(resolve => setTimeout(resolve, 30000));
        continue; // Retry same account
      }

      log(`Unexpected error: ${error.message}`, "ERROR");
      console.error(error);

      // Wait before retrying
      await new Promise(resolve => setTimeout(resolve, 15000));
    }
  }
}

// Run
main().catch(console.error);
