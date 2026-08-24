#!/usr/bin/env bash
# checks/stray-vscode-sessions.sh
#
# Covers the three process-related rows of the design spec's check
# table: finished-but-lingering claude sessions (auto-kill), orphaned
# server-main trees with no CPU activity (auto-kill), and long-running
# claude sessions with no transcript result yet (alert only). See
# docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md.
#
# Interactive sessions (the VS Code extension always launches claude
# with --output-format stream-json) never write a "result" transcript
# line -- confirmed empty across every session on this host -- so the
# auto-kill branch below only ever fires for one-shot/programmatic
# invocations, and every long-lived interactive session falls into the
# alert-only branch instead. That branch used to fire on a flat
# idle-seconds threshold alone, which made it indistinguishable from
# this host's own reconnection-grace-time fix (vscode-server now runs
# with --reconnection-grace-time=86400, so a claude process is expected
# to sit idle for up to 24h across a client disconnect -- see
# jerome/oss-devrel/articles/2026-07-14-remote-claude-code-walkaway).
# It now splits into two buckets instead:
#   - "pending": the transcript's last line is an assistant turn with
#     an unresolved tool_use (a permission prompt or question nobody
#     answered) AND the process is idle (state S, not on-CPU right
#     now) -- this is the actual dangling-question failure mode the
#     walk-away article describes. Alerts fast (STUCK_SESSION_PENDING_SECONDS).
#   - everything else: no evidence of a stuck decision, just idle past
#     the expected walk-away window. Alerts slow
#     (STUCK_SESSION_ALERT_SECONDS, aligned to the 24h grace time).
# A process still on-CPU (state R) is doing real work regardless of
# what the transcript's last line looks like, so it's never put in the
# pending bucket -- avoids flagging an in-flight long tool call as a
# dangling question.
#
# Not `set -e`: a single malformed session file or a transient /proc
# read race must not abort the whole check and skip everything after
# it -- each iteration guards its own failure paths explicitly instead.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

CLAUDE_SESSIONS_DIR="${INSPECTOR_CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}"
CLAUDE_PROJECTS_DIR="${INSPECTOR_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
STRAY_SESSION_IDLE_SECONDS="${INSPECTOR_STRAY_SESSION_IDLE_SECONDS:-1800}"
STUCK_SESSION_ALERT_SECONDS="${INSPECTOR_STUCK_SESSION_ALERT_SECONDS:-90000}"
STUCK_SESSION_PENDING_SECONDS="${INSPECTOR_STUCK_SESSION_PENDING_SECONDS:-1800}"
SERVER_TREE_IDLE_SECONDS="${INSPECTOR_SERVER_TREE_IDLE_SECONDS:-7200}"
SERVER_TREE_STATE_FILE="$INSPECTOR_STATE_DIR/server-tree-cpu.tsv"

kill_verb() {
  [ "${INSPECTOR_DRY_RUN:-0}" = "1" ] && echo "would-kill" || echo "killed"
}

# ---- part 1: per-session transcript check ----

check_claude_sessions() {
  local session_file pid session_id cwd proc_start
  local identity current_starttime transcript last_type age kill_status
  local last_line pending proc_state

  [ -d "$CLAUDE_SESSIONS_DIR" ] || return 0

  for session_file in "$CLAUDE_SESSIONS_DIR"/*.json; do
    [ -e "$session_file" ] || continue

    pid="$(jq -r '.pid // empty' "$session_file" 2>/dev/null)"
    session_id="$(jq -r '.sessionId // empty' "$session_file" 2>/dev/null)"
    cwd="$(jq -r '.cwd // empty' "$session_file" 2>/dev/null)"
    proc_start="$(jq -r '.procStart // empty' "$session_file" 2>/dev/null)"
    [ -n "$pid" ] && [ -n "$session_id" ] && [ -n "$cwd" ] && [ -n "$proc_start" ] || continue

    [ -d "/proc/$pid" ] || continue   # process already gone, nothing to do

    identity="$(capture_pid_identity "$pid" 2>/dev/null)" || continue
    current_starttime="${identity%%|*}"
    [ "$current_starttime" = "$proc_start" ] || continue   # pid reused, not this session anymore

    transcript="$CLAUDE_PROJECTS_DIR/${cwd//\//-}/${session_id}.jsonl"
    [ -f "$transcript" ] || continue

    last_type="$(tail -n 1 "$transcript" 2>/dev/null | jq -r '.type // empty' 2>/dev/null)"
    age="$(process_age_seconds "$pid" 2>/dev/null)" || continue

    if [ "$last_type" = "result" ]; then
      [ "$age" -ge "$STRAY_SESSION_IDLE_SECONDS" ] || continue
      # kill_tree's own exit status is the source of truth for what actually
      # happened -- never assume success just because we decided to try.
      kill_tree "$pid" "$identity" >/dev/null 2>&1
      kill_status=$?
      case "$kill_status" in
        0)
          emit_result "auto" "$(kill_verb)" "claude PID $pid" \
            "session $session_id (cwd=$cwd) finished ${age}s ago, still alive past ${STRAY_SESSION_IDLE_SECONDS}s threshold"
          ;;
        2)
          # Self-chain overlap: kill_tree aborted the whole batch per the
          # design's self-protection rule 4. This must surface, not be
          # swallowed -- spec's "只告警" table has an explicit row for it.
          emit_result "alert" "flagged" "claude PID $pid" \
            "skipped: self-chain overlap -- session $session_id (cwd=$cwd) target PID overlapped the inspector's own process chain, entire kill aborted"
          ;;
        *)
          : # identity changed since detection (pid exited/reused) -- benign, nothing to report
          ;;
      esac
    else
      pending="false"; proc_state=""
      last_line="$(tail -n 1 "$transcript" 2>/dev/null)"
      if [ "$last_type" = "assistant" ]; then
        jq -e '[(.message.content // [])[]? | select(.type=="tool_use")] | length > 0' \
          <<<"$last_line" >/dev/null 2>&1 && pending="true"
      fi
      [ "$pending" = "true" ] && proc_state="$(proc_stat_fields "$pid" 2>/dev/null | awk '{print $1}')"

      if [ "$pending" = "true" ] && [ "$proc_state" = "S" ]; then
        if [ "$age" -ge "$STUCK_SESSION_PENDING_SECONDS" ]; then
          emit_result "alert" "flagged" "claude PID $pid" \
            "session $session_id (cwd=$cwd) has an unanswered tool_use/permission prompt and has been idle ${age}s -- likely a dangling question, not just a long task"
        fi
      elif [ "$age" -ge "$STUCK_SESSION_ALERT_SECONDS" ]; then
        emit_result "alert" "flagged" "claude PID $pid" \
          "session $session_id (cwd=$cwd) alive ${age}s with no transcript result yet -- may be a long task or stuck"
      fi
    fi
  done
}

# ---- part 2: orphaned server-main tree check ----

find_orphaned_server_main_roots() {
  pgrep -P 1 -f 'vscode-server/cli/servers/.*/server/out/server-main\.js' 2>/dev/null || true
}

sum_tree_cpu_ticks() {
  local root="$1" pid fields u s total=0
  while read -r pid; do
    [ -z "$pid" ] && continue
    fields="$(proc_stat_fields "$pid" 2>/dev/null)" || continue
    u="$(awk '{print $3}' <<<"$fields")"; s="$(awk '{print $4}' <<<"$fields")"
    total=$((total + u + s))
  done < <(get_descendants "$root")
  echo "$total"
}

check_orphaned_server_trees() {
  local root_pid identity starttime total_cpu now_epoch changed idle_seconds
  local descendant_count kill_status
  declare -A prev_start prev_cpu prev_changed
  local new_state=""

  now_epoch="$(date +%s)"

  if [ -f "$SERVER_TREE_STATE_FILE" ]; then
    while IFS=$'\t' read -r p st cpu ch; do
      [ -z "$p" ] && continue
      prev_start["$p"]="$st"; prev_cpu["$p"]="$cpu"; prev_changed["$p"]="$ch"
    done < "$SERVER_TREE_STATE_FILE"
  fi

  for root_pid in $(find_orphaned_server_main_roots); do
    identity="$(capture_pid_identity "$root_pid" 2>/dev/null)" || continue
    starttime="${identity%%|*}"
    total_cpu="$(sum_tree_cpu_ticks "$root_pid")"

    if [ "${prev_start[$root_pid]:-}" = "$starttime" ] && [ "${prev_cpu[$root_pid]:-}" = "$total_cpu" ]; then
      changed="${prev_changed[$root_pid]}"
    else
      changed="$now_epoch"
    fi

    idle_seconds=$((now_epoch - changed))

    if [ "$idle_seconds" -lt "$SERVER_TREE_IDLE_SECONDS" ]; then
      new_state+="${root_pid}"$'\t'"${starttime}"$'\t'"${total_cpu}"$'\t'"${changed}"$'\n'
      continue
    fi

    descendant_count="$(get_descendants "$root_pid" | wc -l)"
    # kill_tree's own exit status is the source of truth for what actually
    # happened -- never assume success just because we decided to try.
    kill_tree "$root_pid" "$identity" >/dev/null 2>&1
    kill_status=$?
    case "$kill_status" in
      0)
        emit_result "auto" "$(kill_verb)" "server-main PID $root_pid" \
          "orphaned (ppid=1), no CPU activity across ${descendant_count} processes for ${idle_seconds}s"
        # killed (or would-kill in dry-run) -- drop from state; a real kill
        # needs it gone, a dry-run just re-derives the same idle_seconds
        # next run since nothing was actually touched.
        ;;
      2)
        # Self-chain overlap: kill_tree aborted per self-protection rule 4.
        # Keep tracking with the same `changed` timestamp so this keeps
        # alerting every run until a human resolves it -- never silently
        # drop a target the inspector refused to touch.
        emit_result "alert" "flagged" "server-main PID $root_pid" \
          "skipped: self-chain overlap -- target PID overlapped the inspector's own process chain, entire kill aborted"
        new_state+="${root_pid}"$'\t'"${starttime}"$'\t'"${total_cpu}"$'\t'"${changed}"$'\n'
        ;;
      *)
        : # identity changed since detection -- benign, drop from state
        ;;
    esac
  done

  printf '%b' "$new_state" > "${SERVER_TREE_STATE_FILE}.tmp.$$"
  mv "${SERVER_TREE_STATE_FILE}.tmp.$$" "$SERVER_TREE_STATE_FILE"
}

check_claude_sessions
check_orphaned_server_trees
