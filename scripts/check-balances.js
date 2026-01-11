#!/usr/bin/env node
/**
 * Check ETH balances across all derived accounts
 */

require("dotenv").config();
const { ethers } = require("ethers");

const RPC_URL = process.env.BASE_RPC_URL || "https://mainnet.base.org";
const MNEMONIC = process.env.MNEMONIC;
const MAX_ACCOUNTS = parseInt(process.argv[2]) || 100;

async function main() {
  if (!MNEMONIC) {
    console.error("ERROR: MNEMONIC not set");
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(RPC_URL);

  console.log(`Checking balances for accounts 0-${MAX_ACCOUNTS - 1}...\n`);

  let totalBalance = BigInt(0);
  const accountsWithBalance = [];

  for (let i = 0; i < MAX_ACCOUNTS; i++) {
    const path = `m/44'/60'/0'/0/${i}`;
    const hdNode = ethers.HDNodeWallet.fromPhrase(MNEMONIC, "", path);

    try {
      const balance = await provider.getBalance(hdNode.address);

      if (balance > 0) {
        accountsWithBalance.push({ index: i, address: hdNode.address, balance });
        totalBalance += balance;
        console.log(`Account ${i}: ${hdNode.address} = ${ethers.formatEther(balance)} ETH`);
      }

      // Progress indicator every 50 accounts
      if ((i + 1) % 50 === 0) {
        process.stdout.write(`Checked ${i + 1} accounts...\r`);
      }
    } catch (error) {
      console.error(`Error checking account ${i}: ${error.message}`);
      // Add delay on rate limit
      await new Promise(r => setTimeout(r, 1000));
    }
  }

  console.log(`\n\n=== SUMMARY ===`);
  console.log(`Accounts checked: ${MAX_ACCOUNTS}`);
  console.log(`Accounts with balance: ${accountsWithBalance.length}`);
  console.log(`Total ETH: ${ethers.formatEther(totalBalance)} ETH`);

  if (accountsWithBalance.length > 0) {
    console.log(`\nAccounts with ETH:`);
    accountsWithBalance.forEach(acc => {
      console.log(`  ${acc.index}: ${acc.address} = ${ethers.formatEther(acc.balance)} ETH`);
    });
  }
}

main().catch(console.error);
