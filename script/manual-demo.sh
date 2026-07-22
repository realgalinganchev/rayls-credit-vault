#!/usr/bin/env bash
# Interactive Option-B playground: run any demo step by number, any order,
# any number of times. Human-readable amounts everywhere (raw units are what
# the chain sees; this script prints the decimal-formatted version instead).
#
# Steps are numbered strictly in the order you actually run them (1-9),
# including the two revert drills in their real spots -- no letters, no
# out-of-order numbering.
#
# Requires: script/setup-manual-demo.sh already run against a FRESH anvil
# (deploys + funds the actors). Usage:
#   ./script/manual-demo.sh            # interactive menu
#   ./script/manual-demo.sh step5      # run one step directly

set -uo pipefail

RPC="${RPC:-http://127.0.0.1:8545}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Contract addresses depend on deploy nonce and drift across redeploys --
# always read the actual last-deployed addresses, never hardcode them.
if [ ! -f "$SCRIPT_DIR/.demo-addrs.sh" ]; then
  echo "No deployed addresses found -- run ./script/setup-manual-demo.sh first." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$SCRIPT_DIR/.demo-addrs.sh"

# Anvil's fixed default dev accounts -- these do NOT drift across redeploys.
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
LENDER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
BORROWER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
LIQUIDATOR=0x90F79bf6EB2c4f870365E785982E1f101E93b906
PK0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
PK1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
PK2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
PK3=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6

# cast call prints "100000000000 [1e11]" for round numbers -- strip the hint.
callval() { cast call "$@" --rpc-url "$RPC" | awk '{print $1}'; }
usdr() { cast format-units "$1" 6; }    # human-readable USDr (6 decimals)
amfi() { cast format-units "$1" 18; }   # human-readable mAMFI (18 decimals)

step1() {
  echo "== Step 1: Lender deposits 100,000 USDr into the vault =="
  cast send "$USDR"  "approve(address,uint256)" "$VAULT" 100000000000  --private-key "$PK1" --rpc-url "$RPC" >/dev/null
  cast send "$VAULT" "deposit(uint256,address)" 100000000000 "$LENDER" --private-key "$PK1" --rpc-url "$RPC" >/dev/null
  TA=$(callval "$VAULT" "totalAssets()(uint256)")
  echo "Vault totalAssets: $(usdr "$TA") USDr"
}

step2() {
  echo "== Step 2: Curator allocates 80,000 into the market (80% cap) =="
  cast send "$VAULT" "allocate(uint256)" 80000000000 --private-key "$PK0" --rpc-url "$RPC" >/dev/null
  IDLE=$(callval "$USDR" "balanceOf(address)(uint256)" "$VAULT")
  echo "Vault idle balance: $(usdr "$IDLE") USDr"
}

step3() {
  echo "== Step 3: Borrower posts 50,000 mAMFI collateral (no borrow yet) =="
  cast send "$AMFI"   "approve(address,uint256)" "$MARKET" 50000000000000000000000 --private-key "$PK2" --rpc-url "$RPC" >/dev/null
  cast send "$MARKET" "supplyCollateral(uint256)" 50000000000000000000000          --private-key "$PK2" --rpc-url "$RPC" >/dev/null
  COLLAT=$(callval "$MARKET" "collateralBalance(address)(uint256)" "$BORROWER")
  echo "Borrower collateral posted: $(amfi "$COLLAT") mAMFI"
}

step4() {
  echo "== Step 4 [revert drill]: over-LTV borrow -- 40,000 vs 50,000 collateral = 80% > 70% LLTV =="
  cast send "$MARKET" "borrow(uint256)" 40000000000 --private-key "$PK2" --rpc-url "$RPC"
}

step5() {
  echo "== Step 5: Borrower borrows 30,000 USDr =="
  cast send "$MARKET" "borrow(uint256)" 30000000000 --private-key "$PK2" --rpc-url "$RPC" >/dev/null
  HEALTHY=$(callval "$MARKET" "isHealthy(address)(bool)" "$BORROWER")
  RATE=$(callval "$MARKET" "borrowRateWadPerYear()(uint256)")
  echo "Position healthy? $HEALTHY"
  echo "Borrow rate: $(cast format-units "$RATE" 16)% per year"   # WAD/1e16 = percent
}

step6() {
  echo "== Step 6 [revert drill]: liquidating a healthy position (must be unhealthy first) =="
  cast send "$MARKET" "liquidate(address,uint256)" "$BORROWER" 1 --private-key "$PK3" --rpc-url "$RPC"
}

step7() {
  echo "== Step 7: NAV writedown \$1.00 -> \$0.70 (credit deterioration) =="
  cast send "$AMFI" "setNav(uint256)" 700000 --private-key "$PK0" --rpc-url "$RPC" >/dev/null
  HEALTHY=$(callval "$MARKET" "isHealthy(address)(bool)" "$BORROWER")
  echo "Position healthy now? $HEALTHY"
}

step8() {
  echo "== Step 8: Permissionless liquidation (full position) =="
  SHARES=$(callval "$MARKET" "borrowShares(address)(uint256)" "$BORROWER")
  cast send "$USDR"   "approve(address,uint256)" "$MARKET" 100000000000 --private-key "$PK3" --rpc-url "$RPC" >/dev/null
  cast send "$MARKET" "liquidate(address,uint256)" "$BORROWER" "$SHARES" --private-key "$PK3" --rpc-url "$RPC" >/dev/null
  SEIZED=$(callval "$AMFI" "balanceOf(address)(uint256)" "$LIQUIDATOR")
  echo "Liquidator seized: $(amfi "$SEIZED") mAMFI"
}

step9() {
  echo "== Step 9: Liquidator redeems seized mAMFI via the issuer pool =="
  BAL=$(callval "$AMFI" "balanceOf(address)(uint256)" "$LIQUIDATOR")
  cast send "$AMFI" "redeem(uint256)" "$BAL" --private-key "$PK3" --rpc-url "$RPC" >/dev/null
  PROCEEDS=$(callval "$USDR" "balanceOf(address)(uint256)" "$LIQUIDATOR")
  echo "Liquidator's mUSDr balance now: $(usdr "$PROCEEDS") USDr"
}

status() {
  echo "== Current state =="
  echo "-- Vault --"
  echo "Vault totalAssets:        $(usdr "$(callval "$VAULT" "totalAssets()(uint256)")") USDr"
  echo "Vault idle balance:       $(usdr "$(callval "$USDR" "balanceOf(address)(uint256)" "$VAULT")") USDr"
  echo "-- Market --"
  echo "Market totalSupplyAssets: $(usdr "$(callval "$MARKET" "totalSupplyAssets()(uint256)")") USDr"
  echo "Market totalBorrowAssets: $(usdr "$(callval "$MARKET" "totalBorrowAssets()(uint256)")") USDr"
  echo "Current NAV:              \$$(usdr "$(callval "$AMFI" "navPerToken()(uint256)")") per mAMFI"
  echo "-- Borrower --"
  echo "Healthy?                  $(callval "$MARKET" "isHealthy(address)(bool)" "$BORROWER")"
  echo "Debt:                     $(usdr "$(callval "$MARKET" "debtOf(address)(uint256)" "$BORROWER")") USDr"
  echo "Collateral posted:        $(amfi "$(callval "$MARKET" "collateralBalance(address)(uint256)" "$BORROWER")") mAMFI"
  echo "Collateral value:         $(usdr "$(callval "$MARKET" "collateralValue(address)(uint256)" "$BORROWER")") USDr"
  LLTV=$(callval "$MARKET" "liquidationLtvBps()(uint256)")
  COLLAT_VALUE=$(callval "$MARKET" "collateralValue(address)(uint256)" "$BORROWER")
  MAX_BORROW=$(( COLLAT_VALUE * LLTV / 10000 ))
  echo "Liquidation LTV target:   $((LLTV / 100))% of current collateral value"
  echo "Max debt allowed now:     $(usdr "$MAX_BORROW") USDr"
  echo "USDr wallet (borrowed cash): $(usdr "$(callval "$USDR" "balanceOf(address)(uint256)" "$BORROWER")") USDr"
  echo "-- Liquidator --"
  echo "USDr balance:             $(usdr "$(callval "$USDR" "balanceOf(address)(uint256)" "$LIQUIDATOR")") USDr"
  echo "mAMFI balance:            $(amfi "$(callval "$AMFI" "balanceOf(address)(uint256)" "$LIQUIDATOR")") mAMFI"
}

maxwithdraw() {
  echo "== Not a revert -- the honest max: vault withdrawal capped by real market liquidity =="
  TA=$(callval "$VAULT" "totalAssets()(uint256)")
  MW=$(callval "$VAULT" "maxWithdraw(address)(uint256)" "$LENDER")
  echo "Vault totalAssets:   $(usdr "$TA") USDr"
  echo "maxWithdraw(lender): $(usdr "$MW") USDr"
  echo "(maxWithdraw rounds down by the smallest unit, by design -- withdraw(maxWithdraw) can never revert on a rounding mismatch)"
}

menu() {
  PS3="Pick a step (Ctrl+C to quit): "
  options=("step1 - lender deposits" \
           "step2 - curator allocates" \
           "step3 - borrower posts collateral (no borrow yet)" \
           "step4 [revert drill] - over-LTV borrow attempt" \
           "step5 - borrower borrows 30,000" \
           "step6 [revert drill] - liquidate a healthy position" \
           "step7 - NAV writedown" \
           "step8 - liquidation" \
           "step9 - redemption" \
           "status (check anytime)" \
           "maxwithdraw check (check anytime)")
  select opt in "${options[@]}"; do
    case $REPLY in
      1) step1 ;;
      2) step2 ;;
      3) step3 ;;
      4) step4 ;;
      5) step5 ;;
      6) step6 ;;
      7) step7 ;;
      8) step8 ;;
      9) step9 ;;
      10) status ;;
      11) maxwithdraw ;;
      *) echo "Invalid option" ;;
    esac
    echo ""
  done
}

if [ $# -eq 0 ]; then
  menu
else
  "$1"
fi
