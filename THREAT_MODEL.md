# Threat Model — Arc Agentic Stack

Scope: the three on-chain primitives in this repo — [`AgentBond`](contracts/agent-bond/src/AgentBond.sol), [`StreamPay`](contracts/stream-pay/src/StreamPay.sol), [`CommitStake`](contracts/commit-stake/src/CommitStake.sol) — deployed ownerless on Arc Testnet. All three custody USDC, so the model below asks one question per adversary: **can this actor make the contract pay out money it should not, or freeze money it should release?** Every mitigation listed is enforced by a specific code path and exercised by the test suite (unit + adversarial + 10,000-run fuzz + 10,000-run invariant campaigns; see each project's README for the live numbers).

## Trust assumptions (stated up front)

- **AgentBond**: the *agent chooses* which enforcer contract may lock/slash its bond, and caps it (`setSlashAllowance`). An enforcer is trusted *up to that cap and no further*. Dispute policy lives in the enforcer, by design.
- **CommitStake**: the *staker chooses* the verifier and the beneficiary at `create`. The verifier is trusted to judge pass/fail honestly — but it can neither redirect the money to itself nor hold it hostage (see below).
- **StreamPay**: no third party at all; only sender and recipient have any authority over a stream.
- The token is real Arc USDC (1:1 transfers). The contracts nevertheless defend against non-standard tokens via balance-delta custody, so a misconfigured deployment fails safe.

## Adversaries and defenses

### 1. Malicious verifier / enforcer (the trusted judge turns hostile)

**Attack:** CommitStake's verifier resolves `false` dishonestly to move the stake; AgentBond's enforcer slashes a healthy agent.

**Defense — damage is capped and cannot be redirected:**
- The payout destination is fixed *before* the judge acts: `CommitStake.create` pins `beneficiary` (`CommitStake.sol:113-120`), `AgentBond.lock` pins `creditor` (`AgentBond.sol:153-160`). A hostile judge can trigger the payout, but only to the address the funding party already accepted — it cannot pay itself.
- AgentBond exposure is bounded by the agent's own grant: `lock` spends `slashAllowance` (`AgentBond.sol:144-149`), which the agent sets and can revoke to zero at any time (`setSlashAllowance`, `AgentBond.sol:121-125`). A slash burns capacity permanently (`slash` does not restore allowance, `AgentBond.sol:185-196`), so a hostile enforcer cannot recycle one grant into repeated slashes.
- Tested: `test_slash_paysCreditorAndBurnsCapacity`, `testFuzz_slash_paysExactlyLockedAmount`, `test_revokeAllowance_blocksNewLocks`, and the `invariant_exactlyOnePayout` campaign proving a stake can never reach both sides.

**Residual risk (accepted, documented):** a dishonest verifier *can* misjudge the outcome within those bounds. That is the stated trust model — pick your verifier/enforcer the way you pick an escrow agent. The primitive guarantees the blast radius, not the judge's honesty.

### 2. Silent verifier / abandoned obligation (griefing by doing nothing)

**Attack:** the judge simply never acts, freezing the funds forever.

**Defense — every escrow has a unilateral exit:**
- CommitStake: after the deadline, **anyone** may call `slashExpired` (`CommitStake.sol:158-166`); silence converges to the same outcome as a failed commitment, so going silent buys the verifier nothing. Resolution and expiry windows cannot overlap: `resolve` requires `block.timestamp <= deadline` (`CommitStake.sol:132`), `slashExpired` requires `> deadline` (`CommitStake.sol:161`).
- AgentBond: an obligation opened with a non-zero deadline lets the **agent self-release** after expiry (`release`, `AgentBond.sol:171-174`) — no enforcer can hold a bond hostage indefinitely.
- StreamPay: either party can `cancel` at any time (`StreamPay.sol:186-203`); the recipient keeps exactly the vested part, the sender reclaims the rest, so neither side can freeze the other's money.
- Tested: `testFuzz_silentVerifier_expiryPaysBeneficiary` (random late caller), `test_agentSelfRelease_afterDeadline`, `test_cancel_splitsCorrectly`, plus the invariant handlers which fuzz expiry/self-release paths across 150,000 calls.

### 3. Griefing via dust / repeated locks

**Attack:** lock an agent's bond in many tiny obligations, or open dust streams, to clog accounting.

**Defense:** every lock spends real allowance the agent granted, so the total griefable amount equals the cap the agent chose; zero-amount operations revert everywhere (`AMOUNT_ZERO` / `DEPOSIT_ZERO` checks); per-stream/per-commitment accounting is isolated (no shared pool), proven by `invariant_perStreamConservation` and `test_secondStream_cannotDrainFirst` — N dust entries can never touch each other's funds.

### 4. Front-running

**Attack surfaces considered:**
- *Allowance race (AgentBond):* an enforcer sees the agent's `setSlashAllowance(e, 0)` revocation in the mempool and front-runs it with `lock`. Outcome: it can lock at most the **previously granted** cap — funds the agent had already put at that enforcer's discretion. No privilege escalation; equivalent to the enforcer acting a block earlier. The agent's exposure bound (the cap) is never exceeded — enforced by the `ALLOWANCE` check (`AgentBond.sol:145`) and the `invariant_bondEquation` campaign.
- *Withdraw vs. cancel race (StreamPay):* whichever lands first, the recipient receives exactly the vested amount and the sender exactly the remainder — `cancel` computes the split at execution time (`StreamPay.sol:191-193`). Order cannot change anyone's total. Proven by `testFuzz_cancelSplitsExactly` (random pre-withdrawals before cancel) and `invariant_withdrawNeverExceedsVested`.
- *Resolve vs. expiry race (CommitStake):* the strict `<= deadline` / `> deadline` split makes the two paths mutually exclusive in any ordering; `NOT_ACTIVE` guards make the loser of the race a clean revert, never a double payout (`test_cannotDoubleResolve`, `invariant_exactlyOnePayout`).
- There is no price, auction, or oracle anywhere in the stack — the classic value-extraction front-running targets do not exist.

### 5. Reentrancy

**Attack:** a token (or creditor/beneficiary contract) re-enters during a transfer to double-withdraw or double-slash.

**Defense — belt and suspenders:**
- Every state-changing function is `nonReentrant` (single-slot guard, each contract's lines 12-25).
- Checks-effects-interactions: status flips and accounting updates happen **before** any external transfer in every payout path (`StreamPay.cancel` sets `Ended` + freezes `withdrawn` before paying, `StreamPay.sol:196-200`; `CommitStake.resolve/claim/slashExpired` set terminal status first; `AgentBond.slash` debits `locked`/`bond` first).
- Tested with hostile tokens that actively re-enter: `test_reentrancy_noDoublePay` (StreamPay), `test_reentrancy_noDoublePay_onClaim/onSlash` (CommitStake), `test_reentrantSlash_blocked` (AgentBond) — the reentry attempt itself must fail, not just the theft.

### 6. Insolvency / cross-account drain (the quiet killer)

**Attack:** exploit bookkeeping drift — e.g. a fee-on-transfer token credits more than arrived — so one user's withdrawal is paid from another's escrow.

**Defense:** all three contracts record **balance-delta custody** on the way in (`received = balanceOf(after) - balanceOf(before)`, e.g. `StreamPay.sol:116-119`): the books can only ever claim what physically arrived. This is the property the invariant campaigns hammer hardest — solvency is asserted as *real token balance == independently tracked flows*, never as the contract agreeing with itself:
- `invariant_solvent_flowConservation` (all three) — 10,000 runs × depth 15 = 150,000 randomized calls each, zero violations.
- `invariant_bondEquation` (AgentBond): `free + locked == deposits − slashed − withdrawn` against a ghost ledger built from observed transfers only.
- `test_feeOnTransfer_escrowStaysSolvent` / `test_feeOnTransfer_solvent_bothCanExit`: explicit hostile-token scenarios.

### 7. Privileged-role rug

**Attack:** admin drains the contracts or upgrades the logic.

**Defense:** structural — there is no owner, no admin function, no upgrade hook, no pausability, and no `selfdestruct` in any of the three contracts. The only addresses that can ever move a given escrow's funds are the ones named in that escrow's record. Nothing to compromise, nothing to subpoena.

## What this model does *not* cover

- **Economic design of enforcers/verifiers** built on top — a badly designed enforcer can misuse the capacity an agent grants it (within the cap). Audit the policy layer separately.
- **Key management** of the participating EOAs/agents.
- **Arc consensus / RPC layer** below the EVM.
- Formal verification (Certora et al.) is explicitly out of scope for this phase; the assurance here is adversarial testing + fuzz + invariant campaigns with honest, reproducible numbers.
