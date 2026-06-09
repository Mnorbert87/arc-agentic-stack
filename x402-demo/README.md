# x402 pay-per-inference, settled on Arc with StreamPay

An autonomous agent **pays per API call** over the [x402](https://www.x402.org/) pattern
(HTTP `402 Payment Required`), with the payment settled **on-chain in USDC on Arc** using
**StreamPay** as the settlement rail. No human in the loop, no API keys, no off-chain
invoicing — the `402 → 200` transition is bound to a live on-chain payment.

This is the missing piece for the agentic economy: a server can charge a machine per
request and get paid per second of use, and the buyer agent only spends for what it
actually consumes.

> The "model" behind `/inference` here is a deterministic stub — this demo proves the
> **payment rail and the 402 gate**, not a language model. Swap `runInference()` in
> `server.js` for any real engine and the billing is already done.

## How it works

```
buyer agent                         x402 server (payee)                 Arc Testnet
-----------                         -------------------                 -----------
GET /inference            ───────▶  402 Payment Required
                          ◀───────  { scheme: streampay, payTo, asset: USDC, … }

createStream(payTo, 0.30 USDC, 60s) ───────────────────────────────────▶  StreamPay #N

GET /inference?stream=N   ───────▶  reads stream on-chain (active? recipient? vested?)
                                    withdraw() the vested seconds  ─────▶  USDC moves
                          ◀───────  200 { result, settlementTx }       (real Arc tx)
   …repeat per call (server pulls the seconds vested since the last call)…

cancel(N)                 ───────────────────────────────────────────▶  reclaim unused
```

- **402 with machine-readable terms.** A call with no payment returns `402` plus a JSON
  `x402` body (and a `WWW-Authenticate: x402 …` header) describing the scheme, the
  settlement contract, the `payTo` address, and the asset. An agent reads it and pays.
- **StreamPay as the rail.** The agent opens a *micro-stream* to the server's address.
  The stream is a small committed budget that vests linearly per second. The server,
  as the stream recipient, `withdraw()`s the seconds that have vested **each time it
  serves a call** — that is genuine pay-per-second-of-use, not a flat charge.
- **The gate is on-chain.** `200` is returned **only after** a successful on-chain
  `withdraw()`; if nothing has vested, the server answers `402` again. The settlement
  tx hash is returned in the `200` body.
- **Pay only for use.** When done, the agent `cancel()`s the stream and the unspent
  remainder returns to it. In the [sample run](./SAMPLE_RUN.md): committed 0.30 USDC,
  paid 0.17 for three calls, reclaimed 0.13.

Why streaming instead of one transfer per call? Because the agentic billing model is
metered: a stream lets the server pull continuously while it works, settles many calls
against a single committed budget, and lets the buyer cap and reclaim its spend — all
properties a bare per-call `transfer` does not give you.

## Run it

Needs Node 18+ and two funded Arc-Testnet burner keys (USDC is the gas token; get test
USDC at https://faucet.circle.com). The server wallet auto-tops-up from the agent on
first run.

```bash
npm install
cp .env.example .env        # fill AGENT_PRIVATE_KEY + SERVER_PRIVATE_KEY (dedicated burners)
./run.sh                    # bootstrap → start server → run agent → tee to demo-run.log
```

Or drive the two sides yourself:

```bash
SERVER_PRIVATE_KEY=0x… node server.js          # terminal 1 — the paid endpoint
AGENT_PRIVATE_KEY=0x…  node agent.js            # terminal 2 — the buyer agent
```

See a verified end-to-end transcript with live arcscan links in **[SAMPLE_RUN.md](./SAMPLE_RUN.md)**.

## Files

| File | What |
|------|------|
| `server.js`    | The 402-gated `/inference` endpoint; verifies the stream on-chain and settles via StreamPay `withdraw()`. |
| `agent.js`     | The autonomous buyer: hits 402, opens the stream, polls paid calls, reclaims the remainder. |
| `bootstrap.js` | Funds the server wallet's gas (USDC) from the agent if it is low. |
| `run.sh`       | One-command end-to-end demo. |

## Arc Testnet reference

| | |
|---|---|
| RPC | `https://rpc.testnet.arc.network` |
| Chain ID | `5042002` |
| Gas token | **USDC** (native) — `0x3600000000000000000000000000000000000000` |
| StreamPay | `0x505739d33D85AD85D0f9eeE64856309782382450` |
| Explorer | https://testnet.arcscan.app |
| Faucet | https://faucet.circle.com |

## Security

- Keys are read at runtime; `.env` and `node_modules` are gitignored. **No key is ever
  committed or logged.**
- Use dedicated burner wallets only — never a real-money key.
- StreamPay is the audited primitive in [`../stream-pay`](../stream-pay); this demo adds
  no custody of its own (the server only ever pulls what has vested to it).
