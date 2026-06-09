# Agent — Circle Wallets signing Arc transactions

Aiden is the autonomous agent in this stack. It can run the full lifecycle two ways:

| Script | Signer | What it proves |
|---|---|---|
| `demo-agent.js`    | local burner key (`PRIVATE_KEY`)        | the contracts work end-to-end in USDC on Arc |
| `circle-execute.js`| **Circle Developer-Controlled Wallet**   | the agent signs Arc txs with **no private key on disk** |

The Circle path is the interesting one: Circle custodies the key, and the agent authorizes
each contract call with a registered **Entity Secret**. This is the missing primitive between
"smart contract" and "autonomous agent" — a key the agent can spend from without anyone holding
raw key material.

## Verified live run (Arc Testnet)

Signed by Circle wallet `0xdFDaDEb7440f1CE4Cc2f62Aa21BCCe3374bDF46b` (provisioned on `ARC-TESTNET`):

| Step | Call | Tx |
|---|---|---|
| Approve | `USDC.approve(StreamPay)` | [`0x053495…be03`](https://testnet.arcscan.app/tx/0x05349563271e35e9b79d66116cd5d84ca65cff8032bce41fa937ff29dca8be03) |
| Approve | `USDC.approve(AgentBond)` | [`0xfb90ad…4277`](https://testnet.arcscan.app/tx/0xfb90ad375c089cf1db78f59beaf4c5ad9f07958311248c9815b4bb2291c74277) |
| Bond | `AgentBond.deposit(1 USDC)` | [`0x59a8a0…20ab`](https://testnet.arcscan.app/tx/0x59a8a0d095ca745ee2f37f0abfcdc631852707ced7d8e8a1128ebd42f09220ab) |
| Stream | `StreamPay.createStream(1 USDC / 120s)` | [`0x2f96d1…7302`](https://testnet.arcscan.app/tx/0x2f96d176d5904278806259cd4b96a38d1f0550e078fc953878028bb7b55d7302) |

Circle's `estimateContractExecutionFee` and `createContractExecutionTransaction` worked against
Arc's USDC-as-gas model with no special-casing beyond the `ARC-TESTNET` chain id.

## Run it

```bash
npm install
export CIRCLE_API_KEY=TEST_API_KEY:<id>:<secret>

# 1) one-time: provision an Entity Secret + a wallet on ARC-TESTNET (writes ./.secrets/.env)
node circle-provision.js

# 2) fund the printed wallet address with testnet USDC (USDC is gas on Arc):
#    https://faucet.circle.com  — or send USDC to it from any funded Arc wallet.

# 3) sign a real lifecycle through the Circle wallet
STEPS=approve,approveBond,deposit,stream node circle-execute.js
```

## Security

- `circle-provision.js` writes the Entity Secret and wallet ids to `./.secrets/.env` (mode 600,
  **gitignored**). The `recovery_file_*.dat` is the only way to rotate the Entity Secret — keep it
  safe, never commit it.
- `CIRCLE_API_KEY` is read from the environment (or `../commit-stake/.env`); it is never logged or
  committed.
- No raw private key is used or stored for the Circle path — Circle holds the key.
