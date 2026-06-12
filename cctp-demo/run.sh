#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Cross-chain capital onboarding for agents — CCTP V2 mini-demo.
#
# An agent's bond capital arrives from ANOTHER testnet (Base Sepolia) via Circle
# CCTP V2, and is deposited straight into AgentBond on Arc. One runnable script,
# real transactions on both chains, no Bridge Kit, no API key (the attestation
# service is the public Iris sandbox).
#
# Flow:
#   [Base Sepolia]  approve USDC -> TokenMessengerV2.depositForBurn(dest=Arc, Fast)
#         │                                   (burns USDC, emits the CCTP message)
#         ▼
#   [Iris sandbox]  poll /v2/messages/6?transactionHash=... until attested  (public, no key)
#         ▼
#   [Arc]           MessageTransmitterV2.receiveMessage(message, attestation)  (mints USDC)
#         ▼
#   [Arc]           approve USDC -> AgentBond.deposit(amount)   (capital becomes the bond)
#
# Usage:   ./run.sh                 # uses defaults below
# Env:     DEPLOYER_PRIVATE_KEY (burner; sourced from ../../../commit-stake/.env or your shell)
#          NEVER a personal key. The burner 0x2e36..A08a is the same EOA on both chains.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ---- config -----------------------------------------------------------------
BASE_RPC="${BASE_RPC:-https://sepolia.base.org}"
ARC_RPC="${ARC_RPC_URL:-https://rpc.testnet.arc.network}"
IRIS="https://iris-api-sandbox.circle.com"

SRC_DOMAIN=6          # Base Sepolia CCTP domain
DST_DOMAIN=26         # Arc CCTP domain
AMOUNT="${AMOUNT:-1000000}"   # 1 USDC (6 decimals) — the capital to onboard

# Canonical CCTP V2 contracts (same address on every chain)
TOKEN_MESSENGER=0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA
MESSAGE_TRANSMITTER=0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275
# USDC per chain
USDC_BASE=0x036CbD53842c5426634e7929541eC2318f3dCF7e
USDC_ARC=0x3600000000000000000000000000000000000000
# AgentBond on Arc (the stack's trust layer)
AGENT_BOND=0xB9b4d476bC383eE2951a3eC3A22779458cdBf8e0

PK="${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY (burner) in env}"
BURNER="${DEPLOYER_ADDRESS:-$(cast wallet address --private-key "$PK")}"
RESULT="$(dirname "$0")/result.json"

hr(){ printf '─%.0s' {1..70}; echo; }
say(){ echo "» $*"; }
B32() { echo "0x000000000000000000000000${1:2}"; } # address -> bytes32 (left-padded)

# ---- 0) preflight: source funding ------------------------------------------
hr; say "Preflight — burner $BURNER"
SRC_ETH=$(cast balance "$BURNER" --rpc-url "$BASE_RPC")
SRC_USDC=$(cast call "$USDC_BASE" "balanceOf(address)(uint256)" "$BURNER" --rpc-url "$BASE_RPC")
ARC_GAS=$(cast call "$USDC_ARC" "balanceOf(address)(uint256)" "$BURNER" --rpc-url "$ARC_RPC")
say "Base Sepolia: ETH(gas)=$SRC_ETH  USDC=$SRC_USDC"
say "Arc:          USDC(gas)=$ARC_GAS"
if [ "$SRC_ETH" = "0" ] || [ "$(printf '%s' "$SRC_USDC" | cut -d' ' -f1)" -lt "$AMOUNT" ]; then
  echo
  echo "✋ Source chain not funded. Fund the burner on Base Sepolia, then re-run:"
  echo "   1) USDC : https://faucet.circle.com  -> address $BURNER, chain Base Sepolia (gives 10 USDC)"
  echo "   2) gas  : a Base Sepolia ETH faucet  -> ~0.01 ETH to $BURNER"
  echo "   (Arc-side gas is USDC and the burner already holds it.)"
  exit 2
fi

# ---- 1) source: approve + depositForBurn (Fast Transfer) --------------------
hr; say "[Base Sepolia] approve USDC -> TokenMessengerV2"
TX_APPROVE=$(cast send "$USDC_BASE" "approve(address,uint256)" "$TOKEN_MESSENGER" "$AMOUNT" \
  --rpc-url "$BASE_RPC" --private-key "$PK" --json | python3 -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])")
say "approve tx: $TX_APPROVE"

MINT_RECIPIENT=$(B32 "$BURNER")
DEST_CALLER=0x0000000000000000000000000000000000000000000000000000000000000000  # anyone may receive
MAX_FEE=$(( AMOUNT / 100 ))        # 1% cap; the real Fast fee is a few micro-USDC
MIN_FINALITY=1000                  # 1000 = Fast Transfer (soft finality)

say "[Base Sepolia] depositForBurn  amount=$AMOUNT dest=Arc($DST_DOMAIN) maxFee=$MAX_FEE finality=Fast"
TX_BURN=$(cast send "$TOKEN_MESSENGER" \
  "depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)" \
  "$AMOUNT" "$DST_DOMAIN" "$MINT_RECIPIENT" "$USDC_BASE" "$DEST_CALLER" "$MAX_FEE" "$MIN_FINALITY" \
  --rpc-url "$BASE_RPC" --private-key "$PK" --json | python3 -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])")
say "depositForBurn (burn) tx: $TX_BURN"

# ---- 2) attestation: poll the public Iris sandbox --------------------------
hr; say "[Iris sandbox] polling attestation for src tx $TX_BURN (public, no API key)"
MSG=""; ATT=""
for i in $(seq 1 60); do
  RESP=$(curl -s "$IRIS/v2/messages/$SRC_DOMAIN?transactionHash=$TX_BURN")
  STATUS=$(printf '%s' "$RESP" | python3 -c "import json,sys
try:
 d=json.load(sys.stdin);m=d.get('messages',[{}])[0];print(m.get('status',''))
except: print('')" )
  if [ "$STATUS" = "complete" ]; then
    MSG=$(printf '%s' "$RESP" | python3 -c "import json,sys;print(json.load(sys.stdin)['messages'][0]['message'])")
    ATT=$(printf '%s' "$RESP" | python3 -c "import json,sys;print(json.load(sys.stdin)['messages'][0]['attestation'])")
    say "attestation ready after ${i} polls"; break
  fi
  say "  poll $i: status='${STATUS:-pending}'..."; sleep 6
done
[ -n "$ATT" ] || { echo "✋ attestation did not finalize in time — re-run later with the same burn tx."; exit 3; }

# ---- 3) Arc: receiveMessage (mint) -----------------------------------------
hr; say "[Arc] MessageTransmitterV2.receiveMessage -> mint USDC to burner"
TX_RECEIVE=$(cast send "$MESSAGE_TRANSMITTER" "receiveMessage(bytes,bytes)" "$MSG" "$ATT" \
  --rpc-url "$ARC_RPC" --private-key "$PK" --json | python3 -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])")
say "receiveMessage (mint) tx: $TX_RECEIVE"
ARC_USDC_AFTER=$(cast call "$USDC_ARC" "balanceOf(address)(uint256)" "$BURNER" --rpc-url "$ARC_RPC")
say "Arc USDC after mint: $ARC_USDC_AFTER"

# ---- 4) Arc: the bridged capital becomes the agent's bond ------------------
hr; say "[Arc] approve USDC -> AgentBond, then deposit (bridged capital -> bond)"
BOND_BEFORE=$(cast call "$AGENT_BOND" "bond(address)(uint256)" "$BURNER" --rpc-url "$ARC_RPC")
TX_APPROVE_AB=$(cast send "$USDC_ARC" "approve(address,uint256)" "$AGENT_BOND" "$AMOUNT" \
  --rpc-url "$ARC_RPC" --private-key "$PK" --json | python3 -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])")
TX_DEPOSIT=$(cast send "$AGENT_BOND" "deposit(uint256)" "$AMOUNT" \
  --rpc-url "$ARC_RPC" --private-key "$PK" --json | python3 -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])")
BOND_AFTER=$(cast call "$AGENT_BOND" "bond(address)(uint256)" "$BURNER" --rpc-url "$ARC_RPC")
say "AgentBond bond: $BOND_BEFORE -> $BOND_AFTER  (approve $TX_APPROVE_AB, deposit $TX_DEPOSIT)"

# ---- result map -------------------------------------------------------------
hr; say "DONE — cross-chain capital onboarded into AgentBond"
cat > "$RESULT" <<JSON
{
  "amount_usdc": "$AMOUNT",
  "burner": "$BURNER",
  "base_sepolia": {
    "approve": "$TX_APPROVE",
    "depositForBurn": "$TX_BURN",
    "explorer": "https://sepolia.basescan.org/tx/$TX_BURN"
  },
  "arc": {
    "receiveMessage_mint": "$TX_RECEIVE",
    "agentbond_approve": "$TX_APPROVE_AB",
    "agentbond_deposit": "$TX_DEPOSIT",
    "explorer_mint": "https://testnet.arcscan.app/tx/$TX_RECEIVE",
    "explorer_deposit": "https://testnet.arcscan.app/tx/$TX_DEPOSIT",
    "bond_before": "$BOND_BEFORE",
    "bond_after": "$BOND_AFTER"
  }
}
JSON
say "result -> $RESULT"
