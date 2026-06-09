// Read-only example — no key required. Reads live Arc testnet state through the SDK.
//   npm i ethers && node example.js
import { ArcAgenticStack, ARC } from "./arc-agentic-stack.js";

const arc = ArcAgenticStack.readOnly();

const stats = await arc.stats();
console.log(`Arc Agentic Stack — chain ${ARC.chainId}`);
console.log(`  obligations opened: ${stats.obligations}`);
console.log(`  streams opened:     ${stats.streams}`);

// Inspect the most recent stream.
if (stats.streams > 0) {
  const s = await arc.getStream(stats.streams);
  console.log(`\nstream #${stats.streams}: ${s.status}`);
  console.log(`  deposit ${s.deposit.usdc} USDC · ${s.streamedPct}% streamed · ${s.withdrawable.usdc} withdrawable`);
}

// To send transactions, construct with a Signer instead:
//   import { ethers } from "ethers";
//   const wallet = new ethers.Wallet(process.env.AGENT_KEY, ArcAgenticStack.provider());
//   const arc = new ArcAgenticStack(wallet);
//   await arc.bond("5");
//   const { id } = await arc.createStream(CLIENT, "2", { durationSeconds: 3600, memo: "work" });
