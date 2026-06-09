#!/usr/bin/env node
/**
 * x402 pay-per-inference server — settled on Arc with StreamPay.
 *
 * A single endpoint, `GET /inference`, is gated behind HTTP 402 Payment Required.
 * Payment is NOT a one-shot charge: the client opens a StreamPay micro-stream to this
 * server's address, and the server PULLS the seconds that have vested each time it
 * serves a call. That is pay-per-second-of-use — the agentic-economy billing model —
 * with the on-chain settlement riding our StreamPay primitive as the rail.
 *
 * Flow:
 *   1. GET /inference?prompt=...            -> 402 + machine-readable payment terms (x402 body).
 *   2. (client opens a StreamPay stream to PAY_TO off this response.)
 *   3. GET /inference?prompt=...&stream=ID  -> server reads the stream on-chain:
 *        - must be Active, recipient must be this server, and have vested-unwithdrawn >= MIN.
 *        - server withdraw()s the vested amount (real Arc tx) and returns 200 + the result
 *          + the settlement tx hash. No payment vested -> 402 again.
 *
 * The "model" here is a deterministic stub: this demo proves the PAYMENT RAIL and the
 * 402->200 gate, not a language model. Swap `runInference` for any real engine.
 *
 * Env:
 *   SERVER_PRIVATE_KEY  key whose address receives + withdraws the stream   [required]
 *   RPC_URL             Arc Testnet RPC                                      [default below]
 *   STREAM_PAY          StreamPay address                                    [default = live USDC deploy]
 *   PORT                listen port                                          [default 4021]
 *   MIN_CALL_USDC       min vested USDC required to serve a call             [default 0.01]
 */
import http from "node:http";
import { ethers } from "ethers";

const RPC = process.env.RPC_URL || "https://rpc.testnet.arc.network";
const CHAIN_ID = 5042002;
const EXPLORER = "https://testnet.arcscan.app";
const STREAM_PAY = process.env.STREAM_PAY || "0x505739d33D85AD85D0f9eeE64856309782382450";
const PORT = Number(process.env.PORT || 4021);
const U = 1_000_000n; // 1 USDC (6 decimals)
const MIN_CALL = BigInt(Math.round(Number(process.env.MIN_CALL_USDC || 0.01) * 1e6)); // micro-USDC

const SP_ABI = [
  "function get(uint256) view returns (tuple(address sender,address recipient,uint256 deposit,uint256 withdrawn,uint64 start,uint64 stop,uint8 status))",
  "function recipientBalance(uint256) view returns (uint256)",
  "function withdraw(uint256,uint256)",
];

const usd = (v) => (Number(v) / 1e6).toFixed(6);

const pk = process.env.SERVER_PRIVATE_KEY;
if (!pk) { console.error("Set SERVER_PRIVATE_KEY (the server's testnet key)."); process.exit(1); }

const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID);
const wallet = new ethers.Wallet(pk, provider);
const SERVER_ADDR = wallet.address;
const sp = new ethers.Contract(STREAM_PAY, SP_ABI, wallet);

// --- the "inference" stub. Deterministic, obviously not a real model. ---
function runInference(prompt) {
  const p = (prompt || "").slice(0, 200);
  const tokens = p.split(/\s+/).filter(Boolean).length;
  const hash = ethers.id(p).slice(0, 10);
  return {
    model: "stub-inference-v0 (demo)",
    prompt: p,
    completion: `Acknowledged "${p}" — ${tokens} tokens. Deterministic stub completion ${hash}.`,
    tokens,
  };
}

// machine-readable 402 payment terms, x402-style
function paymentTerms() {
  return {
    error: "payment_required",
    x402: {
      scheme: "streampay",
      network: "arc-testnet",
      chainId: CHAIN_ID,
      asset: "USDC",
      settlementContract: STREAM_PAY,
      payTo: SERVER_ADDR,
      pricing: `pay-per-second: server pulls vested USDC each call (min ${usd(MIN_CALL)} USDC vested to serve)`,
      suggestedDeposit: "0.30 USDC over 60s",
      instructions: `Open a StreamPay stream with recipient=${SERVER_ADDR}, then resend with ?stream=<id>.`,
    },
  };
}

function send(res, code, obj, extraHeaders = {}) {
  const body = JSON.stringify(obj, null, 2);
  res.writeHead(code, { "Content-Type": "application/json", ...extraHeaders });
  res.end(body);
}

async function handle(req, res) {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  if (url.pathname !== "/inference") return send(res, 404, { error: "not_found" });

  const prompt = url.searchParams.get("prompt") || "";
  const streamId = url.searchParams.get("stream");

  // No payment presented -> 402 with terms.
  if (!streamId) {
    console.log(`402  no stream  prompt="${prompt.slice(0, 40)}"`);
    return send(res, 402, paymentTerms(), {
      "WWW-Authenticate": `x402 settlementContract="${STREAM_PAY}", payTo="${SERVER_ADDR}", asset="USDC"`,
    });
  }

  // Verify the stream on-chain.
  let st;
  try {
    st = await sp.get(streamId);
  } catch {
    return send(res, 402, { ...paymentTerms(), reason: "stream_not_found" });
  }
  const recipient = st.recipient.toLowerCase();
  const active = Number(st.status) === 1;
  if (!active || recipient !== SERVER_ADDR.toLowerCase()) {
    return send(res, 402, { ...paymentTerms(), reason: "stream_not_active_or_wrong_recipient" });
  }

  const vested = await sp.recipientBalance(streamId);
  if (vested < MIN_CALL) {
    console.log(`402  stream #${streamId} underfunded vested=$${usd(vested)} < $${usd(MIN_CALL)}`);
    return send(res, 402, {
      ...paymentTerms(),
      reason: "insufficient_vested_balance",
      vested: usd(vested),
      minPerCall: usd(MIN_CALL),
    });
  }

  // Settle: pull everything vested since the last call (pay-per-second). Real Arc tx.
  // On Arc, block.timestamp is non-monotonic, so the amount that has actually vested at
  // mining time can dip below what we just read — making withdraw revert. That is a
  // transient, not a fault: answer 402 and let the agent retry on its next call.
  let rc;
  try {
    const tx = await sp.withdraw(streamId, 0n);
    rc = await tx.wait();
    if (rc.status !== 1) throw new Error("withdraw reverted");
  } catch (e) {
    console.log(`402  stream #${streamId} settle failed (${e.shortMessage || e.message}) — retry next call`);
    return send(res, 402, { ...paymentTerms(), reason: "settlement_reverted_retry" });
  }

  const result = runInference(prompt);
  console.log(`200  stream #${streamId} served, settled $${usd(vested)}  tx ${rc.hash}`);
  return send(res, 200, {
    ok: true,
    result,
    payment: {
      stream: Number(streamId),
      settledUSDC: usd(vested),
      settlementTx: rc.hash,
      explorer: `${EXPLORER}/tx/${rc.hash}`,
    },
  });
}

const server = http.createServer((req, res) => {
  // A failed settlement must never take the server down — always answer something.
  handle(req, res).catch((e) => {
    console.error(`500  ${e.shortMessage || e.message}`);
    try { send(res, 500, { error: "server_error", detail: e.shortMessage || e.message }); } catch {}
  });
});

process.on("unhandledRejection", (e) => console.error("unhandledRejection:", e?.shortMessage || e?.message || e));
process.on("uncaughtException", (e) => console.error("uncaughtException:", e?.shortMessage || e?.message || e));

server.listen(PORT, () => {
  console.log(`x402 inference server on :${PORT}`);
  console.log(`  payTo (server)   ${SERVER_ADDR}`);
  console.log(`  StreamPay        ${STREAM_PAY}`);
  console.log(`  min per call     $${usd(MIN_CALL)} USDC vested`);
});
