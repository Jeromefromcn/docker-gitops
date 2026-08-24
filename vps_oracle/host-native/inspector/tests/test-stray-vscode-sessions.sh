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

echo "== plain idle turn, under the (25h-aligned) idle threshold: should NOT flag =="
output3b="$(
  INSPECTOR_DRY_RUN=1 \
  INSPECTOR_CLAUDE_SESSIONS_DIR="$sessions_dir" \
  INSPECTOR_CLAUDE_PROJECTS_DIR="$projects_dir" \
  INSPECTOR_STUCK_SESSION_ALERT_SECONDS=999999 \
  "$SCRIPT_DIR/../checks/stray-vscode-sessions.sh"
)"
assert_true "no alert when under the idle threshold" \
  "$([ -z "$output3b" ] && echo true || echo false)"

echo "== unresolved tool_use as last line, process idle (S state): pending-dangling-question alert =="
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}]}}' \
  > "$transcript_dir/test-session-1.jsonl"
output4="$(
  INSPECTOR_DRY_RUN=1 \
  INSPECTOR_CLAUDE_SESSIONS_DIR="$sessions_dir" \
  INSPECTOR_CLAUDE_PROJECTS_DIR="$projects_dir" \
  INSPECTOR_STUCK_SESSION_ALERT_SECONDS=999999 \
  INSPECTOR_STUCK_SESSION_PENDING_SECONDS=0 \
  "$SCRIPT_DIR/../checks/stray-vscode-sessions.sh"
)"
assert_true "flags a dangling-question alert even though the idle threshold is unreached" \
  "$(grep -q "dangling question" <<<"$output4" && echo true || echo false)"

echo "== same unresolved tool_use, under the pending threshold: should NOT flag =="
output4b="$(
  INSPECTOR_DRY_RUN=1 \
  INSPECTOR_CLAUDE_SESSIONS_DIR="$sessions_dir" \
  INSPECTOR_CLAUDE_PROJECTS_DIR="$projects_dir" \
  INSPECTOR_STUCK_SESSION_ALERT_SECONDS=999999 \
  INSPECTOR_STUCK_SESSION_PENDING_SECONDS=999999 \
  "$SCRIPT_DIR/../checks/stray-vscode-sessions.sh"
)"
assert_true "no alert when under the pending threshold" \
  "$([ -z "$output4b" ] && echo true || echo false)"

echo "== unresolved tool_use but process is on-CPU right now: not treated as dangling =="
( while :; do :; done ) &
busy_victim=$!
busy_identity="$(capture_pid_identity "$busy_victim")"
busy_starttime="${busy_identity%%|*}"
cat > "$sessions_dir/${busy_victim}.json" <<EOF
{"pid":${busy_victim},"sessionId":"test-session-busy","cwd":"${fake_cwd}","procStart":${busy_starttime}}
EOF
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"Bash","input":{}}]}}' \
  > "$transcript_dir/test-session-busy.jsonl"
output5="$(
  INSPECTOR_DRY_RUN=1 \
  INSPECTOR_CLAUDE_SESSIONS_DIR="$sessions_dir" \
  INSPECTOR_CLAUDE_PROJECTS_DIR="$projects_dir" \
  INSPECTOR_STUCK_SESSION_ALERT_SECONDS=999999 \
  INSPECTOR_STUCK_SESSION_PENDING_SECONDS=0 \
  "$SCRIPT_DIR/../checks/stray-vscode-sessions.sh"
)"
kill -KILL "$busy_victim" 2>/dev/null || true
wait "$busy_victim" 2>/dev/null || true
# grep for this session specifically -- test-session-1's own fixture still
# carries a genuinely-idle dangling tool_use from the scenario above, so a
# bare "dangling question" match would pass for the wrong reason.
assert_true "an on-CPU process with an unresolved tool_use is not flagged as a dangling question" \
  "$(grep -q "test-session-busy.*dangling question" <<<"$output5" && echo false || echo true)"

kill -KILL "$victim" 2>/dev/null || true
wait 2>/dev/null || true
rm -rf "$fixture_dir"

echo "---"
if [ "$failures" -eq 0 ]; then
  echo "PASS"; exit 0
else
  echo "FAIL: $failures check(s) failed"; exit 1
fi
