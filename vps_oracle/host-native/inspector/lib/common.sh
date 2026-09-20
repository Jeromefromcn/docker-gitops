#!/usr/bin/env bash
# lib/common.sh — shared helpers for the vps_oracle inspector.
# Sourced by inspect.sh and by each checks/*.sh script; never executed
# directly. See docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md
# "self-protection rules" section for why these specific functions exist — this file is
# the highest-risk part of the whole inspector (it's what decides what's
# safe to kill), so every function here has a matching case in
# tests/test-common.sh. Don't add a kill/delete path anywhere in this
# project that doesn't go through kill_tree.

CLK_TCK="$(getconf CLK_TCK)"

_COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSPECTOR_ROOT="$(cd "$_COMMON_SH_DIR/.." && pwd)"
INSPECTOR_STATE_DIR="${INSPECTOR_STATE_DIR:-$INSPECTOR_ROOT/state}"
mkdir -p "$INSPECTOR_STATE_DIR"

APPRISE_URL="${APPRISE_URL:-http://localhost:8000}"

# ---- self-chain: PIDs that must never be a kill target ----

# Prints the calling process's own PID plus every ancestor up to PID 1.
# A check script runs as a child of inspect.sh, which runs as a child of
# systemd (or an interactive shell during manual/dry-run testing) --
# this walk covers both without caring which one it is.
inspector_self_chain() {
  local pid="$$"
  while [ -n "$pid" ] && [ "$pid" != "1" ]; do
    echo "$pid"
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  done
  echo "1"
}

# ---- /proc readers ----

# Reads /proc/$1/stat and prints "state starttime utime stime".
# Parses defensively: the comm field (2nd field, in parens) can itself
# contain spaces or ")", so this splits on the LAST ") " in the line
# rather than assuming comm has none.
proc_stat_fields() {
  local pid="$1" stat_content after
  stat_content="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
  [ -n "$stat_content" ] || return 1
  after="${stat_content##*) }"
  local state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt \
        cmajflt utime stime cutime cstime priority nice num_threads \
        itrealvalue starttime rest
  read -r state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt \
       cmajflt utime stime cutime cstime priority nice num_threads \
       itrealvalue starttime rest <<<"$after"
  [ -n "$starttime" ] || return 1
  echo "$state $starttime $utime $stime"
}

proc_cmdline() {
  local pid="$1"
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null
}

# ---- PID identity: guards against PID reuse between detection and kill ----

capture_pid_identity() {
  local pid="$1" fields starttime
  fields="$(proc_stat_fields "$pid")" || return 1
  starttime="$(awk '{print $2}' <<<"$fields")"
  echo "${starttime}|$(proc_cmdline "$pid")"
}

# Re-checks that $1 still matches the identity captured earlier by
# capture_pid_identity ($2). Fails closed: any read error (pid gone,
# /proc race) counts as "does not match" -- never treat an unreadable
# pid as safe to kill.
verify_pid_identity() {
  local pid="$1" expected="$2" current
  current="$(capture_pid_identity "$pid" 2>/dev/null)" || return 1
  [ -n "$current" ] && [ "$current" = "$expected" ]
}

process_age_seconds() {
  local pid="$1" fields starttime uptime_now
  fields="$(proc_stat_fields "$pid")" || return 1
  starttime="$(awk '{print $2}' <<<"$fields")"
  uptime_now="$(awk '{print $1}' /proc/uptime)"
  awk -v u="$uptime_now" -v st="$starttime" -v hz="$CLK_TCK" \
    'BEGIN { printf "%d", u - (st / hz) }'
}

# ---- process tree ----

# Prints $1 and every descendant PID, parents before children. Uses
# `pgrep -P` (direct-children lookup) rather than hand-rolled /proc
# scanning -- confirmed present (procps-ng) on the target host.
get_descendants() {
  local root="$1" pid children
  echo "$root"
  children="$(pgrep -P "$root" 2>/dev/null)" || true
  for pid in $children; do
    get_descendants "$pid"
  done
}

# ---- self-protection gate + two-stage kill ----

# $1 is a newline-separated PID list (already expanded to a full
# subtree). Returns 0 if disjoint from the inspector's own ancestor
# chain, 2 (and logs to stderr) if ANY pid overlaps -- an overlap is
# not "skip that one pid", it aborts the whole batch per spec rule 4.
assert_no_self_overlap() {
  local list="$1" pid self_pid
  local self_chain
  self_chain="$(inspector_self_chain)"
  while read -r pid; do
    [ -z "$pid" ] && continue
    while read -r self_pid; do
      if [ "$pid" = "$self_pid" ]; then
        echo "ABORT: target pid $pid overlaps inspector self-chain" >&2
        return 2
      fi
    done <<<"$self_chain"
  done <<<"$list"
  return 0
}

# Two-stage kill of $1 (root pid) and its full subtree.
#   $1 = root pid, $2 = identity token from capture_pid_identity($1)
#   captured at detection time (re-verified here before sending TERM,
#   in case time passed between detection and this call).
# Honors INSPECTOR_DRY_RUN=1 (prints the target list, kills nothing)
# and INSPECTOR_KILL_GRACE_SECONDS (default 4, spec's TERM->wait->KILL
# gap). Prints the (would-be-)killed PID list on stdout.
kill_tree() {
  local root_pid="$1" root_identity="$2" targets pid

  if ! verify_pid_identity "$root_pid" "$root_identity"; then
    echo "SKIP: pid $root_pid identity changed since detection (exited or reused)" >&2
    return 1
  fi

  targets="$(get_descendants "$root_pid")"
  assert_no_self_overlap "$targets" || return 2

  if [ "${INSPECTOR_DRY_RUN:-0}" = "1" ]; then
    echo "$targets"
    return 0
  fi

  while read -r pid; do
    [ -z "$pid" ] && continue
    kill -TERM "$pid" 2>/dev/null || true
  done <<<"$targets"

  sleep "${INSPECTOR_KILL_GRACE_SECONDS:-4}"

  while read -r pid; do
    [ -z "$pid" ] && continue
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  done <<<"$targets"

  echo "$targets"
  return 0
}

# ---- human-readable formatting ----
# Report text is read by a human on Telegram, so every size and age in a
# detail string goes through one of these two. Raw byte counts and raw
# second counts never reach the report.

# human_bytes <bytes> -> "512 B" / "57.2 MiB" / "3.0 GiB" (base 1024).
human_bytes() {
  awk -v b="$1" 'BEGIN {
    split("B KiB MiB GiB TiB PiB", unit, " ")
    i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, unit[i]
    else printf "%.1f %s", b, unit[i]
  }'
}

# human_duration <seconds> -> "45s" / "15m 5s" / "2h 10m" / "7d 1h".
# Two units at most: the report wants a sense of scale, not precision.
human_duration() {
  awk -v s="$1" 'BEGIN {
    s = int(s); if (s < 0) s = 0
    d = int(s / 86400); s -= d * 86400
    h = int(s / 3600);  s -= h * 3600
    m = int(s / 60);    s -= m * 60
    if (d > 0)      printf "%dd%s", d, (h ? sprintf(" %dh", h) : "")
    else if (h > 0) printf "%dh%s", h, (m ? sprintf(" %dm", m) : "")
    else if (m > 0) printf "%dm%s", m, (s ? sprintf(" %ds", s) : "")
    else            printf "%ds", s
  }'
}

# ---- output + notification ----

# Prints one structured result line to stdout. inspect.sh collects
# these across all check scripts to build the Telegram report.
emit_result() {
  local tier="$1" action="$2" target="$3" detail="$4"
  jq -nc --arg tier "$tier" --arg action "$action" \
    --arg target "$target" --arg detail "$detail" \
    '{tier: $tier, action: $action, target: $target, detail: $detail}'
}

# Posts {title, body, format:"html"} to the inspector-tg apprise target.
# Prints the HTTP status code (200 on success).
send_apprise() {
  local title="$1" body="$2" payload
  payload="$(jq -nc --arg title "$title" --arg body "$body" \
    '{title: $title, body: $body, format: "html"}')"
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    "${APPRISE_URL}/notify/inspector-tg" \
    -H 'Content-Type: application/json' \
    -d "$payload"
}
