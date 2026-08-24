#!/usr/bin/env bash
# tests/test-common.sh — minimal verification for lib/common.sh's
# self-protection functions (self-chain, PID identity, two-stage kill,
# self-overlap abort). The design spec calls these out as the part of
# the whole project that must not have bugs -- this script exists so
# that claim doesn't rest on a human reading the code once. Spawns real
# disposable `sleep` processes; never touches anything else on the host.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

failures=0

assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "true" ]; then
    echo "ok - $desc"
  else
    echo "FAIL - $desc"
    failures=$((failures + 1))
  fi
}

cleanup_pids=()
cleanup() {
  [ "${#cleanup_pids[@]}" -eq 0 ] && return
  kill -KILL "${cleanup_pids[@]}" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

echo "== inspector_self_chain =="
chain="$(inspector_self_chain)"
assert_true "self-chain contains our own pid" \
  "$([ "$(grep -c "^$$\$" <<<"$chain")" -ge 1 ] && echo true || echo false)"
assert_true "self-chain ends at pid 1" \
  "$([ "$(tail -n1 <<<"$chain")" = "1" ] && echo true || echo false)"

echo "== get_descendants =="
chain_file="$(mktemp)"
"$SCRIPT_DIR/fixtures/spawn-chain.sh" "$chain_file" 3 &
spawner=$!
sleep 0.5
mapfile -t chain_pids < "$chain_file"
cleanup_pids=("${chain_pids[@]}")
gen1="${chain_pids[0]}"; gen2="${chain_pids[1]}"; gen3="${chain_pids[2]}"

descendants="$(get_descendants "$gen1")"
assert_true "descendants include gen1 itself" \
  "$([ "$(grep -c "^${gen1}\$" <<<"$descendants")" -ge 1 ] && echo true || echo false)"
assert_true "descendants include gen2" \
  "$([ "$(grep -c "^${gen2}\$" <<<"$descendants")" -ge 1 ] && echo true || echo false)"
assert_true "descendants include gen3" \
  "$([ "$(grep -c "^${gen3}\$" <<<"$descendants")" -ge 1 ] && echo true || echo false)"

echo "== capture_pid_identity / verify_pid_identity =="
identity="$(capture_pid_identity "$gen1")"
assert_true "identity verifies against the live pid" \
  "$(verify_pid_identity "$gen1" "$identity" && echo true || echo false)"

echo "== assert_no_self_overlap =="
overlapping="$$
99999999"
assert_true "rejects a list containing our own pid" \
  "$(assert_no_self_overlap "$overlapping" 2>/dev/null && echo false || echo true)"
disjoint="${gen1}
${gen2}"
assert_true "accepts a list disjoint from self-chain" \
  "$(assert_no_self_overlap "$disjoint" 2>/dev/null && echo true || echo false)"

echo "== kill_tree: dry run must not kill =="
sleep 60 &
victim=$!
cleanup_pids+=("$victim")
victim_identity="$(capture_pid_identity "$victim")"
INSPECTOR_DRY_RUN=1 kill_tree "$victim" "$victim_identity" >/dev/null
assert_true "process still alive after dry-run kill_tree" \
  "$(kill -0 "$victim" 2>/dev/null && echo true || echo false)"

echo "== kill_tree: real run must terminate the whole subtree =="
kill_tree "$gen1" "$identity" >/dev/null
sleep 0.5
assert_true "gen1 terminated" \
  "$(kill -0 "$gen1" 2>/dev/null && echo false || echo true)"
assert_true "gen2 terminated" \
  "$(kill -0 "$gen2" 2>/dev/null && echo false || echo true)"
assert_true "gen3 terminated" \
  "$(kill -0 "$gen3" 2>/dev/null && echo false || echo true)"

echo "== verify_pid_identity: must fail once the pid is gone =="
assert_true "identity check fails for a terminated pid" \
  "$(verify_pid_identity "$gen1" "$identity" && echo false || echo true)"

rm -f "$chain_file"
kill -KILL "$victim" 2>/dev/null || true
wait 2>/dev/null || true

echo "---"
if [ "$failures" -eq 0 ]; then
  echo "PASS: all common.sh self-protection checks passed"
  exit 0
else
  echo "FAIL: $failures check(s) failed"
  exit 1
fi
