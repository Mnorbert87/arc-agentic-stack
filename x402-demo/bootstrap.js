#!/usr/bin/env node
/**
 * One-time setup: make sure the server wallet (payee) holds enough USDC to pay its own
 * gas for withdraw() txs. Funds it from the agent (payer) burner if it is low.
 * USDC is the gas token on Arc, so "gas money" and "USDC balance" are the same thing.
 */
import { ethers } from "ethers";

const RPC = process.env.RPC_URL || "https://rpc.testnet.arc.network";
const CHAIN_ID = 5042002;
const MIN = ethers.parseUnits(process.env.SERVER_MIN_USDC || "0.5", 18); // native gas units (18-dec)
const TOPUP = ethers.parseUnits(process.env.SERVER_TOPUP_USDC || "0.6", 18);

async function main() {
  const apk = process.env.AGENT_PRIVATE_KEY, spk = process.env.SERVER_PRIVATE_KEY;
  if (!apk || !spk) throw new Error("Set AGENT_PRIVATE_KEY and SERVER_PRIVATE_KEY.");
  const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID);
  const agent = new ethers.Wallet(apk, provider);
  const serverAddr = new ethers.Wallet(spk).address;

  const bal = await provider.getBalance(serverAddr);
  console.log(`server ${serverAddr} gas/USDC balance: ${ethers.formatEther(bal)}`);
  if (bal >= MIN) { console.log("server funded, skipping top-up."); return; }

  console.log(`funding server with ${ethers.formatEther(TOPUP)} USDC from agent ${agent.address}…`);
  const tx = await agent.sendTransaction({ to: serverAddr, value: TOPUP });
  const rc = await tx.wait();
  console.log(`  ✓ funded  https://testnet.arcscan.app/tx/${rc.hash}`);
}

main().catch((e) => { console.error("bootstrap error:", e.shortMessage || e.message || e); process.exit(1); });
