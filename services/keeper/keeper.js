
import "dotenv/config";

import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  getAddress
} from "viem";

import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";

const rpcUrl = process.env.BASE_RPC_URL;
const keeperKey = process.env.KEEPER_PRIVATE_KEY;
const walletAddress = process.env.DELEGATED_EOA_ADDRESS;

if (!rpcUrl || !keeperKey || !walletAddress) {
  throw new Error("Missing required environment variables");
}

const account = privateKeyToAccount(keeperKey);
const wallet = getAddress(walletAddress);

const abi = parseAbi([
  "function executePayment()",

  "function getSchedule() view returns (bool initialized,bool enabled,uint64 nextPaymentAt,uint64 endTime,uint32 maxPayments,uint32 paymentsMade,address keeper,uint256 maxEthPerPayment,uint256 reserveWei)",

  "function quotePaymentWei() view returns (uint256 amountWei,uint256 price)"
]);

const publicClient = createPublicClient({
  chain: base,
  transport: http(rpcUrl)
});

const walletClient = createWalletClient({
  account,
  chain: base,
  transport: http(rpcUrl)
});

async function main() {
  const schedule = await publicClient.readContract({
    address: wallet,
    abi,
    functionName: "getSchedule"
  });

  const [
    initialized,
    enabled,
    nextPaymentAt,
    endTime,
    maxPayments,
    paymentsMade,
    configuredKeeper,
    maxEthPerPayment,
    reserveWei
  ] = schedule;

  if (!initialized) {
    throw new Error("Payment schedule is not configured");
  }

  if (!enabled) {
    throw new Error("Payment schedule is paused");
  }

  if (
    getAddress(configuredKeeper) !==
    getAddress(account.address)
  ) {
    throw new Error("This account is not the authorized keeper");
  }

  const now = BigInt(Math.floor(Date.now() / 1000));

  if (now < nextPaymentAt) {
    console.log("Payment is not due yet");
    return;
  }

  if (now > endTime || paymentsMade >= maxPayments) {
    console.log("Payment schedule has expired or reached its limit");
    return;
  }

  const [amountWei, price] = await publicClient.readContract({
    address: wallet,
    abi,
    functionName: "quotePaymentWei"
  });

  const balance = await publicClient.getBalance({
    address: wallet
  });

  const requiredBalance = amountWei + reserveWei;

  console.log("Wallet:", wallet);
  console.log("Payment amount in wei:", amountWei.toString());
  console.log("ETH/USD price (8 decimals):", price.toString());
  console.log("Wallet balance:", balance.toString());

  if (amountWei > maxEthPerPayment) {
    throw new Error("Payment exceeds configured ETH limit");
  }

  if (balance < requiredBalance) {
    console.log("Insufficient Base ETH.");
    console.log("The funding service must arrange an authorized deposit.");
    return;
  }

  const hash = await walletClient.writeContract({
    address: wallet,
    abi,
    functionName: "executePayment"
  });

  console.log("Transaction submitted:", hash);

  const receipt = await publicClient.waitForTransactionReceipt({
    hash
  });

  console.log("Transaction status:", receipt.status);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
