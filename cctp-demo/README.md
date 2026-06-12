# Cross-chain capital onboarding for agents — CCTP V2 (Circle App Kit)

An agent's bond capital does not have to start on Arc. This mini-demo brings USDC **from another
testnet (Base Sepolia) to Arc** and deposits it straight into **AgentBond** — so an agent funded
anywhere can post its slashable bond on Arc in one runnable flow.

```
[Base Sepolia]  ── kit.bridge(FAST) ──▶  [Arc]  ── AgentBond.deposit ──▶  bonded capital
```

## Primary: Circle App Kit — Bridge Kit (`bridge-onboard.ts`)

Built with Circle's official **App Kit / Bridge Kit** (`@circle-fin/bridge-kit` +
`@circle-fin/adapter-viem-v2`), CCTP V2 under the hood. **Bridge Kit lists Arc Testnet natively**
(`ArcTestnet`, chainId `5042002`, CCTP domain `26`) — so the whole cross-chain leg is one
`kit.bridge({ from: 'Base_Sepolia', to: 'Arc_Testnet', config: { transferSpeed: 'FAST' } })` call,
no raw `depositForBurn` / attestation-polling / `receiveMessage` by hand. The AgentBond deposit is
a plain viem call on Arc afterwards.

```bash
npm install
PRIVATE_KEY=0x<burner> npm run onboard        # burner 0x2e36..A08a, never a personal key
```

> Verified: with the SDK installed, `kit.bridge(Base_Sepolia → Arc_Testnet)` resolves the route
> and validates against the real Base-Sepolia USDC — it stops only at the funding gate
> (`BALANCE_INSUFFICIENT_TOKEN`) until the burner is funded, confirming Arc is a first-class
> Bridge-Kit destination.

## Reference: raw CCTP V2, no SDK (`run.sh`)

The same flow with bare `cast` calls against the canonical CCTP V2 contracts —
`approve → TokenMessengerV2.depositForBurn` → poll the public Iris sandbox → Arc
`MessageTransmitterV2.receiveMessage`. Kept as a low-level reference that shows exactly what the
SDK does under the hood (and as a fallback). `./run.sh`.

## Prerequisite — fund the burner on the source chain (Base Sepolia)

- **USDC:** <https://faucet.circle.com> → the burner address, chain *Base Sepolia* (10 USDC/drip)
- **gas (ETH):** any Base Sepolia ETH faucet → ~0.01 ETH

Arc-side gas is USDC and the burner already holds it. A full run writes `result.json` with every
tx hash; the captured transcript is in [`SAMPLE_RUN.md`](./SAMPLE_RUN.md).

## Addresses (CCTP V2)

| | Address | CCTP domain |
|---|---|---|
| TokenMessengerV2 (canonical, every chain) | `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA` | — |
| MessageTransmitterV2 (canonical, every chain) | `0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275` | — |
| USDC · Base Sepolia | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` | src `6` |
| USDC · Arc | `0x3600000000000000000000000000000000000000` | dst `26` |
| AgentBond · Arc | `0xB9b4d476bC383eE2951a3eC3A22779458cdBf8e0` | — |

Standard Transfer (finality threshold `2000`) is free; Fast Transfer (`1000`) costs a few
micro-USDC and clears in seconds on testnet. This demo uses Fast.
