#!/usr/bin/env node
/**
 * Consolidate ETH from multiple accounts into a target account
 */

require("dotenv").config();
const { ethers } = require("ethers");

const RPC_URL = process.env.BASE_RPC_URL || "https://mainnet.base.org";
const MNEMONIC = process.env.MNEMONIC;

const FROM_START = parseInt(process.argv[2]) || 0;
const FROM_END = parseInt(process.argv[3]) || 11;
const TO_INDEX = parseInt(process.argv[4]) || 1089;

function getWallet(index, provider) {
  const path = `m/44'/60'/0'/0/${index}`;
  const hdNode = ethers.HDNodeWallet.fromPhrase(MNEMONIC, "", path);
  return hdNode.connect(provider);
}

async function main() {
  if (!MNEMONIC) {
    console.error("ERROR: MNEMONIC not set");
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const targetWallet = getWallet(TO_INDEX, provider);

  console.log(`Consolidating accounts ${FROM_START}-${FROM_END} into account ${TO_INDEX}`);
  console.log(`Target address: ${targetWallet.address}\n`);

  let totalSent = BigInt(0);
  let successCount = 0;

  // Base L2 has L1 data fees. Reserve enough for gas + L1 data fee
  const gasBuffer = ethers.parseEther("0.0000004"); // ~400 gwei buffer for L1 data fee + gas

  console.log(`Gas buffer: ${ethers.formatEther(gasBuffer)} ETH\n`);

  for (let i = FROM_START; i <= FROM_END; i++) {
    const wallet = getWallet(i, provider);
    const balance = await provider.getBalance(wallet.address);

    if (balance === BigInt(0)) {
      console.log(`Account ${i}: No balance, skipping`);
      continue;
    }

    const amountToSend = balance - gasBuffer;

    if (amountToSend <= 0) {
      console.log(`Account ${i}: Balance ${ethers.formatEther(balance)} ETH too low for gas`);
      continue;
    }

    console.log(`Account ${i}: Sending ${ethers.formatEther(amountToSend)} ETH (bal: ${ethers.formatEther(balance)})...`);

    try {
      const tx = await wallet.sendTransaction({
        to: targetWallet.address,
        value: amountToSend,
      });

      const receipt = await tx.wait();
      totalSent += amountToSend;
      successCount++;
      console.log(`  ✅ Success: ${tx.hash}`);
    } catch (error) {
      console.log(`  ❌ Failed: ${error.message}`);
    }

    // Small delay between transactions
    await new Promise(r => setTimeout(r, 500));
  }

  // Check final balance
  const finalBalance = await provider.getBalance(targetWallet.address);

  console.log(`\n=== CONSOLIDATION COMPLETE ===`);
  console.log(`Accounts processed: ${FROM_END - FROM_START + 1}`);
  console.log(`Successful transfers: ${successCount}`);
  console.log(`Total ETH sent: ${ethers.formatEther(totalSent)} ETH`);
  console.log(`Account ${TO_INDEX} final balance: ${ethers.formatEther(finalBalance)} ETH`);
}

main().catch(console.error);
