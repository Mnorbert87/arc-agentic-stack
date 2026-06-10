# CommitStake — verification notes

Commitment escrow: a staker locks USDC behind a goal; a chosen verifier marks pass (staker reclaims) or fail (stake goes to the beneficiary); past the deadline with no answer, **anyone** can slash — a silent verifier can't freeze funds. Ownerless; escrow tracked by real balance delta.

## Invariants (stated, then proven)

| # | Invariant | Test |
|---|---|---|
| I1 | **Exactly-one payout (XOR):** every stake reaches the staker *or* the beneficiary — never both, never more than the stake, and a terminal state implies the full amount went to the one correct side. Double payout is impossible. | `invariant_exactlyOnePayout` |
| I2 | **Solvency (pure flow):** the contract's actual USDC balance always equals stakes-in minus payouts-out, where payouts are measured from the recipients' real balance deltas. | `invariant_solvent_flowConservation` |
| I3 | **Solvency (book):** balance covers all Active + Passed commitments. | `invariant_solvent` (adversarial suite) |

The handler drives random `create / resolve(pass|fail) / claim / slashExpired / warp` sequences, including randomized `slashExpired` callers (it is permissionless by design).

## Results (actual local run, forge 1.7.1 / solc 0.8.24)

- **25 tests, 0 failed.** No invariant violation was found in any campaign.
- Each of the 3 invariants: **10,000 runs × depth 15 = 150,000 randomized calls, 0 reverts** (`fail_on_revert = true` on the new campaigns).
- Each of the 6 fuzz properties: **10,000 runs** — pass lifecycle makes the staker exactly whole, fail pays the beneficiary exactly once, silent-verifier expiry from a random caller, single-surface XOR property, plus non-verifier / non-staker access fuzz.
- Plus 12 unit tests and a hostile-token suite (reentrancy on claim and slash, fee-on-transfer solvency, no-return token).

## Reproduce

```bash
forge install foundry-rs/forge-std   # once; lib/ is gitignored
forge test                            # fuzz + invariant config lives in foundry.toml
```
