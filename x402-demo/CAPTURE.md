# Recording note (for Rendező — optional)

A 15–20s clip for the submission video. Nothing to host: it is a local Node server +
the buyer agent, captured as a terminal recording.

## Record

```bash
cd contracts/x402-demo
# optional asciinema cast, or just screen-capture the terminal:
./run.sh
```

The whole lifecycle prints in ~25s. For a tight 15–20s cut, trim to the four beats:

1. **402** — `← HTTP 402 Payment Required` (the server refuses without payment).
2. **PAY** — `✓ createStream …/tx/0x…` (the agent opens the on-chain stream).
3. **CONSUME** — the three `call N: 200 — settled $0.0xx …/tx/0x…` lines (each 200 is a
   real on-chain settlement — show one arcscan tab opening on a tx hash).
4. **SETTLE** — `reclaimable … ✓ cancel …` (unused budget comes back).

Punchline overlay: **"the agent paid per API call, on-chain, with no human in the loop."**

The verified transcript + clickable arcscan links are in `SAMPLE_RUN.md`.
