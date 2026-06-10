# AgentBond — verification notes

Reputation-bond primitive: an agent posts a USDC bond, grants capped slashing allowance to enforcer contracts, which lock slices behind obligations and either release or slash them. Ownerless; USDC custody tracked by real balance delta.

## Invariants (stated, then proven)

| # | Invariant | Test |
|---|---|---|
| I1 | **Solvency (book vs reality):** the contract's actual USDC balance always equals the sum of every agent's recorded bond. | `invariant_solvent_bookMatchesBalance` |
| I2 | **Solvency (pure flow):** the balance also equals independently observed inflows − withdrawals − slashes. The contract can never pay out more than was paid in. | `invariant_solvent_flowConservation` |
| I3 | **Bond equation:** per agent, `free + locked == deposits − slashed − withdrawn`, where the right side is a *ghost ledger* built only from observed ERC-20 transfers — never from the contract's own books. | `invariant_bondEquation` |
| I4 | **No over-commitment:** `locked ≤ bond` for every agent, always. | `invariant_lockedNeverExceedsBond` |

The invariant handler drives random `deposit / withdraw / grant / lock / release / selfRelease / slash / warp` sequences from 3 agents, 2 enforcers and 2 disjoint creditors, with forward-only time (Arc timestamps are non-decreasing).

## Results (actual local run, forge 1.7.1 / solc 0.8.24)

- **29 tests, 0 failed.** No invariant violation was found in any campaign.
- Each of the 4 invariants: **10,000 runs × depth 15 = 150,000 randomized calls, 0 reverts** (`fail_on_revert = true` — the handler is never allowed to silently skip via revert).
- Each of the 5 fuzz properties (`AgentBondFuzz.t.sol`): **10,000 runs** — exact round-trip, exact free-bound, exact slash payout, exact release restore, stranger access fuzz.
- Plus 19 unit tests and a hostile-token reentrancy suite (`AgentBondAdversarial.t.sol`).

## Reproduce

```bash
forge install foundry-rs/forge-std   # once; lib/ is gitignored
forge test                            # fuzz + invariant config lives in foundry.toml
```
