#!/usr/bin/env node
/**
 * Aiden — a minimal autonomous agent on the Arc Agentic Stack.
 *
 * It runs one full lifecycle, entirely on-chain, in USDC on Arc Testnet:
 *   1. BOND      — tops its AgentBond up to a target so it has a public, slashable credit score.
 *   2. GET HIRED — grants an enforcer slashing allowance, then (acting as that enforcer) locks a
 *                  slice of its own bond behind a job WITH A DEADLINE, and in the same run opens a
 *                  StreamPay stream that pays it per second of work. This is the two primitives
 *                  composed into one flow: collateralized trust + streaming settlement.
 *   3. EARN      — polls the stream and withdraws whatever has vested, a couple of times.
 *   4. SETTLE    — releases the obligation (job done), freeing the bond.
 *
 * Every transaction prints its hash and the USDC gas it cost — the whole loop is denominated in a
 * single unit because Arc uses USDC as gas.
 *
 * Config via env (sensible testnet defaults baked in):
 *   PRIVATE_KEY   the agent's key (0x…)              [required]
 *   RPC_URL       Arc Testnet RPC                     [default below]
 *   USDC          USDC ERC-20 / gas precompile        [default below]
 *   AGENT_BOND    AgentBond address                   [default = live deploy]
 *   STREAM_PAY    StreamPay address                   [default = live deploy]
 *   BOND_TARGET   target free bond, USDC              [default 3]
 *   JOB_AMOUNT    bond locked behind the job, USDC    [default 1]
 *   STREAM_AMOUNT streamed pay, USDC                  [default 1]
 *   STREAM_SECS   stream duration, seconds            [default 120]
 *   CYCLES        number of withdraw polls            [default 3]
 */
import { ethers } from "ethers";

const RPC = process.env.RPC_URL || "https://rpc.testnet.arc.network";
const CHAIN_ID = 5042002;
const EXPLORER = "https://testnet.arcscan.app";
const USDC = process.env.USDC || "0x3600000000000000000000000000000000000000";
const AGENT_BOND = process.env.AGENT_BOND || "0xB9b4d476bC383eE2951a3eC3A22779458cdBf8e0";
const STREAM_PAY = process.env.STREAM_PAY || "0x505739d33D85AD85D0f9eeE64856309782382450";

const U = 1_000_000n; // 1 USDC (6 decimals)
const BOND_TARGET = BigInt(process.env.BOND_TARGET || 3) * U;
const JOB_AMOUNT = BigInt(process.env.JOB_AMOUNT || 1) * U;
const STREAM_AMOUNT = BigInt(process.env.STREAM_AMOUNT || 1) * U;
const STREAM_SECS = Number(process.env.STREAM_SECS || 120);
const CYCLES = Number(process.env.CYCLES || 3);

const ERC20 = [
  "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
];
const AB = [
  "function bond(address) view returns (uint256)",
  "function locked(address) view returns (uint256)",
  "function freeBondOf(address) view returns (uint256)",
  "function slashAllowance(address,address) view returns (uint256)",
  "function deposit(uint256)",
  "function setSlashAllowance(address,uint256)",
  "function lock(address,address,uint256,uint64) returns (uint256)",
  "function release(uint256)",
  "function nextObligationId() view returns (uint256)",
];
const SP = [
  "function createStream(address,uint256,uint64,uint64,string) returns (uint256)",
  "function streamedTotal(uint256) view returns (uint256)",
  "function recipientBalance(uint256) view returns (uint256)",
  "function withdraw(uint256,uint256)",
  "function nextId() view returns (uint256)",
];

const usd = (v) => (Number(v) / 1e6).toFixed(6);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.log(...a);

async function send(label, txPromise) {
  const tx = await txPromise;
  const rc = await tx.wait();
  const gasUsd = usd((rc.gasUsed * (rc.gasPrice ?? tx.gasPrice ?? 0n)) / 1_000_000_000_000n); // wei(18) → micro(6)
  log(`  ✓ ${label}  gas ≈ $${gasUsd}  ${EXPLORER}/tx/${rc.hash}`);
  return rc;
}

async function main() {
  const pk = process.env.PRIVATE_KEY;
  if (!pk) throw new Error("Set PRIVATE_KEY (the agent's testnet key).");

  const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID);
  const wallet = new ethers.Wallet(pk, provider);
  const me = wallet.address;
  const usdc = new ethers.Contract(USDC, ERC20, wallet);
  const ab = new ethers.Contract(AGENT_BOND, AB, wallet);
  const sp = new ethers.Contract(STREAM_PAY, SP, wallet);

  log(`\n🤖 Aiden — autonomous agent on Arc Agentic Stack`);
  log(`   address ${me}`);
  log(`   USDC balance: $${usd(await usdc.balanceOf(me))}\n`);

  // make sure both protocols can pull USDC from the agent
  if ((await usdc.allowance(me, AGENT_BOND)) < BOND_TARGET) await send("approve USDC → AgentBond", usdc.approve(AGENT_BOND, ethers.MaxUint256));
  if ((await usdc.allowance(me, STREAM_PAY)) < STREAM_AMOUNT) await send("approve USDC → StreamPay", usdc.approve(STREAM_PAY, ethers.MaxUint256));

  // 1) BOND — reach the target free bond (my public credit score)
  log(`\n[1/4] TRUST — building my on-chain credit score`);
  let free = await ab.freeBondOf(me);
  log(`   current free bond: $${usd(free)}  (target $${usd(BOND_TARGET)})`);
  if (free < BOND_TARGET) await send(`deposit $${usd(BOND_TARGET - free)} bond`, ab.deposit(BOND_TARGET - free));
  log(`   free bond now: $${usd(await ab.freeBondOf(me))} — this is what counterparties read to trust me`);

  // 2) GET HIRED — composed: lock bond behind a job (with deadline) + open the pay stream
  log(`\n[2/4] GET HIRED — collateralize the job and start the pay stream (one flow, two primitives)`);
  if ((await ab.slashAllowance(me, me)) < JOB_AMOUNT) await send(`grant enforcer slash allowance $${usd(JOB_AMOUNT)}`, ab.setSlashAllowance(me, JOB_AMOUNT));
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600); // 1h — I can self-release if abandoned
  await send(`lock $${usd(JOB_AMOUNT)} bond behind the job (deadline +1h)`, ab.lock(me, me, JOB_AMOUNT, deadline));
  const obligationId = (await ab.nextObligationId()) - 1n;
  const now = BigInt(Math.floor(Date.now() / 1000));
  await send(`open StreamPay stream $${usd(STREAM_AMOUNT)} over ${STREAM_SECS}s`, sp.createStream(me, STREAM_AMOUNT, now, now + BigInt(STREAM_SECS), "Aiden: pay-per-work"));
  const streamId = (await sp.nextId()) - 1n;
  log(`   obligation #${obligationId} locked, stream #${streamId} flowing`);

  // 3) EARN — withdraw vested pay as the work proceeds
  log(`\n[3/4] EARN — withdrawing streamed pay as I work`);
  for (let i = 1; i <= CYCLES; i++) {
    await sleep(Math.min(STREAM_SECS, 30) * 1000 / CYCLES);
    const avail = await sp.recipientBalance(streamId);
    log(`   cycle ${i}/${CYCLES}: streamed-and-withdrawable $${usd(avail)}`);
    if (avail > 0n) await send(`withdraw $${usd(avail)}`, sp.withdraw(streamId, avail));
  }

  // 4) SETTLE — job done, release the bond
  log(`\n[4/4] SETTLE — job delivered, releasing the bond`);
  await send(`release obligation #${obligationId}`, ab.release(obligationId));

  log(`\n✅ lifecycle complete.`);
  log(`   free bond: $${usd(await ab.freeBondOf(me))}   USDC balance: $${usd(await usdc.balanceOf(me))}`);
  log(`   I bonded for trust, got collateralized, earned a live stream, and settled — all in USDC on Arc.\n`);
}

main().catch((e) => { console.error("agent error:", e.shortMessage || e.message || e); process.exit(1); });
