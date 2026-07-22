#!/usr/bin/env bash
# One-command setup for the Option B manual demo: fresh deploy + fund actors.
# Run this off-stage, before presenting -- it's scaffolding, not part of the
# live story. After this, ./script/manual-demo.sh starts right at step1.
# Requires anvil already running (its own terminal, default port).
# These are well-known, public Anvil test defaults -- fine for local demo use only.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."   # always run from repo root, regardless of caller's cwd

export RPC="${RPC:-http://127.0.0.1:8545}"
export DEPLOYER_PRIVATE_KEY="${DEPLOYER_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

echo "== Deploying fresh contracts =="
forge script script/DeployCreditVault.s.sol --rpc-url "$RPC" --broadcast

echo "== Reading actual deployed addresses (never hardcoded -- avoids stale-address drift across redeploys) =="
BROADCAST="broadcast/DeployCreditVault.s.sol/31337/run-latest.json"
addr() { jq -r --arg name "$1" '.transactions[] | select(.contractName==$name and .transactionType=="CREATE") | .contractAddress' "$BROADCAST"; }
USDR=$(addr "MockUSDr")
AMFI=$(addr "MockAmFiCredit")
MARKET=$(addr "LendingMarket")
VAULT=$(addr "CuratedCreditVault")

cat > script/.demo-addrs.sh <<EOF
export USDR=$USDR
export AMFI=$AMFI
export MARKET=$MARKET
export VAULT=$VAULT
EOF

echo "MockUSDr:           $USDR"
echo "MockAmFiCredit:     $AMFI"
echo "LendingMarket:      $MARKET"
echo "CuratedCreditVault: $VAULT"

# Anvil's fixed default dev accounts -- these do NOT drift across redeploys
# (unlike the contract addresses above, which depend on deploy nonce).
LENDER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
BORROWER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
LIQUIDATOR=0x90F79bf6EB2c4f870365E785982E1f101E93b906
PK0="$DEPLOYER_PRIVATE_KEY"

echo "== Funding actors (off-stage setup, not part of the live story) =="
cast send "$USDR" "transfer(address,uint256)" "$LENDER"     100000000000            --private-key "$PK0" --rpc-url "$RPC" >/dev/null
cast send "$USDR" "transfer(address,uint256)" "$LIQUIDATOR" 50000000000             --private-key "$PK0" --rpc-url "$RPC" >/dev/null
cast send "$AMFI" "transfer(address,uint256)" "$BORROWER"   50000000000000000000000 --private-key "$PK0" --rpc-url "$RPC" >/dev/null

echo ""
echo "Ready. Run ./script/manual-demo.sh to start the live walkthrough at step1."
