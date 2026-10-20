#!/usr/bin/env bash
# Rehearses the mainnet deployment on a local fork of Ink mainnet. Nothing touches the real chain.
#   1. Deploys everything with Deploy.s.sol, handing ownership to a timelock run by a stand-in Safe
#   2. Runs Smoke.s.sol: launch a coin, buy, sell
#   3. Buys out the smoke-test curve so the coin graduates into its Uniswap v4 pool
#   4. Plays the Safe's part of the handover: schedules acceptOwnership() on the factory and the
#      registry through the timelock, waits out the delay, executes, and checks the deployer lost control
# Needs Foundry (anvil, cast, forge). Run: ./script/rehearse.sh
#   INK_RPC  Ink mainnet RPC to fork, default https://rpc-gel.inkonchain.com
#   SOLC     optional path to a solc 0.8.26 binary, passed to forge as --use
#   PORT     local port for the fork, default 8547
set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM=${INK_RPC:-https://rpc-gel.inkonchain.com}
RPC=http://127.0.0.1:${PORT:-8547}
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
DEADLINE=4294967295
LOG=$(mktemp -d)

# Chain id 31337 keeps the rehearsal's broadcast logs apart from real Ink deployments (57073).
anvil --fork-url "$UPSTREAM" --chain-id 31337 --port "${PORT:-8547}" --silent &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true; rm -rf "$LOG"' EXIT
for _ in $(seq 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
check() {
  if [ "$(lower "$2")" != "$(lower "$3")" ]; then echo "FAIL: $1 (expected $3, got $2)"; exit 1; fi
  echo "ok    $1"
}
logged() { awk -v k="$1" '$1 == k { print $NF; exit }' "$2"; }
num() { awk '{ print $1 }'; }

# Throwaway keys hashed from fixed phrases: fresh addresses with no history on Ink.
DEPLOYER_KEY=$(cast keccak "letsprint-rehearsal-deployer")
DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_KEY")
TREASURY=$(cast wallet address --private-key "$(cast keccak "letsprint-rehearsal-treasury")")
SAFE=$(cast wallet address --private-key "$(cast keccak "letsprint-rehearsal-safe")")
cast rpc anvil_setBalance "$DEPLOYER" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null # 100 ETH
cast rpc anvil_setBalance "$SAFE" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null       # 1 ETH

echo "== 1. Deploy"
POOL_MANAGER=0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32 USDC=0x2D270e6886d130D724215A266106e6832161EAEd \
  TREASURY="$TREASURY" SAFE="$SAFE" \
  forge script script/Deploy.s.sol ${SOLC:+--use "$SOLC"} --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" \
  --broadcast > "$LOG/deploy" || { cat "$LOG/deploy"; exit 1; }
sed -n '/== Logs ==/,/^$/p' "$LOG/deploy"
FACTORY=$(logged LaunchpadFactory "$LOG/deploy")
ROUTER=$(logged LaunchRouter "$LOG/deploy")
REGISTRY=$(logged LaunchpadRegistry "$LOG/deploy")
TIMELOCK=$(logged TimelockController "$LOG/deploy")
HOOK=$(logged PrintHook "$LOG/deploy")
check "hook address carries its permission flags" "$(printf '0x%04x' $((0x${HOOK: -4} & 0x3FFF)))" 0x20cc
check "factory is bound to the hook" "$(cast call "$FACTORY" "hook()(address)" --rpc-url "$RPC")" "$HOOK"
check "treasury" "$(cast call "$FACTORY" "treasury()(address)" --rpc-url "$RPC")" "$TREASURY"
check "registry lists the factory" "$(cast call "$REGISTRY" "latest()(address)" --rpc-url "$RPC")" "$FACTORY"
check "deployer still owns the factory" "$(cast call "$FACTORY" "owner()(address)" --rpc-url "$RPC")" "$DEPLOYER"
check "timelock is the pending owner" "$(cast call "$FACTORY" "pendingOwner()(address)" --rpc-url "$RPC")" "$TIMELOCK"
check "USDC pair enabled" "$(cast call "$FACTORY" "quoteConfig(address)(bool,bool,uint256)" \
  0x2D270e6886d130D724215A266106e6832161EAEd --rpc-url "$RPC" | head -1)" true

echo "== 2. Smoke test"
FACTORY="$FACTORY" ROUTER="$ROUTER" \
  forge script script/Smoke.s.sol ${SOLC:+--use "$SOLC"} --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" \
  --broadcast > "$LOG/smoke" || { cat "$LOG/smoke"; exit 1; }
sed -n '/== Logs ==/,/^$/p' "$LOG/smoke"
CURVE=$(logged curve "$LOG/smoke")

echo "== 3. Buy out the curve with the wallet's own gas estimate; it must graduate in the same transaction"
LEFT=$(cast call "$CURVE" "realTokenReserve()(uint256)" --rpc-url "$RPC" | num)
COST=$(cast call "$CURVE" "quoteBuyExactTokens(uint256,address)(uint256)" "$LEFT" "$DEPLOYER" --rpc-url "$RPC" | num)
cast send "$ROUTER" "buyWithETH(address,uint256,address,uint256,bytes32)" "$CURVE" 1 "$DEPLOYER" "$DEADLINE" "$ZERO32" \
  --value "$COST" --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" > "$LOG/fill"
echo "      sent $(cast from-wei "$COST") ETH (any excess is refunded) for the last $(cast from-wei "$LEFT") tokens; gas used $(awk '$1 == "gasUsed" { print $2 }' "$LOG/fill")"
check "coin graduated" "$(cast call "$CURVE" "graduated()(bool)" --rpc-url "$RPC")" true

echo "== 4. Safe accepts ownership through the timelock"
ACCEPT=$(cast calldata "acceptOwnership()")
DELAY=$(cast call "$TIMELOCK" "getMinDelay()(uint256)" --rpc-url "$RPC" | num)
cast rpc anvil_impersonateAccount "$SAFE" --rpc-url "$RPC" >/dev/null
cast send "$TIMELOCK" "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)" \
  "[$FACTORY,$REGISTRY]" "[0,0]" "[$ACCEPT,$ACCEPT]" "$ZERO32" "$ZERO32" "$DELAY" \
  --from "$SAFE" --unlocked --rpc-url "$RPC" >/dev/null
echo "      scheduled; waiting out the ${DELAY}s delay"
cast rpc evm_increaseTime $((DELAY + 1)) --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
cast send "$TIMELOCK" "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)" \
  "[$FACTORY,$REGISTRY]" "[0,0]" "[$ACCEPT,$ACCEPT]" "$ZERO32" "$ZERO32" \
  --from "$SAFE" --unlocked --rpc-url "$RPC" >/dev/null
check "timelock owns the factory" "$(cast call "$FACTORY" "owner()(address)" --rpc-url "$RPC")" "$TIMELOCK"
check "timelock owns the registry" "$(cast call "$REGISTRY" "owner()(address)" --rpc-url "$RPC")" "$TIMELOCK"
if cast call "$FACTORY" "setDeployFee(uint256)" 0 --from "$DEPLOYER" --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "FAIL: the deployer can still change factory settings"; exit 1
fi
echo "ok    deployer can no longer change factory settings"

echo
echo "Rehearsal passed."
