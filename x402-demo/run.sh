#!/usr/bin/env bash
# Runs the full x402 pay-per-inference demo end-to-end against Arc Testnet.
#
#   AGENT_PRIVATE_KEY  read at runtime from contracts/commit-stake/.env (the burner) —
#                      it is NEVER written into this folder.
#   SERVER_PRIVATE_KEY read from this folder's .env (a dedicated demo burner; gitignored).
#
# Output is teed to demo-run.log for the README / screen recording.
set -euo pipefail
cd "$(dirname "$0")"

# 1) server (payee) key + demo params from local .env.
set -a; . ./.env; set +a

# 2) agent (payer) key from the existing gitignored location — not copied here.
#    Read last so it wins over any placeholder line in .env.
AGENT_PRIVATE_KEY="$(grep -E '^DEPLOYER_PRIVATE_KEY=' ../commit-stake/.env | cut -d= -f2-)"
export AGENT_PRIVATE_KEY

[ -z "${AGENT_PRIVATE_KEY:-}" ]  && { echo "missing AGENT_PRIVATE_KEY"; exit 1; }
[ -z "${SERVER_PRIVATE_KEY:-}" ] && { echo "missing SERVER_PRIVATE_KEY"; exit 1; }

LOG=demo-run.log; : > "$LOG"
echo "=== x402 pay-per-inference on Arc — $(date -u +%FT%TZ) ===" | tee -a "$LOG"

# clear any stale server on the port from a previous run
pkill -9 -f "$(pwd)/server.js" 2>/dev/null || true
sleep 1

# ensure the server wallet can pay its own withdraw gas
node bootstrap.js 2>&1 | tee -a "$LOG"

# start the 402-gated server (output appended directly so $! is node's real PID)
node server.js >>"$LOG" 2>&1 &
SERVER_PID=$!
trap 'kill -9 $SERVER_PID 2>/dev/null || true' EXIT

# wait for it to listen
for i in $(seq 1 30); do
  curl -s -o /dev/null "http://localhost:${PORT:-4021}/inference" && break || sleep 0.5
done

# run the autonomous buyer agent
node agent.js 2>&1 | tee -a "$LOG"

echo "=== done — full log in $LOG ===" | tee -a "$LOG"
