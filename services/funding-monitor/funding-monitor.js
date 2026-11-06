
import "dotenv/config";

import {
  createPublicClient,
  http,
  formatEther,
  getAddress
} from "viem";

import { base } from "viem/chains";

const rpcUrl = process.env.BASE_RPC_URL;
const walletAddress = process.env.DELEGATED_EOA_ADDRESS;

if (!rpcUrl || !walletAddress) {
  throw new Error("Missing BASE_RPC_URL or DELEGATED_EOA_ADDRESS");
}

const client = createPublicClient({
  chain: base,
  transport: http(rpcUrl)
});

const wallet = getAddress(walletAddress);

async function checkBalance() {
  const balance = await client.getBalance({
    address: wallet
  });

  console.log("Delegated EOA:", wallet);
  console.log("Base ETH balance:", formatEther(balance), "ETH");

  if (balance === 0n) {
    console.log("Wallet has no Base ETH.");
  } else {
    console.log("Wallet has a Base ETH balance.");
  }

  console.log(
    "Funding actions are read-only. No exchange purchase or withdrawal was made."
  );
}

checkBalance().catch(console.error);
