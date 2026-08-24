#!/usr/bin/env bash
# tests/test-inspect.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSPECTOR_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

failures=0
assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "true" ]; then echo "ok - $desc"; else
    echo "FAIL - $desc"; failures=$((failures + 1)); fi
}

echo "== hermetic aggregation test: fake checks/ dir, stubbed apprise =="
work_dir="$(mktemp -d)"
mkdir -p "$work_dir/checks" "$work_dir/lib"
cp "$INSPECTOR_DIR/lib/common.sh" "$work_dir/lib/common.sh"
cp "$INSPECTOR_DIR/inspect.sh" "$work_dir/inspect.sh"

cat > "$work_dir/checks/aaa-emits-auto.sh" <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
emit_result "auto" "deleted" "fake-target-1" "fake detail 1"
EOF
cat > "$work_dir/checks/bbb-emits-alert-and-fails.sh" <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
emit_result "alert" "flagged" "fake-target-2" "fake detail 2"
exit 1
EOF
chmod +x "$work_dir/checks/"*.sh "$work_dir/inspect.sh"

# Stub curl (send_apprise's only external dependency) so this test
# never makes a network call: capture the payload to a file and always
# report success, matching apprise's real 200 response shape.
mkdir -p "$work_dir/bin"
cat > "$work_dir/bin/curl" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "-d" ]; then next_is_payload=1; continue; fi
  if [ "\${next_is_payload:-}" = "1" ]; then echo "\$a" > "$work_dir/captured_payload.json"; break; fi
done
echo -n "200"
EOF
chmod +x "$work_dir/bin/curl"

PATH="$work_dir/bin:$PATH" "$work_dir/inspect.sh"
inspect_status=$?

assert_true "inspect.sh exits 0 even though one check exited non-zero" \
  "$([ "$inspect_status" -eq 0 ] && echo true || echo false)"
assert_true "captured apprise payload mentions the auto-tier target" \
  "$(grep -q "fake-target-1" "$work_dir/captured_payload.json" && echo true || echo false)"
assert_true "captured apprise payload mentions the alert-tier target" \
  "$(grep -q "fake-target-2" "$work_dir/captured_payload.json" && echo true || echo false)"
assert_true "captured apprise payload mentions the failed check by name" \
  "$(grep -q "bbb-emits-alert-and-fails.sh" "$work_dir/captured_payload.json" && echo true || echo false)"

assert_true "payload title is the English inspection title" \
  "$(grep -q "Inspection report vps_oracle" "$work_dir/captured_payload.json" && echo true || echo false)"
assert_true "payload body uses English section headers" \
  "$(grep -q "Auto-handled" "$work_dir/captured_payload.json" && grep -q "Needs manual review" "$work_dir/captured_payload.json" && echo true || echo false)"
assert_true "payload contains no CJK characters" \
  "$(grep -qP '[\x{3400}-\x{4dbf}\x{4e00}-\x{9fff}\x{f900}-\x{faff}]' "$work_dir/captured_payload.json" && echo false || echo true)"

rm -rf "$work_dir"

echo "== real end-to-end dry run against actual checks/, real apprise (inspector-tg) =="
if INSPECTOR_DRY_RUN=1 "$INSPECTOR_DIR/inspect.sh"; then
  echo "ok - real dry run against actual checks/ completed and notified apprise successfully"
else
  echo "FAIL - real dry run exited non-zero"
  failures=$((failures + 1))
fi

echo "---"
if [ "$failures" -eq 0 ]; then
  echo "PASS"; exit 0
else
  echo "FAIL: $failures check(s) failed"; exit 1
fi
