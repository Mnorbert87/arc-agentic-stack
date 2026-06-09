#!/usr/bin/env node
/**
 * CIRCLE_MODE binding — the agent (Aiden) signs a REAL Arc Testnet transaction through its
 * Circle Developer-Controlled Wallet instead of a local burner key. No private key on disk
 * touches the chain: Circle holds the key, we authorize via the registered Entity Secret.
 *
 * This runs one or more contract executions on the live Arc Agentic Stack:
 *   approve  → StreamPay can pull the agent's USDC
 *   deposit  → AgentBond (build the credit score)
 *   createStream → StreamPay (open a pay-per-second stream)
 *   withdraw → StreamPay (pull vested pay)
 *
 * Each step is submitted via Circle's createContractExecutionTransaction, then polled to a
 * terminal state, and the on-chain tx hash + arcscan link is printed.
 *
 *   CIRCLE_API_KEY        env, else ../../commit-stake/.env
 *   CIRCLE_ENTITY_SECRET  ./.secrets/.env
 *   CIRCLE_WALLET_ID      ./.secrets/.env   (wallet 0xdfda…f46b on ARC-TESTNET)
 *   STEPS=approve         comma list: approve,deposit,stream,withdraw  (default: approve)
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { initiateDeveloperControlledWalletsClient } from "@circle-fin/developer-controlled-wallets";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const USDC = "0x3600000000000000000000000000000000000000";
const AGENT_BOND = "0xB9b4d476bC383eE2951a3eC3A22779458cdBf8e0";
const STREAM_PAY = "0x505739d33D85AD85D0f9eeE64856309782382450";
const EXPLORER = "https://testnet.arcscan.app";
const MAX_UINT = "115792089237316195423570985008687907853269984665640564039457584007913129639935";

function parseEnv(file) {
  if (!fs.existsSync(file)) return {};
  const out = {};
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
  return out;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const secrets = parseEnv(path.join(__dirname, ".secrets", ".env"));
const apiKey = process.env.CIRCLE_API_KEY || parseEnv(path.join(__dirname, "..", "..", "commit-stake", ".env")).CIRCLE_API_KEY;
const entitySecret = secrets.CIRCLE_ENTITY_SECRET;
const walletId = secrets.CIRCLE_WALLET_ID;
const walletAddress = secrets.CIRCLE_WALLET_ADDRESS;
if (!apiKey || !entitySecret || !walletId) throw new Error("Missing CIRCLE_API_KEY / ENTITY_SECRET / WALLET_ID.");

const client = initiateDeveloperControlledWalletsClient({ apiKey, entitySecret });

async function exec(label, contractAddress, abiFunctionSignature, abiParameters) {
  console.log(`\n→ ${label}`);
  console.log(`   ${abiFunctionSignature}  on ${contractAddress}`);
  let res;
  try {
    res = await client.createContractExecutionTransaction({
      walletId,
      contractAddress,
      abiFunctionSignature,
      abiParameters,
      fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    });
  } catch (e) {
    console.log("   ✗ submit ERR:", e?.response?.status, JSON.stringify(e?.response?.data ?? e?.message ?? String(e)));
    throw e;
  }
  const id = res?.data?.id;
  console.log(`   submitted, Circle tx id ${id}, initial state ${res?.data?.state}`);
  // poll to terminal state
  for (let i = 0; i < 40; i++) {
    await sleep(3000);
    const g = await client.getTransaction({ id });
    const t = g?.data?.transaction;
    const st = t?.state;
    if (i % 3 === 0 || st !== "SENT") console.log(`   [${i}] state=${st}${t?.txHash ? " hash=" + t.txHash : ""}`);
    if (st === "CONFIRMED" || st === "COMPLETE") {
      console.log(`   ✓ ${label} CONFIRMED  ${EXPLORER}/tx/${t.txHash}`);
      return t.txHash;
    }
    if (st === "FAILED" || st === "CANCELLED" || st === "DENIED") {
      console.log(`   ✗ ${label} ${st}: ${JSON.stringify(t?.errorReason ?? t?.errorDetails ?? "")}`);
      throw new Error(`${label} ${st}`);
    }
  }
  throw new Error(`${label} did not reach terminal state in time`);
}

const STEPS = (process.env.STEPS || "approve").split(",").map((s) => s.trim()).filter(Boolean);

async function main() {
  console.log(`🔐 CIRCLE_MODE — Aiden signs via Circle wallet ${walletAddress} (id ${walletId})`);
  const hashes = {};
  for (const step of STEPS) {
    if (step === "approve") {
      hashes.approve = await exec("approve USDC → StreamPay", USDC, "approve(address,uint256)", [STREAM_PAY, MAX_UINT]);
    } else if (step === "approveBond") {
      hashes.approveBond = await exec("approve USDC → AgentBond", USDC, "approve(address,uint256)", [AGENT_BOND, MAX_UINT]);
    } else if (step === "deposit") {
      hashes.deposit = await exec("deposit 1 USDC bond", AGENT_BOND, "deposit(uint256)", ["1000000"]);
    } else if (step === "stream") {
      const now = Math.floor(Date.now() / 1000);
      hashes.stream = await exec(
        "createStream 1 USDC / 120s",
        STREAM_PAY,
        "createStream(address,uint256,uint64,uint64,string)",
        [walletAddress, "1000000", String(now), String(now + 120), "Aiden via Circle Wallet"]
      );
    }
  }
  console.log("\n✅ CIRCLE_MODE done. Hashes:");
  for (const [k, v] of Object.entries(hashes)) console.log(`   ${k}: ${EXPLORER}/tx/${v}`);
}

main().catch((e) => { console.error("\ncircle-execute fatal:", e?.shortMessage || e?.message || e); process.exit(1); });
