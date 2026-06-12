# Cold Economic Review — CommitStake v2 mechanism (pre-implementation)

Independent cold read of VERIFIER_ECONOMICS.md (no code, economist's eye, adversarial
mandate). Findings classified per the Phase-1 standard: **mechanism flaw** (fix warranted)
vs **re-confirmation of an already-disclosed trust assumption** (not a finding).

## Genuine mechanism findings → fix

- **G1+G2 — challenge bond denominated against `stake`, but the capturable prize is
  `stake + slice`.** Not in §9's disclosed assumptions (those cover beneficiary–arbiter,
  not staker≡beneficiary). Calc: attacker risk = bond (0.25–0.5×stake); gain on an erroneous
  overturn = `slice` (1.5×stake), because the stake leg nets to zero when one principal holds
  both staker and beneficiary; break-even arbiter error ≈ 17%. **Fix:** size `challengeBond`
  against `slice`, not `stake`.
- **G9 — "harmed party gets everything" over-rewards (slice > actual damage), and that
  surplus is what powers G1.** **Fix:** compensate harmed party for *actual* damage; route the
  surplus (slice − damage) to a burn/sink so no challenger is ever over-rewarded.
- **G7 — the invariant `slice > stake + maxAccruableFee` silently assumes P(overturn)=1.**
  For subjective goals with low overturn probability, lying can be +EV in aggregate. **Fix:**
  restate as `P(overturn) × slice > maxAccruableFee`; Trust assumptions must say enforcement
  is probabilistic.
- **G3 — liveness branch fee-stream cancellation unspecified.** An absent verifier could keep
  streaming the staker's fee while being made whole on stake. **Fix:** `slashVerifierExpired`
  itself cancels the verifier's fee stream (no-show = zero fee). *(Shipped in the deployed contract.)*
- **G5 — rounding/margin.** `slice ≥ stake + maxAccruableFee + ε`, round slice **up**.

## NOT findings — re-confirmation of disclosed Trust assumptions (review noise)

- **G6 — beneficiary+arbiter collusion.** §9 explicitly states this is unprotected. The review
  ranked it "dominant/cheapest attack" — exactly the inflation to guard against. Downgraded to
  confirmation of §9. (Surplus-burn from G9 incidentally lowers its upside; not a closure.)
- **G4 — staker fee-skim via cancel timing.** The flip side of the already-accepted
  timing-based fee-gating caveat (§7), not a new mechanism flaw. Optional mitigation: a minimum
  guaranteed fee on any valid resolve.

## Genuine design fork (mechanism, not a disclosed assumption) — owner's call

- **G8 — arbiter silence "fails closed" favours a lying verifier** (steer toward a lazy arbiter,
  the false verdict stands). Alternative: unadjudicated dispute → slice to challenger — but that
  is weaponizable in reverse (challenger bribes arbiter to stay silent → auto-win). Neither
  default is clean. **Decision pending from owner.**

## Outcome

All five mechanism fixes were incorporated into the shipped CommitStakeV2: the challenge bond
is sized against the slice (G1+G2), the surplus above damage is burned to `0x…dEaD` (G9), the
slashing invariant is stated probabilistically (G7), `slashVerifierExpired` cancels the fee
stream (G3), and the slice carries the G5 rounding margin. G8 was resolved per the project
owner's call: arbiter silence fails closed, with the reasoning written up in
VERIFIER_ECONOMICS.md §9. The two on-chain burns in the submission are the G9 fix firing.
