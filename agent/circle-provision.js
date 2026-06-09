#!/usr/bin/env node
/**
 * Circle Developer-Controlled Wallets — one-time provisioning for the Arc Agentic Stack.
 *
 * Provisions, idempotently:
 *   1. an Entity Secret (32-byte hex) registered against the Circle API key,
 *   2. a wallet set,
 *   3. one EOA developer-controlled wallet on ARC-TESTNET for the agent (Aiden).
 *
 * Secrets are written to ./.secrets/.env (gitignored). The registration recovery file
 * is written to ./.secrets/ — keep it: it is the ONLY way to rotate the Entity Secret.
 *
 * This script does NOT send any Arc transaction. It only creates Circle-side resources,
 * so it is independent of the burner wallet's on-chain nonce.
 *
 *   CIRCLE_API_KEY   read from env, else parsed from ../../commit-stake/.env
 */
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  registerEntitySecretCiphertext,
  initiateDeveloperControlledWalletsClient,
} from "@circle-fin/developer-controlled-wallets";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SECRETS_DIR = path.join(__dirname, ".secrets");
const SECRETS_ENV = path.join(SECRETS_DIR, ".env");

function parseEnv(file) {
  if (!fs.existsSync(file)) return {};
  const out = {};
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
  return out;
}

function loadApiKey() {
  if (process.env.CIRCLE_API_KEY) return process.env.CIRCLE_API_KEY;
  const fromCommitStake = parseEnv(path.join(__dirname, "..", "..", "commit-stake", ".env"));
  if (fromCommitStake.CIRCLE_API_KEY) return fromCommitStake.CIRCLE_API_KEY;
  throw new Error("CIRCLE_API_KEY not found (env or ../../commit-stake/.env).");
}

function writeSecretsEnv(obj) {
  fs.mkdirSync(SECRETS_DIR, { recursive: true });
  const body = Object.entries(obj).map(([k, v]) => `${k}=${v}`).join("\n") + "\n";
  fs.writeFileSync(SECRETS_ENV, body, { mode: 0o600 });
}

const mask = (s) => (s ? s.slice(0, 10) + "…" + s.slice(-4) : "");

async function main() {
  const apiKey = loadApiKey();
  const existing = parseEnv(SECRETS_ENV);

  // If a wallet is already provisioned, just report it (idempotent).
  if (existing.CIRCLE_WALLET_ID && existing.CIRCLE_WALLET_ADDRESS) {
    console.log("Already provisioned (skipping):");
    console.log("  walletSetId :", existing.CIRCLE_WALLET_SET_ID);
    console.log("  walletId    :", existing.CIRCLE_WALLET_ID);
    console.log("  address     :", existing.CIRCLE_WALLET_ADDRESS);
    console.log("  blockchain  :", existing.CIRCLE_WALLET_BLOCKCHAIN || "ARC-TESTNET");
    return;
  }

  // 1) Entity Secret — generate once, register once.
  let entitySecret = existing.CIRCLE_ENTITY_SECRET;
  if (!entitySecret) {
    entitySecret = crypto.randomBytes(32).toString("hex");
    console.log("Generated new Entity Secret (32-byte hex):", mask(entitySecret));
    console.log("Registering ciphertext against API key", mask(apiKey), "…");
    const reg = await registerEntitySecretCiphertext({ apiKey, entitySecret });
    const recovery = reg?.data?.recoveryFile;
    if (recovery) {
      const rf = path.join(SECRETS_DIR, `recovery_file_${Date.now()}.dat`);
      fs.mkdirSync(SECRETS_DIR, { recursive: true });
      fs.writeFileSync(rf, recovery, { mode: 0o600 });
      console.log("Recovery file saved:", rf, "(KEEP THIS — needed to rotate the secret)");
    } else {
      console.log("WARN: registration returned no recoveryFile field.");
    }
  } else {
    console.log("Reusing Entity Secret from .secrets/.env:", mask(entitySecret));
  }

  // 2) client + wallet set + 3) wallet on ARC-TESTNET
  const client = initiateDeveloperControlledWalletsClient({ apiKey, entitySecret });

  console.log("Creating wallet set 'arc-agentic-stack' …");
  const ws = await client.createWalletSet({ name: "arc-agentic-stack" });
  const walletSetId = ws.data?.walletSet?.id;
  console.log("  walletSetId:", walletSetId);

  console.log("Creating 1 EOA wallet on ARC-TESTNET for agent Aiden …");
  const wr = await client.createWallets({
    walletSetId,
    blockchains: ["ARC-TESTNET"],
    accountType: "EOA",
    count: 1,
    metadata: [{ name: "aiden-agent", refId: "arc-agentic-stack" }],
  });
  const wallet = wr.data?.wallets?.[0];
  console.log("  walletId  :", wallet?.id);
  console.log("  address   :", wallet?.address);
  console.log("  blockchain:", wallet?.blockchain, " state:", wallet?.state);

  writeSecretsEnv({
    CIRCLE_ENTITY_SECRET: entitySecret,
    CIRCLE_WALLET_SET_ID: walletSetId,
    CIRCLE_WALLET_ID: wallet?.id || "",
    CIRCLE_WALLET_ADDRESS: wallet?.address || "",
    CIRCLE_WALLET_BLOCKCHAIN: wallet?.blockchain || "ARC-TESTNET",
  });
  console.log("\nWrote", SECRETS_ENV, "(mode 600, gitignored).");
  console.log("DONE — Circle wallet live at the provisioning layer.");
}

main().catch((e) => {
  console.error("provision error:", e?.response?.data || e?.message || e);
  process.exit(1);
});
