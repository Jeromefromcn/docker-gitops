#!/usr/bin/env bash
# tests/test-vscode-server-versions.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failures=0
assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "true" ]; then echo "ok - $desc"; else
    echo "FAIL - $desc"; failures=$((failures + 1)); fi
}

fixture_dir="$(mktemp -d)"
mkdir -p "$fixture_dir/Stable-newest" "$fixture_dir/Stable-old" "$fixture_dir/Stable-oldest"
touch "$fixture_dir/Stable-newest/marker" "$fixture_dir/Stable-old/marker" "$fixture_dir/Stable-oldest/marker"
cat > "$fixture_dir/lru.json" <<'EOF'
["Stable-newest", "Stable-old", "Stable-oldest"]
EOF

echo "== keep=2: oldest should be deleted, newest+old kept =="
INSPECTOR_VSCODE_SERVERS_DIR="$fixture_dir" \
INSPECTOR_KEEP_SERVER_VERSIONS=2 \
  "$SCRIPT_DIR/../checks/vscode-server-versions.sh" >/dev/null

assert_true "Stable-newest still exists" \
  "$([ -d "$fixture_dir/Stable-newest" ] && echo true || echo false)"
assert_true "Stable-old still exists" \
  "$([ -d "$fixture_dir/Stable-old" ] && echo true || echo false)"
assert_true "Stable-oldest was deleted" \
  "$([ ! -d "$fixture_dir/Stable-oldest" ] && echo true || echo false)"

echo "== dry-run must not delete =="
mkdir -p "$fixture_dir/Stable-old"   # recreate for this sub-test
output="$(
  INSPECTOR_DRY_RUN=1 \
  INSPECTOR_VSCODE_SERVERS_DIR="$fixture_dir" \
  INSPECTOR_KEEP_SERVER_VERSIONS=1 \
    "$SCRIPT_DIR/../checks/vscode-server-versions.sh"
)"
assert_true "dry-run emits would-delete for Stable-old" \
  "$(grep -q '"target":"Stable-old"' <<<"$output" && grep -q would-delete <<<"$output" && echo true || echo false)"
assert_true "dry-run left Stable-old on disk" \
  "$([ -d "$fixture_dir/Stable-old" ] && echo true || echo false)"

rm -rf "$fixture_dir"

echo "---"
if [ "$failures" -eq 0 ]; then
  echo "PASS"; exit 0
else
  echo "FAIL: $failures check(s) failed"; exit 1
fi
