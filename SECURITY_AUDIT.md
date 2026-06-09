# Security Audit — Arc Agentic Stack

Adversarial self-audit of the two contracts (`AgentBond`, `StreamPay`) using Foundry. Method: full unit + adversarial suites, reentrancy attacker tokens, fee-on-transfer tokens, and a stateful solvency **invariant** (random multi-actor call sequences). All amounts are micro-USDC (6 decimals).

**Verdict: no critical or high-severity findings.** Both contracts are solvent under fuzzing, reentrancy-safe, and access-controlled. One low-severity view-correctness bug was found and fixed; one medium design gap is documented with a recommendation.

| Severity | Finding | Status |
|---|---|---|
| 🟢 Low | StreamPay: `recipientBalance`/`senderBalance` reported phantom funds for a *terminal* (cancelled) stream | **Fixed** + regression test |
| 🟡 Medium (design) | AgentBond: an approved enforcer can lock bond **indefinitely** (no obligation expiry) — griefing | Documented; fix recommended |
| ⚪ By-design | Approving an enforcer grants it full lock+slash power (ERC-20 `approve` trust model) | Accepted risk, documented |

---

## Test results

```
AgentBond:  18 passed / 0 failed   (incl. solvency invariant: 256 runs · 128,000 calls · 0 reverts)
StreamPay:  18 passed / 0 failed   (incl. fee-on-transfer, reentrancy, solvent-split fuzz, terminal-view regression)
```

### Crown proof — solvency invariant (AgentBond)
A handler drives random `deposit / withdraw / setSlashAllowance / lock / release / slash` from 3 agents and 2 enforcers. Across **128,000 calls with zero reverts**, two invariants held continuously:
- `usdc.balanceOf(AgentBond) == Σ bond[agent]` — the contract is never under- or over-collateralized.
- `locked[agent] ≤ bond[agent]` for every agent — locked capacity can never exceed the bond backing it.

StreamPay carries an equivalent per-stream solvency property (`withdrawn + recipientBalance + senderBalance == deposit`) verified by `testFuzz_solventSplit` and the adversarial "second stream cannot drain the first" test.

---

## Confirmed defenses (both contracts)

- **Checks-Effects-Interactions.** Every fund-moving path sets terminal state and updates accounting *before* the external token transfer (`slash`, `withdraw`, `cancel`).
- **Reentrancy guard.** Single-slot `nonReentrant` mutex on all state-changing entry points (belt-and-suspenders alongside CEI). Proven by attacker-token tests: a malicious token re-entering during payout cannot double-pay; the end state shows exactly one payout.
- **Balance-delta custody.** Deposits/streams record `balanceOf(after) − balanceOf(before)`, so fee-on-transfer or rebasing tokens can never let one position drain another's escrow.
- **Safe ERC-20.** Low-level call with `require(ok && (data.length == 0 || abi.decode(data,(bool))))` — tolerates non-standard no-return tokens (e.g. USDT-style).
- **Access control.** `release`/`slash` restricted to the opening enforcer; `withdraw` to the recipient; `cancel` to either party. No owner, no admin, no upgrade key — nothing privileged to compromise.
- **No cross-actor theft.** Slash allowance is keyed `[agent][enforcer]`; an enforcer can only ever touch the bond of agents that explicitly granted *it*.
- **Solidity 0.8 checked math** throughout; the `bond ≥ locked` invariant means the `free = bond − locked` subtraction can never underflow.

---

## Findings in detail

### 🟢 LOW — StreamPay terminal-stream views reported phantom balances *(fixed)*

**Before:** `streamedTotal` kept accruing against wall-clock time even after a stream became terminal. So a stream cancelled at 50% would later report `recipientBalance = 40 USDC` as "withdrawable," even though the stream was `Ended` and `withdraw()` correctly reverts `NOT_ACTIVE`.

**Impact:** view-only. No funds at risk (the write path is guarded), but a frontend or integrator reading `recipientBalance` / `senderBalance` would display funds that don't exist — an integration footgun.

**Fix:** `streamedTotal` now freezes at `withdrawn` once a stream is `Ended`; `recipientBalance` and `senderBalance` return `0` for any non-`Active` stream. Regression tests `test_views_zeroAfterCancel` and `test_views_zeroAfterFullWithdraw` lock the behavior.

### 🟡 MEDIUM (design) — AgentBond obligations never expire

An enforcer that an agent has approved can call `lock` and then simply never `release` or `slash`. That slice of the agent's bond stays locked forever; the agent has no way to force-reclaim it. Unlike `slash`, this benefits no one — it is pure griefing by a misbehaving (but previously trusted) enforcer.

**Why it's not critical:** it cannot move funds anywhere, and it only affects bond the agent voluntarily exposed to that specific enforcer. But it's a liveness gap worth closing.

**Recommendation:** add an optional `deadline` to an obligation; after it passes with no resolution, allow the *agent* to self-`release` (unlock without slashing). This preserves the enforcer's window to act while removing the indefinite-lock vector. (Feature change → requires redeploy.)

### ⚪ BY-DESIGN — enforcer approval is full trust

`setSlashAllowance(enforcer, amount)` is deliberately modeled on ERC-20 `approve`: once granted, the enforcer can `lock` and `slash` up to that amount to a creditor *of its choosing*. Approving a malicious or buggy enforcer is therefore as dangerous as approving a malicious ERC-20 spender. This is the intended composability model (the enforcer is the protocol the agent opted into) and is called out in the contract NatSpec: *"Only ever trust audited enforcer code."* Mitigation is social/operational, not contract-level.

**Minor, related:** `setSlashAllowance` is a raw set (not increase/decrease), so it carries the classic ERC-20 approve race. Low impact here because already-locked obligations are unaffected and the enforcer was already trusted up to the prior allowance.

---

## Notes considered and dismissed

- **Integer overflow in `streamedTotal` (`deposit * elapsed`).** Safe for any realistic USDC amount: even total USDC supply (~10¹⁶ micro-USDC ≈ 2⁵³) times a 64-bit elapsed time stays far below 2²⁵⁶.
- **Back-dated `start`.** `createStream` allows `start` in the past; this lets a sender intentionally front-load accrual with their own funds — sender's choice, not a vulnerability.
- **`block.timestamp` non-monotonic on Arc.** Linear accrual is monotonic regardless; equal timestamps stream nothing extra and the floor/remainder split keeps the escrow exactly solvent.
- **Reentrancy via creditor/recipient in payouts.** Blocked by both CEI (state already terminal) and the mutex; proven by attacker-token tests.

---

## Not testable without a deployer key (operational)

- On-chain deployment parameters (correct USDC address wired at construction) — verified by reading the live contract's `usdc()` getter on Arc Testnet, not by unit test.
