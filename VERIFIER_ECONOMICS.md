# Verifier Economics (CommitStake v2)

**Status: FINALIZED SPEC (all design forks + cold-economic-review fixes incorporated) —
owner's pre-contract sight-check pending; no contract deployed yet.** This document is the
authoritative mechanism specification the implementation must match.

CommitStake v1 makes the *staker* accountable: lock USDC behind a goal, a verifier
judges it, the stake is reclaimed on success or slashed to a beneficiary on failure.
The verifier itself is **trusted and unaccountable** — it can stay silent, or lie, at
no cost. v2 closes that gap by giving the verifier *skin in the game*, reusing the two
primitives the stack already ships (AgentBond, StreamPay) rather than inventing new
trust machinery.

The central discipline of this document — carried over from the Phase 1 audit standard
— is **intellectual honesty about where trust lives**. We do **not** claim the chain can
detect a lie. We split the verifier's two failure modes, enforce the one the chain *can*
prove, and name explicitly the root of trust for the one it cannot.

---

## 1. The two failure modes (the spine)

| | What the verifier does wrong | On-chain provable? | How v2 handles it |
|---|---|---|---|
| **Liveness** | Never resolves before the deadline | **Yes** — deadline passed, no `resolve` call | Trustless. Verifier's bonded slice is slashed (**`damage` → staker, surplus → burn**, §7a); **the staker is made whole** (stake returned + accrued-fee damage). |
| **Correctness** | Resolves, but lies (false `pass` / false `fail`) | **No** — the chain cannot know the off-chain truth | Bounded: a two-sided challenge routes to a **named, pre-agreed arbiter** the staker opts into at entry. |

Everything below follows from this split. Most "agent reputation / slashing" designs
blur it and implicitly pretend the chain detects lies. We refuse that.

---

## 2. The bug fix (liveness inversion)

v1 has a genuine injustice. `slashExpired` (CommitStake.sol:158) lets *anyone* push the
stake to the beneficiary once the deadline passes with no resolution. That punishes the
**staker** for the **verifier's** no-show — the staker loses the stake because the judge
never showed up.

v2 inverts it:

- On verifier silence past the deadline, the **verifier's bonded slice is slashed** (the
  at-fault party pays): the staker receives **`damage`** (the fee that accrued to the
  no-show verifier before the atomic cancel; the arbiter cost is zero on this branch) and
  the **surplus is burned** (§7a), and **the staker's stake is returned**, not handed to
  the beneficiary.
- This is a strictly better mechanism *and* it is fully on-chain provable (no oracle, no
  arbiter). It is the clean negative branch we seed first.

We present this in the submission narrative as a **fix**, not a feature: v1 mispriced who
bears the cost of a liveness failure; v2 prices it to the party that caused it.

---

## 3. State machine — the verdict is never instantly final

A challenge can only unwind a verdict if money has not already moved. So payouts are
gated behind a new finalize step.

```
                         create (stake escrowed, verifier slice locked in AgentBond)
                              │
                              ▼
                          [Active] ──────────────► (deadline passes, no resolve)
                              │                              │
                       resolve(pass|fail)                    ▼
                              │                       [Expired] → slashVerifier:
                              ▼                         slice slashed: damage → staker,
                        [Resolved] ── opens ─────►       surplus → burn; stake returned
                              │   challenge window
                  ┌───────────┴───────────┐
        (window closes, no challenge)   challenge(by harmed party + bond)
                  │                           │
                  ▼                           ▼
              finalize                   [Challenged] ── arbiter rules / times out
                  │                           │
                  ▼                  ┌────────┴─────────┐
            payouts run           uphold              overturn
        (stake per verdict,         │                   │
         verifier slice             ▼                   ▼
         released, fee          payouts run        slice slashed: damage →
         stream settles)        per verdict;       harmed party, surplus →
                                challenger bond    burn; challenge bond refunded
                                slashed (anti-grief)
```

**No stake, fee, or bond moves before `finalize` (or a terminal arbiter outcome).** The
challenge window is configurable (minutes for the demo, hours in production) but it always
exists — otherwise the challenge arm is paper.

---

## 4. The bonded verifier — reuse AgentBond, write no new slashing code

v2's CommitStake is an **AgentBond enforcer**. It writes *zero* new custody/slashing
logic; it drives the audited AgentBond obligation lifecycle. This is itself the
composability proof: CommitStake v2 is built **on** AgentBond, not beside it.

Lifecycle, mapped to the real AgentBond surface (`agent-bond/src/AgentBond.sol`):

1. **Opt-in (verifier, once):** `agentBond.setSlashAllowance(commitStakeV2, capacity)` —
   the verifier grants CommitStake v2 a revolving slashing capacity, exactly like an
   ERC-20 approve.
2. **Lock (at `create`):** CommitStake calls
   `agentBond.lock(verifier, creditor = address(this), slice, bondDeadline)`. This pulls
   `slice` from the verifier's **free** bond. AgentBond already reverts with
   `INSUFFICIENT_BOND` if the verifier doesn't have the free capacity — so a verifier
   **cannot take on more commitments than its free bond covers.** Hit-and-run (many
   commitments, one bond) is structurally impossible, not merely discouraged.
3. **Resolve (clean path):** on a finalized, unchallenged-or-upheld verdict, CommitStake
   calls `agentBond.release(id)` — the slice returns to the verifier's free bond and the
   revolving capacity is restored.
4. **Slash (bad path):** on liveness failure or an overturned false verdict, CommitStake
   calls `agentBond.slash(id)`. AgentBond pays the slice to `creditor` (= CommitStake), which
   forwards only **`damage`** to the wronged party determined at finalize (staker for liveness /
   false-fail; beneficiary for false-pass) and **burns the surplus** (§7a). The arbiter never
   sets that number — it rules pass/fail only.

**Why `creditor = address(this)` (CommitStake), not a fixed party:** the wronged party
isn't known at lock time (a false `fail` harms the staker; a false `pass` harms the
beneficiary). AgentBond fixes the creditor at `lock`. So CommitStake takes custody of the
slashed slice and routes it at finalize. Funds are real (balance-delta), simply forwarded.

**Sizing rule — the central formula of this document.** The slice must make a lie a loss,
not merely a reputational hit. Two bounds, stated honestly:

```
   probabilistic (the real bound):  P(overturn) × slice   >   maxAccruableFee
   single-shot floor (P=1, conservative):  slice  >  stake + maxAccruableFee + arbiterFee + ε
   default:                                 slice  =  150% × stake          (round UP)
   large-fee guard: if maxAccruableFee ≥ 50% × stake, raise slice to
                                            > stake + maxAccruableFee + arbiterFee + ε
```

The `arbiterFee` term is **not optional padding** — it is what keeps the §7a `damage` strictly
below the slice (`damage = feeAccruedToLyingVerifier + arbiterFee ≤ maxAccruableFee + arbiterFee
< slice`), so the surplus burned on every slash is strictly positive. Without it, an
`arbiterFee` chosen up to the slice would let `damage` reach the whole slice and a colluding
arbiter would recapture it — see §9. **Enforced in code** as
`require(verifierSlice > amount + feeDeposit + arbiterFee, "SLICE_TOO_SMALL")` at `create`.

The **single-shot floor** assumes the lie is always caught and overturned (`P(overturn)=1`):
under it, lying is a net loss in one play. But `P(overturn)` is **not observable on-chain**,
and for subjective goals it is well below 1 — so the honest bound is the **probabilistic**
one, and where it cannot be met in a single play the incentive is carried by the **repeated
game** (accumulating bond-reputation and future commissions), not by a one-shot guarantee.
This is stated plainly in Trust assumptions (§9) — the claim is sized to the evidence.

`ε` covers fee-accrual rounding (StreamPay accrues by wall-clock, floored) and the verifier's
gas; `slice` is always rounded **up**, so the inequality is never satisfied only to a dust unit.

AgentBond enforces the rest for free: `lock` reverts with `INSUFFICIENT_BOND` if the
verifier lacks that much **free** bond, so a verifier can never be on the hook for more
commitments than its posted bond covers. Hit-and-run is structurally impossible.

**`bondDeadline`:** set to the commitment finalize-deadline **plus a buffer**. In the
normal flow CommitStake always resolves the obligation (release or slash) first. The
AgentBond deadline is only a backstop: if CommitStake itself were abandoned/buggy, the
verifier could eventually self-`release` and not be held hostage. Normal flow always wins.

---

## 5. The challenge — two-sided, harmed-party-only, bonded

- **Who may challenge:** only the party harmed by *this* verdict.
  - `fail` verdict → only the **staker** may challenge (it claims the goal *was* met).
  - `pass` verdict → only the **beneficiary** may challenge (it claims the goal was *not* met).
  - Enforced with `require(msg.sender == harmedParty)`. No open challenge right — that
    would invite spam even with a bond.
- **Challenge bond:** the challenger posts a bond up front. On a frivolous challenge
  (arbiter upholds the verifier) the challenger's bond is slashed — anti-grief.

---

## 6. The arbiter — paid for *deciding*, not for the direction; silence has a default

The challenge routes to a single **arbiter named at `create`** and knowingly accepted by
the staker when it opts into the commitment.

- **Motivation:** the arbiter is paid a **fixed fee out of the challenge bond on *both*
  outcomes** (overturn and uphold). The *fact* of ruling pays, not the direction — so the
  arbiter has no incentive to lean either way, and the challenge arm doesn't reproduce the
  liveness problem one level up (an unpaid judge doesn't judge).
- **Arbiter silence (deterministic default):** if the arbiter does not rule by its own
  deadline, the challenge **fails closed**: the original verdict stands, the challenger's
  bond is **returned** (not slashed — it wasn't proven frivolous), and the arbiter is **not
  paid**. *No ruling, no punishment, nobody profits from the deadlock.*
- **Conflict-of-interest, enforced in code (not just documented):** at `create`,
  `require(arbiter != verifier)` and `require(arbiter != staker && arbiter != beneficiary)`.
  The staker-side check is only watertight because **`staker = msg.sender` at `create`**
  (decided, see Appendix): the commitment is always created by the staker itself, so
  `arbiter != msg.sender` *is* the staker conflict check — and no third party can bind an
  unwilling staker into a commitment (the unsolicited-bind surface is closed at the same time).

**The arbiter is NOT bonded or slashed by CommitStake v2 (decided).** Bonding the arbiter
would be theater unless something could slash it — and slashing the arbiter would require
*another* judge above it, the infinite regress we are deliberately terminating. The arbiter
is the explicit, named **root of trust**: accountable by reputation and by being chosen up
front, paid for ruling, defaulting closed on silence.

This does *not* break the stack's reputation thesis — it completes it. An arbiter **may**
voluntarily hold an AgentBond bond as a pure **reputational signal** (its free bond is the
credit score anyone can read before naming it), exactly the primitive's intended use. But
CommitStake v2 **never locks or slashes the arbiter's bond** — the bond, if present, is a
public signal, not a contract-enforced stake. We state this explicitly so the narrative
stays whole without manufacturing a false constraint.

---

## 7. The fee — StreamPay composability

The verifier earns a verification fee streamed via StreamPay (`stream-pay/src/StreamPay.sol`),
the same primitive demonstrated as Stream #18 in Phase 1.

- The fee stream (staker-funded, paid to the verifier) is gated so the verifier is paid only
  for a verdict that survives to finalize: **CommitStake opens the stream itself at `create`
  and is therefore the stream `sender`; on every slash path the terminal call cancels the
  stream atomically** — the unstreamed remainder is refunded to the escrow and forwarded to
  the staker in the same transaction; the verifier keeps only what had already accrued. No
  branch depends on the staker remembering to act.
- **Liveness branch (no-show = no fee):** if the verifier never resolves, `slashVerifierExpired`
  **itself cancels the fee stream atomically** (the contract does not rely on the staker to
  remember). A verifier that does no work earns nothing. *(Spec gap closed — was unspecified.)*

**Decided: StreamPay-native, timing-based gating (option a).** The in-contract escrow
alternative would duplicate escrow logic and pull StreamPay out of the loop, weakening the
very composability thesis.

> **Honest caveat (also in Trust assumptions):** StreamPay accrues by **wall-clock**, not by
> an external event — accrual cannot be made literally conditional on `finalize`. We
> approximate "fee contingent on finalize" by setting the fee-stream window to begin at/after
> the challenge window and cancelling on a slash. This is *timing-based* gating, not
> contract-enforced conditional withdrawal.

**Why the caveat does not hurt — it is a sizing input, not a weakness.** A lying verifier
walks away with *at most* the fee accrued before the terminal call cancels the stream
atomically, while it **loses its entire bonded slice**. That `maxAccruableFee` is exactly the quantity folded into the
slashing bound of §4 (`P(overturn) × slice > maxAccruableFee`), so the timing approximation
is priced into the sizing rule rather than left as a loose end.

---

## 7a. Where the money goes — deterministic routing

Every terminal outcome routes funds by a fixed, on-chain rule (no discretion):

| Outcome | Stake | Slashed verifier slice | Challenge bond |
|---|---|---|---|
| **Clean pass** (no challenge / upheld pass) | → staker (claim) | released to verifier | n/a |
| **Clean fail** (no challenge / upheld fail) | → beneficiary | released to verifier | n/a |
| **Liveness** (silence past deadline) | **returned to staker** | harmed party (staker) gets **`damage`** (fee accrued to the no-show verifier; arbiter cost is zero on this branch); **surplus → BURN** | n/a |
| **False `fail` overturned** | → staker (corrected verdict) | harmed party (staker) gets **`damage`** (formula below); **surplus `slice − damage` → BURN** | refunded to challenger |
| **False `pass` overturned** | → beneficiary (corrected verdict) | harmed party (beneficiary) gets **`damage`**; **surplus → BURN** | refunded to challenger |
| **Frivolous challenge** (verdict upheld) | per the upheld verdict | released to verifier | challenger bond slashed → arbiter fee, remainder (fee-scale at the corrected floor below — pennies) to the (honest) verifier |

Rules behind the table:

- **`damage` is a formula, not a judgement — the arbiter rules only pass/fail, never a number.**
  On an overturn the corrected verdict *already* redirects the stake to the right party, so the
  only residual loss to compensate is narrow and mechanical:

  ```
  damage  =  feeAccruedToLyingVerifier  +  challengerArbiterFeeCost
  ```

  i.e. the fee the lying verifier managed to pull before being slashed, plus the arbiter fee the
  challenger had to spend to get the overturn. Both are on-chain-known quantities. Everything
  above that — the bulk of a slice sized at ≥150% of stake — is **surplus that is burned.** The
  arbiter's authority never expands to setting damages.

  **`damage < slice` is guaranteed, not assumed.** Both terms are bounded by create-time inputs:
  `feeAccruedToLyingVerifier ≤ feeDeposit` and `challengerArbiterFeeCost ≤ arbiterFee`. The
  sizing rule `verifierSlice > amount + feeDeposit + arbiterFee` (enforced at `create`) therefore
  forces `damage < slice` on **every** slash branch, so the burned surplus `slice − damage` is
  **strictly positive** — the §7a defense can never be zeroed out by an inflated `arbiterFee`.
  (This closes a gate-4 audit finding: before `arbiterFee` was folded into the sizing rule, an
  `arbiterFee ≥ slice` made `damage ≥ slice`, burning nothing and letting a colluding arbiter
  recapture the whole slice.)

- **Surplus → BURN, never a treasury.** The surplus goes to a dead address
  (`0x000000000000000000000000000000000000dEaD`), deterministic and owned by no one. A treasury
  would imply a recipient and a decision-maker — breaking the **ownerless, no-admin-keys** thesis,
  and creating a honeypot plus a governance burden. Burning keeps the contract trustless.

- **Why this defangs the raid (G1):** with the harmed party capped at `damage` (pennies) and the
  rest burned, a `staker≡beneficiary` attacker that challenges an honest `pass` *no longer wins
  the slice on an arbiter error* — its upside collapses to ~`damage` while it risks a
  slice-denominated challenge bond. The attack goes from +EV to deeply −EV.

- **Arbiter fee** is taken from the **challenge bond on both rulings** (the fact of ruling pays).
  The challenge bond must therefore be `≥ arbiterFee`.
- **Arbiter silence** → challenge fails closed: verdict stands, challenge bond **returned** to
  challenger, arbiter unpaid. Nobody profits from the deadlock. (Why fail-closed, not slice-to-
  challenger: see §9 — slashing the verifier for the *arbiter's* inaction would repeat, one level
  up, the very V1 injustice we fixed.)

**The challenge bond is sized against the *post-burn* capturable prize — not the stake, and
not the slice.** Two earlier rules were wrong, in opposite directions:

- The original `≥25–50% × stake` floor priced the bond against the base while the prize on an
  erroneous overturn was the **slice**. This was a live finding, not a theoretical one: with
  the bond at `0.25–0.5 × stake` and the slice at `1.5 × stake`, a `staker≡beneficiary`
  attacker (whose stake leg nets to zero) broke even at an arbiter error rate of only
  **≈17%** — the prize was extractable. That finding is what the **surplus-burn** above fixes.
- The interim `arbiterFee + k × slice (k ≥ 1)` floor over-corrected: it kept pricing the bond
  against the **pre-burn** prize even though the burn had already collapsed the capturable
  upside to `damage` (≈ pennies). The two fixes closed the same hole twice — and the bill
  landed on the **legitimate** challenger: a victim of a false `fail` would have risked a
  ~1.5×-stake bond to recover a ~1×-stake claim, which is negative-EV whenever
  `P(overturn)` is below ~60%. For exactly the subjective goals where challenges matter most,
  the rational harmed party would never challenge — the challenge arm would be paper.

With the prize already removed by the burn, the bond only needs to cover what a frivolous
challenge *costs the system* — the arbiter's fee plus a spam margin:

```
   challengeBond × P(uphold)  >  capturable upside on an erroneous overturn  =  damage (≈ pennies)
   hard floor:   challengeBond  ≥  arbiterFee + spamMargin
                 spamMargin  ≤  0.1–0.25 × slice        (small k — NOT k ≥ 1)
```

Sized this way the legitimate harmed party risks a fee-scale bond to recover a stake-scale
loss — challenging is rational whenever the claim is genuine — while a frivolous or colluding
challenger still pays the arbiter and forfeits its margin to win, at most, `damage`. A side
effect: the frivolous-branch "remainder → honest verifier" payout (table above) shrinks to
pennies, so the verifier has no incentive to *provoke* challenges either. The mirror case
(staker frivolously challenging a `fail`) is bounded identically. `challengeBond` is a
first-class create-parameter, and the band is enforced in code as floor **and** cap:
`BOND_BELOW_FLOOR` rejects an undersized bond, `BOND_ABOVE_CAP` an oversized one — so the
legitimate harmed party can never be priced out of challenging by an inflated bond, and the
upper `0.1–0.25 × slice` margin is a contract constraint, not just a sizing guideline.

## 8. On-chain seed plan (real Arc testnet tx, including a negative branch)

1. **Positive:** verifier resolves correctly, no challenge → at finalize the stake settles
   per verdict, `agentBond.release` returns the slice, fee stream settles.
2. **Negative 1 (liveness):** verifier stays silent past the deadline → `slashVerifierExpired`
   cancels the fee stream, `agentBond.slash` sends `damage` → staker, **stake returned to
   staker**, surplus burned (the bug-fix branch).
3. **Negative 2 (correctness):** verifier issues a false `fail`, staker challenges, arbiter
   overturns → `agentBond.slash`; staker compensated `damage`, **surplus → burn**, challenge
   bond refunded.

All three categorised with tx hashes, as in Phase 1.

---

## 9. Trust assumptions (explicit — claim sized to evidence)

- **Liveness arm: trustless.** "Verifier resolved before the deadline" is on-chain
  observable. Silence slashes the verifier and returns the stake with no oracle, no arbiter.
- **Correctness arm: rooted in a named, pre-agreed arbiter.** The chain cannot know whether
  the off-chain goal was met. The arbiter is the explicit root of trust — named at `create`,
  knowingly accepted by the staker on entry. It is **paid for ruling, not slashed**; its
  silence fails closed. An arbiter may hold an AgentBond bond as a public reputational signal,
  but v2 never locks or slashes it.
- **Economic backstop on the verifier — and where it is *probabilistic*, not absolute.**
  The verifier's incentive is independently aligned: with the slashing bound of §4 a lie is
  loss-making. But honesty is provably dominant in a **single play** only when the lie is
  certain to be overturned (`P(overturn)=1`). `P(overturn)` is **not on-chain observable**, and
  for **subjective goals it is below 1** — so in the one-shot game honesty is *not* guaranteed
  dominant there. The incentive in that regime is carried by the **repeated game**: the verifier's
  accumulating bond-reputation (its free bond is the public credit score) and the flow of future
  commissions it would forfeit. We say this plainly: the claim is sized to the evidence, and the
  one-shot subjective-goal case rests on reputation, not on a per-event proof.
- **What is NOT protected** (stated, not hidden):
  - **Arbiter dishonesty / beneficiary–arbiter collusion.** A corrupt arbiter (or one
    colluding with the party it should rule against) can mis-rule. Mitigations are economic
    and reputational (the arbiter is public and chosen up front), not cryptographic. *(The
    surplus-burn of §7a **caps** how much such collusion can extract to `damage`: the sizing rule
    `slice > stake + maxAccruableFee + arbiterFee` keeps `damage < slice`, so on any mis-rule the
    harmed/colluding party receives at most `damage` and the strictly-positive surplus
    `slice − damage` is burned. The cap is real, not incidental — but it does not stop a mis-rule
    from happening, so the hole is bounded, not closed.)*
  - **Arbiter liveness is part of the trust root, by design.** A challenged dispute fails closed
    if the arbiter stays silent (§6, §7a). We deliberately do **not** slash the verifier for the
    arbiter's inaction: the verifier did not choose the arbiter — the **staker** did at `create`.
    Slashing it for a third party's silence would repeat, one level up, the exact V1 injustice we
    fixed (punishing one party for another's no-show), and would let a challenger weaponise a
    bribed-silent arbiter into an automatic win. So the arbiter's reliability — its honesty *and*
    its liveness — is the content of the named trust root the staker accepts on entry.
    **Choosing a diligent arbiter is the staker's responsibility.** The arbiter is paid only on a
    ruling, so silence is its loss too.
  - **Subjective / borderline goals.** "Did the agent write *good* code?" has no objective
    on-chain answer; the arbiter's judgement is final by construction.
  - **Fee gating is timing-based** (§7 caveat), not a hard on-chain condition.

We make exactly the claims the mechanism supports, and no more.

---

## 10. Scope & fallback (risk rule)

The liveness inversion (§2) is **independently complete and valuable** — it is fully
trustless and fixes a real v1 injustice on its own.

If the challenge/arbiter arm's design or on-chain seeding slips, we ship **only** the
liveness arm (the Phase-1-approved "Option A") cleanly, rather than leaving a half-wired
challenge path. No half-finished branch ever ships.

Phase 1 QC discipline repeats at the end of Phase 2: an **independent adversarial Forge
audit** (fresh spawn, cold read) against the new contract logic before it is called done.

---

## Appendix — CommitStake v2 interface sketch (for review; not final)

```solidity
// new/changed state on Commitment
struct Commitment {
    address staker;
    address verifier;
    address beneficiary;
    address arbiter;          // NEW: named root of trust for disputes
    uint256 amount;
    uint256 bondObligationId; // NEW: AgentBond obligation holding the verifier's slice
    uint64  deadline;         // verifier must resolve by here
    uint64  challengeWindow;  // NEW: seconds after resolve during which a challenge is allowed
    // ... finalize bookkeeping (resolvedPass, challenger, challengeBond, arbiterDeadline)
    Status  status;           // Active | Resolved | Challenged | Finalized | Expired | Claimed | Slashed
}

// verifier opts in first (on AgentBond, not here):
//   agentBond.setSlashAllowance(address(commitStakeV2), capacity);

function create(
    address verifier,
    address beneficiary,
    address arbiter,          // NEW
    uint256 amount,
    uint256 verifierSlice,    // NEW: bond to lock; must satisfy sizing rule vs amount
    uint64  deadline,
    uint64  challengeWindow,  // NEW
    uint256 challengeBond,    // NEW: floored at arbiterFee + spamMargin, spamMargin <= 0.1–0.25×slice (§7a — post-burn prize)
    uint64  arbiterDeadline,  // NEW: how long the arbiter has to rule once challenged
    string calldata goal
) external returns (uint256 id);
// staker = msg.sender (DECIDED): create is always called by the staker — there is no staker
// parameter. This makes the arbiter != msg.sender check cover the staker conflict (§6) and
// closes the unsolicited-bind surface (nobody can open a commitment in someone else's name).
// BURN_ADDR = 0x000000000000000000000000000000000000dEaD  (surplus sink, §7a)
// on overturn/expiry: harmed party gets damage = feeAccruedToLyingVerifier + challengerArbiterFeeCost;
// slice − damage is transferred to BURN_ADDR. Arbiter never sets a number; it rules pass/fail only.
// require(arbiter != verifier && arbiter != msg.sender && arbiter != beneficiary)
// agentBond.lock(verifier, address(this), verifierSlice, deadline + buffer)

function resolve(uint256 id, bool passed) external;            // verifier only, <= deadline; opens challenge window
function challenge(uint256 id) external;                       // harmed party only, within window, posts challenge bond
function arbitrate(uint256 id, bool overturn) external;        // arbiter only, <= arbiterDeadline; pays arbiter fee from bond
function finalize(uint256 id) external;                        // anyone, after window/arbiter resolves; runs payouts:
                                                               //   stake per (possibly overturned) verdict,
                                                               //   agentBond.release | agentBond.slash + route slice,
                                                               //   fee stream settles clean / terminal call cancels the stream atomically on every slash path
function slashVerifierExpired(uint256 id) external;            // anyone, after deadline w/ no resolve:
                                                               //   cancels fee stream, agentBond.slash,
                                                               //   damage -> staker, surplus -> burn, stake returned
```

**Decided parameters (all forks closed):**
- Arbiter: **unbonded, not slashed** (§6); may hold a bond as a pure reputational signal only.
- Fee gating: **StreamPay-native, timing-based** (§7); liveness branch cancels the stream atomically.
- `verifierSlice` default: **150% × stake** (round up, +ε), raised per the §4 large-fee guard.
  Honest slashing bound is **probabilistic**: `P(overturn) × slice > maxAccruableFee` (§4, §9).
  **Hard create-time floor (enforced): `verifierSlice > amount + feeDeposit + arbiterFee`** — this
  keeps the §7a `damage` strictly below the slice so the surplus burned is always positive and a
  colluding arbiter cannot recapture the slice via an inflated `arbiterFee` (§4, §7a, §9).
- `challengeWindow` and the arbiter-decision deadline: **3–5 minutes for the demo seed**, both
  **create-parameters** (not constants) so production can set hours.
- `challengeBond`: **create-parameter**, floored at **`arbiterFee + spamMargin`** with
  `spamMargin ≤ 0.1–0.25 × slice` — sized against the **post-burn** capturable prize
  (`damage`, ≈ pennies), not the slice, so the legitimate harmed party is never priced out
  of challenging (§7a corrected bound).
- Slashed-slice routing: harmed party gets **`damage = feeAccruedToLyingVerifier +
  challengerArbiterFeeCost`**; **surplus → `0x…dEaD` burn**. Arbiter rules pass/fail only (§7a).
- **G8 default:** arbiter silence **fails closed** (verdict stands, bond returned) — never slash
  the verifier for the arbiter's inaction (§9 reasoning).
- **`staker = msg.sender` at `create`** — the commitment is always created by the staker; no
  `staker` parameter exists, so the `arbiter != msg.sender` check covers the staker conflict
  (§6) and the unsolicited-bind surface is closed (§6, Appendix).
