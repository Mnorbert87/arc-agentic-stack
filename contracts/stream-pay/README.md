# StreamPay — verification notes

Linear USDC payment streaming: sender escrows a deposit that vests to the recipient per second between `start` and `stop`; withdraw anytime, either party may cancel (recipient keeps the vested part, sender reclaims the rest). Ownerless; escrow tracked by real balance delta.

## Invariants (stated, then proven)

| # | Invariant | Test |
|---|---|---|
| I1 | **Solvency (pure flow):** the escrow's actual USDC balance always equals deposits-in minus payouts-out, summed over all streams — one stream can never be paid from another's funds. | `invariant_solvent_flowConservation` |
| I2 | **Vesting bound:** the recipient's cumulative real payout never exceeds the linear vesting cap recomputed *in the test* from the stream's immutable parameters (`deposit × elapsed ÷ duration`) — never by asking the contract. | `invariant_withdrawNeverExceedsVested` |
| I3 | **Per-stream conservation:** recipient payout + sender refund ≤ deposit at all times, and == deposit exactly once a stream is terminal. | `invariant_perStreamConservation` |

The handler drives random `createStream / withdraw / cancel / warp` sequences across 2 senders and 2 recipients, with past and future start times and forward-only clock.

## Results (actual local run, forge 1.7.1 / solc 0.8.24)

- **25 tests, 0 failed.** No invariant violation was found in any campaign.
- Each of the 3 invariants: **10,000 runs × depth 15 = 150,000 randomized calls, 0 reverts** (`fail_on_revert = true`).
- Each of the 5 fuzz properties: **10,000 runs** — exact vested payout at any point in a stream's life, exact cancel split (with random pre-withdrawals), vesting monotonicity, solvency split (`testFuzz_solventSplit`), stranger access fuzz.
- Plus 13 unit tests, terminal-view probes, and a hostile-token suite (reentrancy, fee-on-transfer, cross-stream drain).

## Reproduce

```bash
forge install foundry-rs/forge-std   # once; lib/ is gitignored
forge test                            # fuzz + invariant config lives in foundry.toml
```
