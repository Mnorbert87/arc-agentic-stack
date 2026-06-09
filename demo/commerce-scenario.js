// Arc Agentic Stack — end-to-end commerce scenario: "Hire an AI service agent."
//
// A concrete, named, money-moving flow that turns the two primitives into a product:
//
//   Acme Corp (buyer)  hires  Aiden (an AI research agent)  to deliver a report.
//
//   1. Aiden posts a USDC bond              — skin-in-the-game behind its reputation.   [AgentBond]
//   2. Aiden grants Acme slashing rights    — Acme may lock/slash that bond.            [AgentBond]
//   3. Acme locks a guarantee on the job    — an obligation: perform, or the bond pays. [AgentBond]
//   4. Acme opens a pay-per-second stream   — Aiden earns USDC as the work lands.       [StreamPay]
//   5. Aiden withdraws streamed earnings    — paid for delivered work, no invoice.      [StreamPay]
//   6. Settle: report accepted              — stream finishes, obligation released.     [both]
//
// Reuses the already-deployed contracts (no new deploys). All value is real testnet USDC.
//
//   DRY_RUN (default): prints the full plan + amounts, sends NO transactions. Safe anytime.
//   LIVE=1:            runs it on Arc testnet. Needs PRIVATE_KEY = a funded burner (it plays
//                      Aiden and also seeds an ephemeral Acme wallet with gas+budget USDC).
//
//   npm i ethers
//   node commerce-scenario.js            # dry run — see the script of the demo
//   PRIVATE_KEY=0x... LIVE=1 node commerce-scenario.js
//
// The burner key is read from env only, never logged or written. Acme's key is generated
// fresh at runtime and discarded — it never leaves this process.
import { ethers } from "ethers";
import { ArcAgenticStack, ARC } from "../sdk/arc-agentic-stack.js";

// --- scenario parameters (real USDC) ---------------------------------------
const JOB = {
  title: "Market-research report on stablecoin payment rails",
  budget: "0.60", // USDC streamed to Aiden over the work window
  guarantee: "0.50", // USDC of Aiden's bond Acme locks as a performance guarantee
  windowSeconds: 60, // the streaming work window (short, so the demo settles live)
  acmeFunding: "1.40", // USDC the buyer wallet needs: stream budget + gas for its txs
};

const LIVE = process.env.LIVE === "1";
const c = {
  // tiny ANSI helpers; no dependency
  dim: (s) => `\x1b[2m${s}\x1b[0m`,
  b: (s) => `\x1b[1m${s}\x1b[0m`,
  cyan: (s) => `\x1b[36m${s}\x1b[0m`,
  gold: (s) => `\x1b[33m${s}\x1b[0m`,
  green: (s) => `\x1b[32m${s}\x1b[0m`,
};
const tx = (h) => c.dim(`${ARC.explorer}/tx/${h}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function header() {
  console.log(c.b("\n  Arc Agentic Stack — commerce scenario: \"Hire an AI service agent\"\n"));
  console.log(`  ${c.gold("Acme Corp")} (buyer) hires ${c.cyan("Aiden")} (AI research agent) on Arc, settled in USDC.`);
  console.log(`  Job:       ${JOB.title}`);
  console.log(`  Budget:    ${JOB.budget} USDC streamed over ${JOB.windowSeconds}s of work`);
  console.log(`  Guarantee: ${JOB.guarantee} USDC of Aiden's bond locked behind the job`);
  console.log(`  Contracts: AgentBond ${c.dim(ARC.contracts.AgentBond)}`);
  console.log(`             StreamPay ${c.dim(ARC.contracts.StreamPay)}`);
  console.log(c.dim(`             chain ${ARC.chainId} · ${LIVE ? "LIVE — real testnet transactions" : "DRY RUN — no transactions sent"}\n`));
}

function step(n, who, what) {
  console.log(`  ${c.b(`[${n}]`)} ${who}  ${what}`);
}

async function dryRun() {
  header();
  step(1, c.cyan("Aiden  "), `bond(${JOB.guarantee}) — posts USDC so it has a slashable reputation.`);
  step(2, c.cyan("Aiden  "), `setSlashAllowance(Acme, ${JOB.guarantee}) — lets Acme enforce the job.`);
  step(3, c.gold("Acme   "), `lock(Aiden, Acme, ${JOB.guarantee}, +1h) — opens the obligation.`);
  step(4, c.gold("Acme   "), `createStream(Aiden, ${JOB.budget}, ${JOB.windowSeconds}s) — pay-per-second begins.`);
  step("…", c.dim("(work)"), c.dim(`Aiden delivers; USDC accrues second by second.`));
  step(5, c.cyan("Aiden  "), `withdraw(stream) — pulls the streamed-so-far earnings.`);
  step(6, c.gold("Acme   "), `release(obligation) — report accepted, guarantee returned.`);
  console.log(c.green("\n  Happy path: Aiden is paid for delivered work; its bond is freed and its reputation grows."));
  console.log(c.dim("  Default path (not run here): if Aiden defaults, Acme calls slash() and the bond pays Acme instead.\n"));
  console.log(c.dim("  Re-run with LIVE=1 and a funded PRIVATE_KEY to execute this on Arc testnet.\n"));
}

async function live() {
  const key = process.env.PRIVATE_KEY;
  if (!key) throw new Error("LIVE=1 needs PRIVATE_KEY (a funded Arc testnet burner).");

  const provider = ArcAgenticStack.provider();
  const aiden = new ethers.Wallet(key, provider); // the funded burner plays the agent
  const acme = ethers.Wallet.createRandom().connect(provider); // fresh buyer wallet, discarded after

  header();
  console.log(`  ${c.cyan("Aiden")} = ${aiden.address}`);
  console.log(`  ${c.gold("Acme")}  = ${acme.address} ${c.dim("(ephemeral; funded by Aiden for the demo)")}\n`);

  const arcAiden = new ArcAgenticStack(aiden);
  const arcAcme = new ArcAgenticStack(acme);
  const hashes = {};

  // 0. Seed the buyer wallet. On Arc, USDC *is* the gas token, so one native USDC transfer
  //    funds both Acme's gas and the stream budget it will lock.
  step(0, c.gold("Acme   "), `funded with ${JOB.acmeFunding} USDC (gas + stream budget) by Aiden…`);
  const fund = await aiden.sendTransaction({
    to: acme.address,
    value: ethers.parseEther(JOB.acmeFunding), // native USDC has 18 decimals on Arc
  });
  await fund.wait();
  hashes.fund = fund.hash;
  console.log(`        ${tx(fund.hash)}`);

  // 1. Aiden posts (tops up) its bond so it has at least `guarantee` free.
  const free = await arcAiden.freeBondOf(aiden.address);
  if (parseFloat(free.usdc) < parseFloat(JOB.guarantee)) {
    step(1, c.cyan("Aiden  "), `bond(${JOB.guarantee}) — posting reputation collateral…`);
    const r = await arcAiden.bond(JOB.guarantee);
    hashes.bond = r.hash;
    console.log(`        ${tx(r.hash)}`);
  } else {
    step(1, c.cyan("Aiden  "), `already holds ${free.usdc} USDC free bond — reusing it as collateral.`);
  }

  // 2. Aiden grants Acme the right to lock/slash up to `guarantee`.
  step(2, c.cyan("Aiden  "), `setSlashAllowance(Acme, ${JOB.guarantee}) — opting Acme in as enforcer…`);
  const allow = await arcAiden.setSlashAllowance(acme.address, JOB.guarantee);
  hashes.allowance = allow.hash;
  console.log(`        ${tx(allow.hash)}`);

  // 3. Acme locks the guarantee behind a new obligation (deadline +1h so Aiden can always reclaim).
  step(3, c.gold("Acme   "), `lock(Aiden, Acme, ${JOB.guarantee}) — opening the job obligation…`);
  const deadline = Math.floor(Date.now() / 1000) + 3600;
  const lock = await arcAcme.lock(aiden.address, acme.address, JOB.guarantee, deadline);
  const obligationId = lock.id;
  hashes.lock = lock.receipt.hash;
  console.log(`        obligation #${obligationId} · ${tx(lock.receipt.hash)}`);

  // 4. Acme opens the pay-per-second stream for the work budget.
  step(4, c.gold("Acme   "), `createStream(Aiden, ${JOB.budget}, ${JOB.windowSeconds}s) — pay-per-second begins…`);
  const stream = await arcAcme.createStream(aiden.address, JOB.budget, {
    durationSeconds: JOB.windowSeconds,
    memo: JOB.title,
  });
  const streamId = stream.id;
  hashes.createStream = stream.receipt.hash;
  console.log(`        stream #${streamId} · ${tx(stream.receipt.hash)}`);

  // …work happens. Let a chunk of the window stream, then Aiden gets paid for delivered work.
  const waitS = Math.min(20, Math.ceil(JOB.windowSeconds / 3));
  step("…", c.dim("(work)"), c.dim(`Aiden delivers; letting ~${waitS}s of work stream…`));
  await sleep(waitS * 1000);
  const snap = await arcAcme.getStream(streamId);
  console.log(c.dim(`        ${snap.streamedPct}% streamed · ${snap.withdrawable.usdc} USDC withdrawable`));

  // 5. Aiden withdraws what it has earned so far.
  step(5, c.cyan("Aiden  "), `withdraw(stream) — pulling streamed earnings…`);
  const wd = await arcAiden.withdraw(streamId);
  hashes.withdraw = wd.hash;
  console.log(`        ${tx(wd.hash)}`);

  // 6. Report accepted → release the obligation. (Default path would be slash() instead.)
  step(6, c.gold("Acme   "), `release(obligation #${obligationId}) — report accepted, guarantee returned…`);
  const rel = await arcAcme.release(obligationId);
  hashes.release = rel.hash;
  console.log(`        ${tx(rel.hash)}`);

  // Final state.
  const finalStream = await arcAcme.getStream(streamId);
  const finalObl = await arcAiden.getObligation(obligationId);
  console.log(c.green(`\n  Settled. Aiden earned ${finalStream.withdrawn.usdc} USDC for delivered work; obligation #${obligationId} is ${finalObl.status}.`));
  console.log(c.dim(`\n  Scenario footprint (record these for the use-case page):`));
  console.log(c.dim(`    obligationId=${obligationId}  streamId=${streamId}`));
  console.log(c.dim(`    ${JSON.stringify(hashes, null, 0)}\n`));
}

(LIVE ? live() : dryRun()).catch((e) => {
  console.error("\n  scenario failed:", e.message || e, "\n");
  process.exit(1);
});
