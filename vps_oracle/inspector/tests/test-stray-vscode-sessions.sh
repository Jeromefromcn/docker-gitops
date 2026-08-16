#!/usr/bin/env bash
# tests/test-stray-vscode-sessions.sh — classification-logic check for
# checks/stray-vscode-sessions.sh, run in dry-run mode against a
# hermetic fixture (never the real ~/.claude/sessions).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

failures=0
assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "true" ]; then echo "ok - $desc"; else
    echo "FAIL - $desc"; failures=$((failures + 1)); fi
}

fixture_dir="$(mktemp -d)"
sessions_dir="$fixture_dir/sessions"
projects_dir="$fixture_dir/projects"
mkdir -p "$sessions_dir" "$projects_dir"

# A real disposable process to act as the "still alive" session.
sleep 120 &
victim=$!
identity="$(capture_pid_identity "$victim")"
starttime="${identity%%|*}"

fake_cwd="/tmp/fake-project"
transcript_dir="$projects_dir/${fake_cwd//\//-}"
mkdir -p "$transcript_dir"

cat > "$sessions_dir/${victim}.json" <<EOF
{"pid":${victim},"sessionId":"test-session-1","cwd":"${fake_cwd}","procStart":${starttime}}
EOF
echo '{"type":"result","subtype":"success"}' > "$transcript_dir/test-session-1.jsonl"

echo "== finished session past idle threshold: should propose a kill in dry-run =="
output="$(
  INSPECTOR_DRY_RUN=1 \
  INSPECTOR_CLAUDE_SESSIONS_DIR="$sessions_dir" \
  INSPECTOR_CLAUDE_PROJECTS_DIR="$projects_dir" \
  INSPECTOR_STRAY_SESSION_IDLE_SECONDS=0 \
  "$SCRIPT_DIR/../checks/stray-vscode-sessions.sh"
)"
assert_true "emits a would-kill line for the finished session" \
  "$(grep -q "\"action\":\"would-kill\"" <<<"$output" && echo true || echo false)"
assert_true "process is still alive (dry-run took no action)" \
  "$(kill -0 "$victim" 2>/dev/null && echo true || echo false)"

echo "== same session, threshold not yet reached: should NOT propose a kill =="
output2="$(
  INSPECTOR_DRY_RUN=1 \
  INSPECTOR_CLAUDE_SESSIONS_DIR="$sessions_dir" \
  INSPECTOR_CLAUDE_PROJECTS_DIR="$projects_dir" \
  INSPECTOR_STRAY_SESSION_IDLE_SECONDS=999999 \
  "$SCRIPT_DIR/../checks/stray-vscode-sessions.sh"
)"
assert_true "no would-kill line when under threshold" \
  "$([ -z "$output2" ] && echo true || echo false)"

echo "== transcript with no result, past alert threshold: should flag, not kill =="
echo '{"type":"assistant","message":"still working"}' > "$transcript_dir/test-session-1.jsonl"
output3="$(
  INSPECTOR_DRY_RUN=1 \
  INSPECTOR_CLAUDE_SESSIONS_DIR="$sessions_dir" \
  INSPECTOR_CLAUDE_PROJECTS_DIR="$projects_dir" \
  INSPECTOR_STUCK_SESSION_ALERT_SECONDS=0 \
  "$SCRIPT_DIR/../checks/stray-vscode-sessions.sh"
)"
assert_true "emits an alert-tier flagged line" \
  "$(grep -q '"tier":"alert"' <<<"$output3" && grep -q '"action":"flagged"' <<<"$output3" && echo true || echo false)"

kill -KILL "$victim" 2>/dev/null || true
wait 2>/dev/null || true
rm -rf "$fixture_dir"

echo "---"
if [ "$failures" -eq 0 ]; then
  echo "PASS"; exit 0
else
  echo "FAIL: $failures check(s) failed"; exit 1
fi
