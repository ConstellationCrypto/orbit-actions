#!/usr/bin/env bash
#
# Post-migration verification for VanillaMigrationNitroContracts2Point1Point3UpgradeAction.
#
# Run this AFTER the execute step (step 3) to confirm the chain was migrated celestia -> vanilla
# correctly: vanilla wasm root set, vanilla OSP installed, in-flight celestia challenges still
# routed to the celestia OSP, and inbox / sequencer inbox upgraded to the vanilla v2.1.3 impls.
#
# Usage:
#   PARENT_CHAIN_RPC=...  (or RPC=...)
#   set INBOX_ADDRESS and UPGRADE_ACTION_ADDRESS in your .env (project root) or the env, then:
#     ./scripts/foundry/contract-upgrades/vanilla-migration-2.1.3/verify.sh
#
# It reads the expected values straight off the deployed upgrade action's immutables, so there is
# nothing to hand-enter beyond the inbox and the action address.

set -euo pipefail

# --- load .env from project root if present -----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
  set +a
fi

RPC="${RPC:-${PARENT_CHAIN_RPC:-}}"
: "${RPC:?set RPC or PARENT_CHAIN_RPC}"
: "${INBOX_ADDRESS:?set INBOX_ADDRESS}"
: "${UPGRADE_ACTION_ADDRESS:?set UPGRADE_ACTION_ADDRESS}"

A="$UPGRADE_ACTION_ADDRESS"

pass=0
fail=0
lc() { echo "${1:-}" | tr '[:upper:]' '[:lower:]'; }
check() { # name expected actual
  local name="$1" exp actual
  exp="$(lc "$2")"; actual="$(lc "$3")"
  if [[ "$exp" == "$actual" ]]; then
    printf '  \033[32mPASS\033[0m %-34s %s\n' "$name" "$actual"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m %-34s got=%s\n       %*s expected=%s\n' "$name" "$actual" 39 "" "$exp"
    fail=$((fail + 1))
  fi
}
neq() { # name a b   (PASS when a != b)
  local name="$1" a b
  a="$(lc "$2")"; b="$(lc "$3")"
  if [[ "$a" != "$b" ]]; then
    printf '  \033[32mPASS\033[0m %-34s %s\n' "$name" "$a"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m %-34s %s (should differ)\n' "$name" "$a"
    fail=$((fail + 1))
  fi
}

call() { cast call --rpc-url "$RPC" "$@"; }
# read the EIP-1967 implementation slot of a transparent proxy
IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
impl_of() { cast storage --rpc-url "$RPC" "$1" "$IMPL_SLOT" | cast parse-bytes32-address; }

# --- expected values from the action immutables -------------------------------------------------
VANILLA_ROOT="$(call "$A" 'newWasmModuleRoot()(bytes32)')"
CELESTIA_ROOT="$(call "$A" 'condRoot()(bytes32)')"
VANILLA_OSP="$(call "$A" 'osp()(address)')"
EXP_CM_IMPL="$(call "$A" 'newChallengeManagerImpl()(address)')"
EXP_ETH_INBOX="$(call "$A" 'newEthInboxImpl()(address)')"
EXP_ERC20_INBOX="$(call "$A" 'newERC20InboxImpl()(address)')"
EXP_ETH_SEQ="$(call "$A" 'newEthSequencerInboxImpl()(address)')"
EXP_ERC20_SEQ="$(call "$A" 'newERC20SequencerInboxImpl()(address)')"

# --- topology from the inbox --------------------------------------------------------------------
BRIDGE="$(call "$INBOX_ADDRESS" 'bridge()(address)')"
SEQ_INBOX="$(call "$INBOX_ADDRESS" 'sequencerInbox()(address)')"
ROLLUP="$(call "$BRIDGE" 'rollup()(address)')"
CM="$(call "$ROLLUP" 'challengeManager()(address)')"

# eth vs erc20 (matches the action's detection)
IS_ERC20=false
if call "$BRIDGE" 'nativeToken()(address)' >/dev/null 2>&1; then IS_ERC20=true; fi

echo "action   $A"
echo "inbox    $INBOX_ADDRESS"
echo "bridge   $BRIDGE  (erc20=$IS_ERC20)"
echo "seqInbox $SEQ_INBOX"
echo "rollup   $ROLLUP"
echo "challMgr $CM"
echo

echo "wasm module root:"
check "rollup.wasmModuleRoot == vanilla" "$VANILLA_ROOT" "$(call "$ROLLUP" 'wasmModuleRoot()(bytes32)')"
echo

echo "one-step proof entry (OSP) routing:"
check "challengeManager.osp == vanilla"  "$VANILLA_OSP" "$(call "$CM" 'osp()(address)')"
check "getOsp(vanillaRoot) == vanilla"   "$VANILLA_OSP" "$(call "$CM" 'getOsp(bytes32)(address)' "$VANILLA_ROOT")"
# in-flight safety: the celestia root must still resolve to the (non-vanilla) celestia OSP
neq   "getOsp(celestiaRoot) != vanilla"  "$(call "$CM" 'getOsp(bytes32)(address)' "$CELESTIA_ROOT")" "$VANILLA_OSP"
echo

echo "implementations upgraded to vanilla v2.1.3 / consensus-v32:"
check "challengeManager impl"            "$EXP_CM_IMPL" "$(impl_of "$CM")"
if [[ "$IS_ERC20" == "true" ]]; then
  check "inbox impl (erc20)"             "$EXP_ERC20_INBOX" "$(impl_of "$INBOX_ADDRESS")"
  check "sequencerInbox impl (erc20)"    "$EXP_ERC20_SEQ"   "$(impl_of "$SEQ_INBOX")"
else
  check "inbox impl (eth)"               "$EXP_ETH_INBOX" "$(impl_of "$INBOX_ADDRESS")"
  check "sequencerInbox impl (eth)"      "$EXP_ETH_SEQ"   "$(impl_of "$SEQ_INBOX")"
fi
echo

echo "------------------------------------------------------------"
if [[ "$fail" -eq 0 ]]; then
  printf '\033[32mALL %d CHECKS PASSED\033[0m — migration verified.\n' "$pass"
  exit 0
else
  printf '\033[31m%d CHECK(S) FAILED\033[0m (%d passed) — migration NOT verified.\n' "$fail" "$pass"
  exit 1
fi
