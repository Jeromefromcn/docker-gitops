#!/usr/bin/env bash
# tests/test-ccr-tool-schema-rejections.sh — hermetic: docker stub serves a
# canned node response, so nothing here touches the real daemon, the real
# ccr container, or its request-log database. The node program the check
# pipes into `docker exec` cannot be exercised this way (it needs
# better-sqlite3 from inside the image), so the stub also records how many
# bytes arrived on stdin: that guards the quoting, which is the part that
# would break silently. The query itself is verified against the live
# container by hand, see the check's header comment.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"

# Canned node output. Row shape mirrors what the query prints.
matched_json="$work_dir/matched.json"
cat > "$matched_json" <<'EOF'
{"ok":true,"scanned":57,"matched":[{"id":16996,"created_at":"2026-09-25T14:59:07.401Z","provider":"deepseek::anthropic_messages","resolved_model":"deepseek-flash","status_code":400,"signature":"Invalid schema for function"},{"id":16995,"created_at":"2026-09-25T14:58:22.737Z","provider":"deepseek::anthropic_messages","resolved_model":"deepseek-flash","status_code":400,"signature":"is not valid under any of the schemas"}]}
EOF
clean_json="$work_dir/clean.json"
cat > "$clean_json" <<'EOF'
{"ok":true,"scanned":57,"matched":[]}
EOF
broken_json="$work_dir/broken.json"
cat > "$broken_json" <<'EOF'
this is not json at all
EOF

# STUB_MODE selects the behaviour; STUB_RUNNING/STUB_EXISTS control inspect.
cat > "$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" info "*)
    [ "${STUB_DOCKER_DOWN:-0}" = "1" ] && exit 1
    exit 0 ;;
esac
case "$1" in
  inspect)
    [ "${STUB_EXISTS:-1}" = "0" ] && exit 1
    echo "${STUB_RUNNING:-true}"; exit 0 ;;
  exec)
    # Swallow stdin, recording only its size — proves the query was piped.
    bytes="$(cat | wc -c)"
    echo "$bytes" >> "${STUB_DIR:-/tmp}/stdin_bytes.log"
    [ "${STUB_EXEC_FAIL:-0}" = "1" ] && exit 1
    cat "${STUB_OUTPUT:?}"
    exit 0 ;;
esac
exit 1
EOF
chmod +x "$bin_dir/docker"
export STUB_DIR="$work_dir"

check="$SCRIPT_DIR/../checks/ccr-tool-schema-rejections.sh"
run_check() {
  STUB_OUTPUT="$1" PATH="$bin_dir:$PATH" "$check" 2>/dev/null
}

# --- rejections present: alert, with count and provider ------------------
out="$(run_check "$matched_json")"
assert_true "flags a window containing provider schema rejections" \
  "$(grep -q '"action":"flagged"' <<<"$out" && echo true || echo false)"
assert_true "alert names the provider that rejected the request" \
  "$(grep -q 'deepseek::anthropic_messages' <<<"$out" && echo true || echo false)"
assert_true "alert reports how many requests were rejected" \
  "$(grep -q '2 ' <<<"$out" && echo true || echo false)"
assert_true "alert points at the incident record for the fix" \
  "$(grep -q '2026-09-25-ccr-deepseek-artifact-schema-400' <<<"$out" && echo true || echo false)"

# --- clean window: silence ----------------------------------------------
out="$(run_check "$clean_json")"
assert_true "a window with no schema rejections produces no line" \
  "$([ -z "$out" ] && echo true || echo false)"

# --- alert tier never claims to have deleted anything -------------------
out="$(run_check "$matched_json")"
assert_true "alert-tier check never emits deleted/would-delete" \
  "$(grep -qE '"action":"(deleted|would-delete)"' <<<"$out" && echo false || echo true)"

# --- the query actually reaches docker exec on stdin --------------------
: > "$work_dir/stdin_bytes.log"
run_check "$clean_json" >/dev/null
assert_true "the sqlite query is piped into docker exec (stdin non-empty)" \
  "$([ -s "$work_dir/stdin_bytes.log" ] && [ "$(head -1 "$work_dir/stdin_bytes.log")" -gt 100 ] && echo true || echo false)"

# --- dependency unavailable: alert, never a silent skip -----------------
out="$(STUB_EXEC_FAIL=1 run_check "$clean_json" 2>/dev/null)"
assert_true "docker exec failing raises an alert instead of skipping" \
  "$(grep -q '"tier":"alert"' <<<"$out" && echo true || echo false)"

out="$(run_check "$broken_json")"
assert_true "unparseable query output raises an alert instead of crashing" \
  "$(grep -q '"tier":"alert"' <<<"$out" && echo true || echo false)"

out="$(STUB_DOCKER_DOWN=1 run_check "$clean_json" 2>/dev/null)"
assert_true "docker daemon unreachable raises an alert" \
  "$(grep -q '"tier":"alert"' <<<"$out" && echo true || echo false)"

# --- container absent: a legitimate skip, not an alert ------------------
out="$(STUB_EXISTS=0 run_check "$clean_json" 2>/dev/null)"
assert_true "no ccr container at all is a skip, not an alert" \
  "$([ -z "$out" ] && echo true || echo false)"

# --- container present but stopped: alert ---------------------------------
out="$(STUB_RUNNING=false run_check "$clean_json" 2>/dev/null)"
assert_true "a stopped ccr container is flagged" \
  "$(grep -q '"tier":"alert"' <<<"$out" && echo true || echo false)"

# --- malformed-but-valid JSON degrades without crashing ------------------
echo '{"ok":false,"error":"no such table: request_logs"}' > "$broken_json"
out="$(run_check "$broken_json")"
assert_true "a query-level error is reported as an alert, not a crash" \
  "$(grep -q '"tier":"alert"' <<<"$out" && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
