#!/usr/bin/env node
/**
 * Autonomous buyer agent for the x402 pay-per-inference demo.
 *
 * It pays per API call, on-chain, with no human in the loop:
 *   1. Calls GET /inference and gets a 402 with machine-readable payment terms.
 *   2. Parses the terms, opens a StreamPay micro-stream to the server's payTo address
 *      (real Arc tx). This is its "wallet of intent": it commits a small budget that
 *      streams per second.
 *   3. Polls the endpoint a few times with ?stream=<id>; each 200 means the server pulled
 *      the seconds vested since the last call. The agent prints the result + settlement tx.
 *   4. Cancels the stream to reclaim the unspent remainder (real Arc tx) — clean lifecycle.
 *
 * Env:
 *   AGENT_PRIVATE_KEY  the buyer agent's key (0x…)              [required]
 *   RPC_URL            Arc Testnet RPC                          [default below]
 *   USDC               USDC ERC-20 / gas precompile             [default below]
 *   STREAM_PAY         StreamPay address                        [default = live USDC deploy]
 *   SERVER_URL         base URL of the x402 server              [default http://localhost:4021]
 *   DEPOSIT_USDC       stream budget                            [default 0.30]
 *   STREAM_SECS        stream duration seconds                  [default 30]
 *   CALLS              number of paid calls                     [default 3]
 */
import { ethers } from "ethers";

const RPC = process.env.RPC_URL || "https://rpc.testnet.arc.network";
const CHAIN_ID = 5042002;
const EXPLORER = "https://testnet.arcscan.app";
const USDC = process.env.USDC || "0x3600000000000000000000000000000000000000";
const STREAM_PAY = process.env.STREAM_PAY || "0x505739d33D85AD85D0f9eeE64856309782382450";
const SERVER_URL = process.env.SERVER_URL || "http://localhost:4021";
const U = 1_000_000n;
const DEPOSIT = BigInt(Math.round(Number(process.env.DEPOSIT_USDC || 0.30) * 1e6));
const STREAM_SECS = Number(process.env.STREAM_SECS || 60);
const CALLS = Number(process.env.CALLS || 3);

const ERC20 = [
  "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
];
const SP = [
  "function createStream(address,uint256,uint64,uint64,string) returns (uint256)",
  "function recipientBalance(uint256) view returns (uint256)",
  "function senderBalance(uint256) view returns (uint256)",
  "function get(uint256) view returns (tuple(address sender,address recipient,uint256 deposit,uint256 withdrawn,uint64 start,uint64 stop,uint8 status))",
  "function nextId() view returns (uint256)",
  "function cancel(uint256)",
];

const usd = (v) => (Number(v) / 1e6).toFixed(6);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.log(...a);

async function send(label, txPromise) {
  const tx = await txPromise;
  const rc = await tx.wait();
  const gasUsd = usd((rc.gasUsed * (rc.gasPrice ?? tx.gasPrice ?? 0n)) / 1_000_000_000_000n);
  log(`   ✓ ${label}  gas ≈ $${gasUsd}  ${EXPLORER}/tx/${rc.hash}`);
  return rc;
}

async function main() {
  const pk = process.env.AGENT_PRIVATE_KEY;
  if (!pk) throw new Error("Set AGENT_PRIVATE_KEY (the buyer agent's testnet key).");

  const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID);
  const wallet = new ethers.Wallet(pk, provider);
  const me = wallet.address;
  const usdc = new ethers.Contract(USDC, ERC20, wallet);
  const sp = new ethers.Contract(STREAM_PAY, SP, wallet);

  log(`\n🤖 Buyer agent — pays per inference call on Arc, no human in the loop`);
  log(`   address ${me}`);
  log(`   USDC balance: $${usd(await usdc.balanceOf(me))}\n`);

  // 1) Probe the endpoint with no payment -> expect 402 + terms.
  log(`[1/4] CALL — hitting ${SERVER_URL}/inference with no payment`);
  const probe = await fetch(`${SERVER_URL}/inference?prompt=${encodeURIComponent("classify: arc is a stablecoin L1")}`);
  if (probe.status !== 402) throw new Error(`expected 402, got ${probe.status}`);
  const terms = (await probe.json()).x402;
  log(`   ← HTTP 402 Payment Required`);
  log(`     scheme=${terms.scheme} asset=${terms.asset} payTo=${terms.payTo}`);
  log(`     ${terms.instructions}`);
  const payTo = ethers.getAddress(terms.payTo);

  // 2) Open the StreamPay micro-stream off those terms.
  log(`\n[2/4] PAY — opening a StreamPay stream: $${usd(DEPOSIT)} over ${STREAM_SECS}s -> ${payTo}`);
  if ((await usdc.allowance(me, STREAM_PAY)) < DEPOSIT) await send("approve USDC → StreamPay", usdc.approve(STREAM_PAY, ethers.MaxUint256));
  const now = BigInt(Math.floor(Date.now() / 1000));
  await send(`createStream`, sp.createStream(payTo, DEPOSIT, now, now + BigInt(STREAM_SECS), "x402 pay-per-inference"));
  const streamId = (await sp.nextId()) - 1n;
  log(`   stream #${streamId} flowing at $${usd(DEPOSIT / BigInt(STREAM_SECS))}/s`);

  // 3) Poll the paid endpoint; each 200 = server pulled the seconds vested since last call.
  log(`\n[3/4] CONSUME — paid calls (server settles per call from the stream)`);
  // Poll at a fixed short interval, independent of the stream length, so the agent only
  // spends for the seconds it actually used and a real remainder is left to reclaim.
  const gap = Number(process.env.POLL_MS || 5000);
  for (let i = 1; i <= CALLS; i++) {
    await sleep(gap);
    const r = await fetch(`${SERVER_URL}/inference?prompt=${encodeURIComponent(`call ${i}: summarize x402`)}&stream=${streamId}`);
    const body = await r.json();
    if (r.status === 200) {
      log(`   call ${i}: 200 — settled $${body.payment.settledUSDC}  ${body.payment.explorer}`);
      log(`            → "${body.result.completion}"`);
    } else {
      log(`   call ${i}: ${r.status} — ${body.reason || body.error} (vested $${body.vested ?? "?"})`);
    }
  }

  // 4) Reclaim the unspent remainder. Clean lifecycle.
  log(`\n[4/4] SETTLE — cancelling the stream to reclaim the unspent budget`);
  const st = await sp.get(streamId);
  if (Number(st.status) !== 1) {
    log(`   stream #${streamId} already terminal — fully consumed, nothing to reclaim.`);
  } else {
    const reclaim = await sp.senderBalance(streamId);
    log(`   reclaimable (unused budget): $${usd(reclaim)}`);
    await send(`cancel stream #${streamId}`, sp.cancel(streamId));
  }

  log(`\n✅ done. Paid per call, on-chain, autonomously. USDC balance: $${usd(await usdc.balanceOf(me))}`);
  log(`   The 402→200 gate was bound to a live StreamPay settlement on Arc.\n`);
}

main().catch((e) => { console.error("agent error:", e.shortMessage || e.message || e); process.exit(1); });
