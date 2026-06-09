# arc-agentic-stack-sdk

A tiny [ethers v6](https://docs.ethers.org/v6/) wrapper over the **Arc Agentic Stack** —
[`AgentBond`](https://mnorbert87.github.io/arc-agentic-stack/agent-bond/) (reputation-backed
trust) and [`StreamPay`](https://mnorbert87.github.io/arc-agentic-stack/stream-pay/)
(continuous USDC settlement) — deployed on **Arc testnet** (chain `5042002`).

Addresses, chain id, and USDC's 6 decimals are baked in. You pass human USDC amounts
(`"10"` = 10 USDC); the SDK handles micro-USDC conversion and approvals.

```bash
npm i ethers
# drop arc-agentic-stack.js next to your code, or `npm i arc-agentic-stack-sdk`
```

## 10-line integration

An agent posts a bond, then gets streamed paid by the second:

```js
import { ethers } from "ethers";
import { ArcAgenticStack } from "arc-agentic-stack-sdk";

const agent  = new ethers.Wallet(process.env.AGENT_KEY, ArcAgenticStack.provider());
const arc    = new ArcAgenticStack(agent);

await arc.bond("5");                                  // post 5 USDC of skin-in-the-game
const { id } = await arc.createStream(CLIENT_ADDR, "2", { durationSeconds: 3600, memo: "api work" });
console.log("free bond:", (await arc.freeBondOf(agent.address)).usdc);
console.log("stream", id, (await arc.getStream(id)).streamedPct + "% streamed");
```

That's the whole "is there an SDK?" answer: **yes** — bond + stream in a few lines.

## API

Construct with a **Signer** (to send transactions) or a **Provider** (read-only views):

```js
const arc = new ArcAgenticStack(signerOrProvider);   // writes need a Signer
const ro  = ArcAgenticStack.readOnly();              // read straight off the public RPC
```

### AgentBond — trust layer

| Method | What it does |
|---|---|
| `bond(amount)` | Post / top up your bond (auto-approves USDC). |
| `unbond(amount)` | Withdraw free (unlocked) bond. |
| `setSlashAllowance(enforcer, amount)` | Let an enforcer contract lock/slash up to `amount` of your bond. |
| `lock(agent, creditor, amount, deadline?)` | *(enforcer)* Lock bond behind an obligation → `{ id, receipt }`. |
| `release(id)` | Obligation performed — bond unlocks, capacity returns. |
| `slash(id)` | Agent defaulted — bond pays the creditor. |
| `freeBondOf(agent)` · `bondOf(agent)` | Read the public "credit score" / full breakdown. |
| `slashAllowanceOf(agent, enforcer)` · `getObligation(id)` | Allowance + decoded obligation. |

### StreamPay — settlement layer

| Method | What it does |
|---|---|
| `createStream(recipient, amount, { durationSeconds \| stop, start?, memo? })` | Open a USDC stream → `{ id, receipt }` (auto-approves). |
| `withdraw(id, amount?)` | Recipient pulls streamed funds (default `"all"`). |
| `cancel(id)` | Either party cancels; recipient keeps streamed, sender reclaims the rest. |
| `recipientBalance(id)` · `senderBalance(id)` · `getStream(id)` | Live balances + decoded record with `streamedPct`. |

### Helpers

`ArcAgenticStack.provider()` · `ArcAgenticStack.readOnly()` · `arc.usdcBalanceOf(addr)` ·
`arc.approveUsdc(spender, amount)` · `arc.stats()` · `arc.explorerTx(hash)` · `ARC` (network constants).

Every amount view returns `{ raw, usdc }` — `raw` is the micro-USDC bigint, `usdc` is the
formatted string. You never touch decimals.

## Network

```
RPC       https://rpc.testnet.arc.network
Chain id  5042002
Explorer  https://testnet.arcscan.app
USDC      0x3600000000000000000000000000000000000000  (native gas token + 6-dec ERC-20)
AgentBond 0xB9b4d476bC383eE2951a3eC3A22779458cdBf8e0
StreamPay 0x505739d33D85AD85D0f9eeE64856309782382450
```

> Testnet only. Not audited for production; do not point this at mainnet funds.

MIT.
