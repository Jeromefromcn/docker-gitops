# vps_oracle Inspector — Phase 1 (Core + VS Code Checks) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a real, deployable `vps_oracle/inspector/` that solves the motivating incident end-to-end — detects and cleans up stray VS Code/Claude session process trees and stale `.vscode-server` version directories, sends a Telegram report every run via the already-registered `inspector-tg` apprise target, and runs on a systemd timer.

**Architecture:** Host-native bash (no container — see spec's "架構" section for why). `lib/common.sh` holds the self-protection primitives (self-chain computation, PID identity verification, two-stage kill, apprise sender) shared by everything else. `inspect.sh` is the main entry: it globs `checks/*.sh`, runs each as a subprocess, collects their structured JSON-line output, and sends one aggregated Telegram report regardless of outcome. Each check script is independently executable and self-contained; `inspect.sh` has zero check-specific logic. This phase implements exactly two checks (`stray-vscode-sessions.sh`, `vscode-server-versions.sh`) — the ones that directly address the source incidents — plus the systemd deployment. Docker/k3s hygiene checks are a separate follow-up plan; `inspect.sh`'s glob-based discovery means adding them later requires no changes here.

**Tech Stack:** bash (`set -uo pipefail`, deliberately not `-e` — see Task 1 note), `jq` 1.7 (present on host), `curl`, `/proc` filesystem, systemd (service + timer, no install.sh — see spec's "部署" section).

**Spec:** [`docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md`](../specs/2026-08-15-vps-oracle-inspector-design.md)

## Global Constraints

- **Report every run, no exceptions**: `inspect.sh` sends exactly one Telegram message per run via the `inspector-tg` apprise target (`http://localhost:30085/notify/inspector-tg` — apprise is a k3s NodePort, not a docker container, see spec's updated "通知格式" section), whether or not anything needed attention. If nothing happened, the message is `✅ 一切正常，無需處理`.
- **Self-protection is non-negotiable**: every kill path must (1) compute the inspector's own process ancestor chain, (2) re-verify a target PID's identity (start time) immediately before killing it, (3) send `TERM` then wait then `KILL` survivors — never `-9` first, (4) abort the *entire* batch (not just skip one item) if any target overlaps the self-chain. These four rules live in `lib/common.sh` and must have their own automated verification script, not just a manual read-through (spec's "測試方式" §2).
- **`INSPECTOR_DRY_RUN=1`**: when set, every check script that would kill/delete must instead print `would-kill`/`would-delete` and take no destructive action. This must be exercised for real (several dry runs) before any real run.
- **No config-file mutation**: checks only clean up resources or alert; none of them edit compose/k8s config files (spec's "非目標").
- **Thresholds are overridable env vars declared at the top of each script**, not hardcoded inline, so they can be tuned later from observed reports without code changes.
- **systemd runs as `ubuntu`, not root**: killing session processes and calling apprise over HTTP both work fine as the `ubuntu` user; nothing in this phase needs root.
- **No `install.sh`**: `ExecStart` points directly at the repo checkout path. `git pull`/`git commit` is the deploy step. (Explicitly avoiding the claude-code-notify "forgot to run install.sh" failure mode — see [[claude_code_notify_deploy_path]] territory, and spec's "部署" section.)
- **`vps_oracle/inspector/state/` is gitignored** — runtime dedup/comparison state, not version-controlled.

---

## File Structure

```
vps_oracle/inspector/
├── inspect.sh                       # Task 4 — main entry
├── lib/
│   └── common.sh                    # Task 1 — self-protection + apprise send + emit_result
├── checks/
│   ├── stray-vscode-sessions.sh     # Task 2
│   └── vscode-server-versions.sh    # Task 3
├── tests/
│   ├── test-common.sh               # Task 1 — verification for lib/common.sh
│   ├── test-stray-vscode-sessions.sh   # Task 2
│   ├── test-vscode-server-versions.sh  # Task 3
│   └── fixtures/
│       └── spawn-chain.sh           # Task 1 — spawns a disposable real process tree for tests
├── systemd/
│   ├── docker-gitops-inspector.service  # Task 5
│   └── docker-gitops-inspector.timer    # Task 5
├── state/                           # created at runtime, gitignored
└── README.md                        # Task 5
```

(The spec's file-tree diagram doesn't list a `tests/` directory, but its "測試方式" section explicitly requires a minimal verification script for `lib/common.sh`'s self-protection functions — `tests/` is where that lives, plus a matching test per check script for the same "don't just eyeball it" reason.)

---

### Task 1: `lib/common.sh` — self-protection primitives + apprise sender

**Files:**
- Create: `vps_oracle/inspector/lib/common.sh`
- Create: `vps_oracle/inspector/tests/fixtures/spawn-chain.sh`
- Create: `vps_oracle/inspector/tests/test-common.sh`
- Modify: `.gitignore` (add `vps_oracle/inspector/state/`)

**Interfaces:**
- Consumes: nothing (first task)
- Produces (used by Tasks 2–4):
  - `inspector_self_chain()` → prints newline-separated PIDs (own pid up to pid 1)
  - `proc_stat_fields(pid)` → prints `"state starttime utime stime"` or returns 1 if pid doesn't exist
  - `proc_cmdline(pid)` → prints the process's null-joined cmdline as space-joined text
  - `capture_pid_identity(pid)` → prints `"starttime|cmdline"` token, or returns 1
  - `verify_pid_identity(pid, identity_token)` → returns 0 if still matching, 1 otherwise
  - `process_age_seconds(pid)` → prints integer seconds since process start, or returns 1
  - `get_descendants(root_pid)` → prints root_pid plus every descendant, one per line
  - `assert_no_self_overlap(newline_pid_list)` → returns 0 if disjoint from self-chain, 2 (and prints to stderr) if overlapping
  - `kill_tree(root_pid, identity_token)` → two-stage kill of the whole subtree; prints the killed/would-kill PID list; returns 0 on success, 1 if identity no longer matches (skip, not an error), 2 if self-chain overlap (abort)
  - `emit_result(tier, action, target, detail)` → prints one `{"tier":...}` JSON line
  - `send_apprise(title, body)` → POSTs to apprise, prints the HTTP status code
  - Env-derived vars: `CLK_TCK`, `INSPECTOR_ROOT`, `INSPECTOR_STATE_DIR` (auto-created), `APPRISE_URL` (default `http://localhost:30085`)

- [ ] **Step 1: Write `lib/common.sh`**

```bash
#!/usr/bin/env bash
# lib/common.sh — shared helpers for the vps_oracle inspector.
# Sourced by inspect.sh and by each checks/*.sh script; never executed
# directly. See docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md
# "自我保護規則" for why these specific functions exist — this file is
# the highest-risk part of the whole inspector (it's what decides what's
# safe to kill), so every function here has a matching case in
# tests/test-common.sh. Don't add a kill/delete path anywhere in this
# project that doesn't go through kill_tree.

CLK_TCK="$(getconf CLK_TCK)"

_COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSPECTOR_ROOT="$(cd "$_COMMON_SH_DIR/.." && pwd)"
INSPECTOR_STATE_DIR="${INSPECTOR_STATE_DIR:-$INSPECTOR_ROOT/state}"
mkdir -p "$INSPECTOR_STATE_DIR"

APPRISE_URL="${APPRISE_URL:-http://localhost:30085}"

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
```

- [ ] **Step 2: `chmod` and syntax-check**

```bash
chmod 644 vps_oracle/inspector/lib/common.sh   # sourced, not executed
bash -n vps_oracle/inspector/lib/common.sh
```
Expected: no output (syntax OK).

- [ ] **Step 3: Add `state/` to `.gitignore`**

Add this line to the root `.gitignore`, in the existing "runtime logs written by containers into mounted config dirs" section (same style as the existing `vps_oracle/compose/homepage/config/logs/` entry — a specific path, not a glob, matching this repo's existing convention):

```
vps_oracle/inspector/state/
```

- [ ] **Step 4: Write the process-tree test fixture**

```bash
#!/usr/bin/env bash
# spawn-chain.sh OUT_FILE DEPTH
#
# Builds a real chain of DEPTH nested processes, each the direct parent
# of the next, and appends each generation's PID (root first) to
# OUT_FILE. Used only by tests/test-common.sh to exercise
# get_descendants/kill_tree against a real, disposable process tree
# instead of mocking /proc. The trick: each generation backgrounds the
# next generation as a real child *before* exec-ing into `sleep` --
# exec replaces the running program but does not change the PID or its
# already-established parent/child relationships, so the chain survives
# the exec.
out_file="$1"
depth="${2:-3}"

echo "$$" >> "$out_file"

if [ "$depth" -gt 1 ]; then
  bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spawn-chain.sh" \
    "$out_file" $((depth - 1)) &
fi

exec sleep 300
```

- [ ] **Step 5: `chmod +x` the fixture**

```bash
chmod +x vps_oracle/inspector/tests/fixtures/spawn-chain.sh
```

- [ ] **Step 6: Write `tests/test-common.sh`**

```bash
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
  "$([ "$(grep -c "^${$}\$" <<<"$chain")" -ge 1 ] && echo true || echo false)"
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
```

- [ ] **Step 7: `chmod +x` and run the test**

```bash
chmod +x vps_oracle/inspector/tests/test-common.sh
cd vps_oracle/inspector && ./tests/test-common.sh
```
Expected: every line starts `ok -`, final line `PASS: all common.sh self-protection checks passed`, exit code 0. If anything prints `FAIL -`, stop and fix `lib/common.sh` before moving to Task 2 — this is the one piece of the whole project that must be right before anything builds on it.

- [ ] **Step 8: Commit**

```bash
git add vps_oracle/inspector/lib/common.sh \
        vps_oracle/inspector/tests/test-common.sh \
        vps_oracle/inspector/tests/fixtures/spawn-chain.sh \
        .gitignore
git commit -m "Add inspector self-protection library (common.sh) with verification tests"
```

---

### Task 2: `checks/stray-vscode-sessions.sh`

Handles all three process-related rows from the spec's check table in one script (they share the same underlying data sources and the auto/alert split is a threshold, not a different mechanism):

1. **Auto**: a `claude` session whose transcript's last line has `"type":"result"` (finished normally) but the process is still alive past `INSPECTOR_STRAY_SESSION_IDLE_SECONDS` (default 1800 = 30 min) → `kill_tree`.
2. **Auto**: an orphaned `server-main.js` tree (`ppid=1`, i.e. the SSH client disconnected without the server self-shutting-down) with zero CPU activity across every descendant for `INSPECTOR_SERVER_TREE_IDLE_SECONDS` (default 7200 = 2h) → `kill_tree`. CPU-activity is tracked across runs via a state file, since a single snapshot can't show "idle".
3. **Alert only**: a `claude` session whose transcript has no `result` yet (i.e. maybe still genuinely working) but has been alive past `INSPECTOR_STUCK_SESSION_ALERT_SECONDS` (default 21600 = 6h) → flagged for human review, never touched.

Session discovery uses `~/.claude/sessions/<pid>.json` (written by the Claude Code CLI itself: `{"pid":...,"sessionId":...,"cwd":...,"procStart":...}` — confirmed on this host that `procStart` is exactly `/proc/<pid>/stat`'s field 22, i.e. it's already the PID-identity fingerprint this project needs) rather than `ps | grep`-style pattern matching, which sidesteps the exact self-matching footgun the source incident's cleanup ran into.

**Files:**
- Create: `vps_oracle/inspector/checks/stray-vscode-sessions.sh`
- Create: `vps_oracle/inspector/tests/test-stray-vscode-sessions.sh`

**Interfaces:**
- Consumes: `lib/common.sh`'s `capture_pid_identity`, `verify_pid_identity`, `process_age_seconds`, `get_descendants`, `kill_tree`, `emit_result`, `INSPECTOR_STATE_DIR`
- Produces: an executable script; when run, prints zero or more `emit_result`-shaped JSON lines to stdout and exits 0. Reads/writes `$INSPECTOR_STATE_DIR/server-tree-cpu.tsv` (format: `root_pid<TAB>starttime<TAB>total_cpu_ticks<TAB>last_changed_epoch`, one line per currently-tracked orphaned server-main tree).
- Overridable env vars: `INSPECTOR_CLAUDE_SESSIONS_DIR` (default `$HOME/.claude/sessions`), `INSPECTOR_CLAUDE_PROJECTS_DIR` (default `$HOME/.claude/projects`), `INSPECTOR_STRAY_SESSION_IDLE_SECONDS` (1800), `INSPECTOR_STUCK_SESSION_ALERT_SECONDS` (21600), `INSPECTOR_SERVER_TREE_IDLE_SECONDS` (7200)

- [ ] **Step 1: Write `checks/stray-vscode-sessions.sh`**

```bash
#!/usr/bin/env bash
# checks/stray-vscode-sessions.sh
#
# Covers the three process-related rows of the design spec's check
# table: finished-but-lingering claude sessions (auto-kill), orphaned
# server-main trees with no CPU activity (auto-kill), and long-running
# claude sessions with no transcript result yet (alert only). See
# docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md.
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
STUCK_SESSION_ALERT_SECONDS="${INSPECTOR_STUCK_SESSION_ALERT_SECONDS:-21600}"
SERVER_TREE_IDLE_SECONDS="${INSPECTOR_SERVER_TREE_IDLE_SECONDS:-7200}"
SERVER_TREE_STATE_FILE="$INSPECTOR_STATE_DIR/server-tree-cpu.tsv"

kill_verb() {
  [ "${INSPECTOR_DRY_RUN:-0}" = "1" ] && echo "would-kill" || echo "killed"
}

# ---- part 1: per-session transcript check ----

check_claude_sessions() {
  local session_file pid session_id cwd proc_start
  local identity current_starttime transcript last_type age kill_status

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
      if [ "$age" -ge "$STUCK_SESSION_ALERT_SECONDS" ]; then
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
```

- [ ] **Step 2: `chmod +x` and syntax-check**

```bash
chmod +x vps_oracle/inspector/checks/stray-vscode-sessions.sh
bash -n vps_oracle/inspector/checks/stray-vscode-sessions.sh
```

- [ ] **Step 3: Write `tests/test-stray-vscode-sessions.sh`**

Uses a hermetic fixture directory (not the real `~/.claude/sessions`) so the test never risks matching a real session, and a real disposable process (via the Task 1 fixture) so `process_age_seconds`/PID-liveness logic is exercised truthfully rather than mocked.

```bash
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
```

- [ ] **Step 4: `chmod +x` and run**

```bash
chmod +x vps_oracle/inspector/tests/test-stray-vscode-sessions.sh
cd vps_oracle/inspector && ./tests/test-stray-vscode-sessions.sh
```
Expected: all `ok -` lines, final `PASS`, exit 0.

- [ ] **Step 5: Dry-run against real host state (sanity check, not automated)**

```bash
cd vps_oracle/inspector && INSPECTOR_DRY_RUN=1 ./checks/stray-vscode-sessions.sh
```
Expected: exits 0, prints zero or more valid JSON lines (pipe through `jq .` to confirm), and does **not** propose killing any PID that's part of the current interactive session running this command. Eyeball the output against `ps` before trusting it.

- [ ] **Step 6: Commit**

```bash
git add vps_oracle/inspector/checks/stray-vscode-sessions.sh \
        vps_oracle/inspector/tests/test-stray-vscode-sessions.sh
git commit -m "Add stray-vscode-sessions check: finished/stuck sessions + orphaned server-main trees"
```

---

### Task 3: `checks/vscode-server-versions.sh`

Deletes stale `~/.vscode-server/cli/servers/<version>/` directories: not among the `INSPECTOR_KEEP_SERVER_VERSIONS` (default 2) most-recently-used entries in `lru.json`, and not referenced by any currently-running `server-main.js` process. Scope is deliberately limited to `cli/servers/*` (matches the spec's "6 個版本目錄/3.8G" incident reference) — the separate, much smaller `~/.vscode-server/code-<commit>` CLI-tunnel binaries are out of scope for this check (not mentioned in the spec; note this boundary in the README, Task 5).

**Files:**
- Create: `vps_oracle/inspector/checks/vscode-server-versions.sh`
- Create: `vps_oracle/inspector/tests/test-vscode-server-versions.sh`

**Interfaces:**
- Consumes: `lib/common.sh`'s `emit_result` only (no process-kill primitives needed — this check deletes directories, not processes)
- Produces: an executable script; prints zero or more `emit_result`-shaped JSON lines, exits 0
- Overridable env vars: `INSPECTOR_VSCODE_SERVERS_DIR` (default `$HOME/.vscode-server/cli/servers`), `INSPECTOR_KEEP_SERVER_VERSIONS` (default 2)

- [ ] **Step 1: Write `checks/vscode-server-versions.sh`**

```bash
#!/usr/bin/env bash
# checks/vscode-server-versions.sh
#
# Deletes stale ~/.vscode-server/cli/servers/<version>/ directories:
# not among the N most-recently-used entries in lru.json, and not
# referenced by any live server-main.js process. See design spec's
# "VS Code server 版本目錄堆積" row.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

SERVERS_DIR="${INSPECTOR_VSCODE_SERVERS_DIR:-$HOME/.vscode-server/cli/servers}"
KEEP_COUNT="${INSPECTOR_KEEP_SERVER_VERSIONS:-2}"
LRU_FILE="$SERVERS_DIR/lru.json"

[ -d "$SERVERS_DIR" ] || exit 0

mapfile -t existing_dirs < <(
  find "$SERVERS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
)
[ "${#existing_dirs[@]}" -eq 0 ] && exit 0

mapfile -t lru_order < <(jq -r '.[]?' "$LRU_FILE" 2>/dev/null)

declare -A keep
kept=0
for name in "${lru_order[@]}"; do
  [ "$kept" -ge "$KEEP_COUNT" ] && break
  for existing in "${existing_dirs[@]}"; do
    if [ "$name" = "$existing" ]; then
      keep["$name"]=1
      kept=$((kept + 1))
      break
    fi
  done
done

for dir in "${existing_dirs[@]}"; do
  [ -n "${keep[$dir]:-}" ] && continue

  if pgrep -f "vscode-server/cli/servers/${dir}/server/out/server-main\\.js" >/dev/null 2>&1; then
    continue   # actively referenced by a live process -- never delete
  fi

  size="$(du -sh "$SERVERS_DIR/$dir" 2>/dev/null | cut -f1)"
  detail="not in top ${KEEP_COUNT} lru.json entries, no active process, size=${size:-unknown}"

  if [ "${INSPECTOR_DRY_RUN:-0}" = "1" ]; then
    emit_result "auto" "would-delete" "$dir" "$detail"
  else
    rm -rf "${SERVERS_DIR:?}/${dir:?}"
    emit_result "auto" "deleted" "$dir" "$detail"
  fi
done
```

- [ ] **Step 2: `chmod +x` and syntax-check**

```bash
chmod +x vps_oracle/inspector/checks/vscode-server-versions.sh
bash -n vps_oracle/inspector/checks/vscode-server-versions.sh
```

- [ ] **Step 3: Write `tests/test-vscode-server-versions.sh`**

Builds a hermetic fixture directory tree (never the real `~/.vscode-server`) with fake version dirs and a fake `lru.json`, so `rm -rf` in the test run only ever touches the fixture.

```bash
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
```

- [ ] **Step 4: `chmod +x` and run**

```bash
chmod +x vps_oracle/inspector/tests/test-vscode-server-versions.sh
cd vps_oracle/inspector && ./tests/test-vscode-server-versions.sh
```
Expected: all `ok -`, final `PASS`, exit 0.

- [ ] **Step 5: Dry-run against real host state (sanity check)**

```bash
cd vps_oracle/inspector && INSPECTOR_DRY_RUN=1 ./checks/vscode-server-versions.sh
```
Expected: exits 0. On this host, both existing version dirs (`Stable-a5b5...`, `Stable-1b6a...`) are within the default keep-count of 2, so expect **no output** right now — that's correct, not a bug.

- [ ] **Step 6: Commit**

```bash
git add vps_oracle/inspector/checks/vscode-server-versions.sh \
        vps_oracle/inspector/tests/test-vscode-server-versions.sh
git commit -m "Add vscode-server-versions check: prune stale server version directories"
```

---

### Task 4: `inspect.sh` — main entry

**Files:**
- Create: `vps_oracle/inspector/inspect.sh`
- Create: `vps_oracle/inspector/tests/test-inspect.sh`

**Interfaces:**
- Consumes: `lib/common.sh`'s `emit_result`, `send_apprise`; the check-script contract from Tasks 2–3 (any executable in `checks/*.sh` that prints zero or more `emit_result`-shaped JSON lines and exits 0 on success)
- Produces: `inspect.sh`, executable, no CLI args; reads `INSPECTOR_DRY_RUN` and passes it through to check scripts via the environment (checks already read it directly, no explicit plumbing needed since child processes inherit exported env vars — `inspect.sh` must `export INSPECTOR_DRY_RUN` if set, since a shell var isn't inherited by subprocesses unless exported)

- [ ] **Step 1: Write `inspect.sh`**

```bash
#!/usr/bin/env bash
# inspect.sh — vps_oracle host inspector, main entry.
#
# Runs every checks/*.sh script, collects their structured JSON-line
# output, and sends exactly one aggregated Telegram report via apprise
# -- regardless of whether anything needed attention, so "is the
# inspector still running" is itself observable (design spec's
# "通知格式" section).
#
# Not `set -e`: one check script crashing must not abort the whole run
# and silently skip the report -- a crashing check becomes an alert
# line in the report instead (see the loop below).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

[ -n "${INSPECTOR_DRY_RUN:-}" ] && export INSPECTOR_DRY_RUN

CHECKS_DIR="$SCRIPT_DIR/checks"
results_file="$(mktemp)"
trap 'rm -f "$results_file"' EXIT

start_epoch="$(date +%s.%N)"

for check in "$CHECKS_DIR"/*.sh; do
  [ -e "$check" ] || continue
  check_name="$(basename "$check")"
  # Capture output unconditionally, THEN check the exit status -- a check
  # that emits a few valid result lines and then crashes partway through
  # must not have those already-emitted lines thrown away, on top of the
  # failure itself being reported. stderr is left to flow through to
  # inspect.sh's own stderr (systemd journal when run as a service)
  # rather than a temp file, so there's nothing here to leak/clean up.
  output="$("$check")"
  check_status=$?
  [ -n "$output" ] && printf '%s\n' "$output" >> "$results_file"
  if [ "$check_status" -ne 0 ]; then
    emit_result "alert" "flagged" "check:$check_name" \
      "check script exited non-zero (status $check_status) -- see journalctl -u docker-gitops-inspector.service" \
      >> "$results_file"
  fi
done

elapsed="$(awk -v s="$start_epoch" -v n="$(date +%s.%N)" 'BEGIN{printf "%.1f", n-s}')"

# Builds the HTML report body from collected JSON lines. Groups into
# "已自動處理" (tier=auto) / "需要人工確認" (tier=alert) sections
# matching the spec's example format; a run with nothing to report
# prints a single reassuring line instead of two empty sections.
build_report() {
  local line tier action target detail
  local auto_lines="" alert_lines=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    jq -e . >/dev/null 2>&1 <<<"$line" || continue
    tier="$(jq -r '.tier' <<<"$line")"
    action="$(jq -r '.action' <<<"$line")"
    target="$(jq -r '.target' <<<"$line")"
    detail="$(jq -r '.detail' <<<"$line")"
    if [ "$tier" = "auto" ]; then
      auto_lines+="✅ ${action}: ${target}"$'\n'"   ${detail}"$'\n'
    elif [ "$tier" = "alert" ]; then
      alert_lines+="⚠️ ${target}"$'\n'"   ${detail}"$'\n'
    fi
  done < "$results_file"

  if [ -z "$auto_lines" ] && [ -z "$alert_lines" ]; then
    printf '✅ 一切正常，無需處理\n\n本次耗時 %ss' "$elapsed"
    return
  fi

  local report=""
  [ -n "$auto_lines" ] && report+="已自動處理"$'\n'"${auto_lines}"$'\n'
  [ -n "$alert_lines" ] && report+="需要人工確認"$'\n'"${alert_lines}"$'\n'
  report+="本次耗時 ${elapsed}s"
  printf '%s' "$report"
}

report_body="$(build_report)"
title="🔍 巡檢報告 vps_oracle · $(date '+%Y-%m-%d %H:%M')"
status="$(send_apprise "$title" "$report_body")"

if [ "$status" != "200" ]; then
  echo "WARNING: apprise notify returned HTTP $status" >&2
  exit 1
fi
```

- [ ] **Step 2: `chmod +x` and syntax-check**

```bash
chmod +x vps_oracle/inspector/inspect.sh
bash -n vps_oracle/inspector/inspect.sh
```

- [ ] **Step 3: Write `tests/test-inspect.sh`**

Uses a hermetic fake `checks/` directory (two tiny stub scripts) so the aggregation/report-building logic is tested in isolation from the real checks, then a separate real end-to-end dry run against the actual `checks/` directory (which legitimately hits the already-registered `inspector-tg` apprise target — this is the integration point that proves the whole pipeline works, not just each piece alone).

```bash
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
```

- [ ] **Step 4: `chmod +x` and run**

```bash
chmod +x vps_oracle/inspector/tests/test-inspect.sh
cd vps_oracle/inspector && ./tests/test-inspect.sh
```
Expected: all `ok -`, final `PASS`, exit 0. Check the "OCI System inspection" Telegram group for the real dry-run report (it should show up).

- [ ] **Step 5: Commit**

```bash
git add vps_oracle/inspector/inspect.sh vps_oracle/inspector/tests/test-inspect.sh
git commit -m "Add inspect.sh: check discovery, result aggregation, apprise reporting"
```

---

### Task 5: systemd deployment + README

**Files:**
- Create: `vps_oracle/inspector/systemd/docker-gitops-inspector.service`
- Create: `vps_oracle/inspector/systemd/docker-gitops-inspector.timer`
- Create: `vps_oracle/inspector/README.md`

**Interfaces:**
- Consumes: absolute path to `inspect.sh` (Task 4)
- Produces: an installed, enabled systemd timer running the inspector twice daily

- [ ] **Step 1: Write `systemd/docker-gitops-inspector.service`**

```ini
[Unit]
Description=docker-gitops host inspector (vps_oracle) — stray session cleanup + resource report
After=network-online.target

[Service]
Type=oneshot
User=ubuntu
WorkingDirectory=/home/ubuntu/jerome/docker-gitops/vps_oracle/inspector
ExecStart=/home/ubuntu/jerome/docker-gitops/vps_oracle/inspector/inspect.sh
```

- [ ] **Step 2: Write `systemd/docker-gitops-inspector.timer`**

```ini
[Unit]
Description=Run docker-gitops-inspector.service twice daily

[Timer]
OnCalendar=09:00,21:00
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Write `README.md`**

```markdown
# vps_oracle/inspector

Host-level巡檢腳本，非 docker compose 管理（跟 `vps_oracle/k3s/` 一樣是 `<host>/` 下的非 compose 子目錄，見 repo 根 README「目錄結構」一節）。設計背景、分級規則、自我保護規則見
[`docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md`](../../docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md)。

## 現況（phase 1）

已實作：
- `checks/stray-vscode-sessions.sh` — 游離/卡死的 claude session、脫離連線的 server-main 樹
- `checks/vscode-server-versions.sh` — 堆積的 `.vscode-server/cli/servers/*` 版本目錄

尚未實作（見另一份 phase 2 計畫）：docker 層與 k3s 層的資源清理 checks。新增時只要在 `checks/` 加一個新的可執行腳本，`inspect.sh` 用 glob 自動發現，不用改這裡任何現有代碼。

**範圍邊界**：`vscode-server-versions.sh` 只清 `cli/servers/<version>/` 這種大目錄（單個 500-650M 級別），不動 `~/.vscode-server/code-<commit>` 這類小得多的 CLI tunnel binary（~27M/個）——spec 沒把它們列進范围，之后想扩再加新 check。

## 執行

```bash
cd vps_oracle/inspector
./inspect.sh                    # 正式跑一次，會發 Telegram
INSPECTOR_DRY_RUN=1 ./inspect.sh  # 只印 would-kill/would-delete，不動手
```

## 測試

```bash
cd vps_oracle/inspector
./tests/test-common.sh
./tests/test-stray-vscode-sessions.sh
./tests/test-vscode-server-versions.sh
./tests/test-inspect.sh   # 最後一段會真的打 apprise inspector-tg，Telegram 群組要收得到
```

`tests/test-common.sh` 是全案最重要的一份測試——它驗證的是「絕不誤殺自己」這條規則本身，不能只靠人工看一遍代碼，見 spec 的「自我保護規則」一節。

## 部署

```bash
sudo ln -sf $(pwd)/systemd/docker-gitops-inspector.service /etc/systemd/system/
sudo ln -sf $(pwd)/systemd/docker-gitops-inspector.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now docker-gitops-inspector.timer
```

用 symlink 不是複製——改代碼、`git pull`/`git commit` 完就是生效狀態，不用另外跑 install.sh（見 claude-code-notify 的教訓：獨立 install 步驟容易忘記跑）。改動 unit 檔案結構本身（不是 `inspect.sh` 內容）時才需要重新 `daemon-reload`。

手動觸發一次：`sudo systemctl start docker-gitops-inspector.service`；看結果：`sudo systemctl status docker-gitops-inspector.service` / `journalctl -u docker-gitops-inspector.service -n 50`。

## apprise target

`inspector-tg` 已於 2026-08-16 註冊完成（沿用 vikunja 既有 bot token，指向 Telegram 群組 "OCI System inspection"）。apprise 現在是 k3s NodePort（`http://localhost:30085`），不是 docker 容器，見 spec 文件「通知格式」節的更新說明。

## 上線紀律

1. `INSPECTOR_DRY_RUN=1` 先跑幾輪，核對報告跟實際狀態相符（尤其 `stray-vscode-sessions.sh` 不能把還在互動的 session 判定為游離）。
2. 正式模式上線後先觀察幾天的 Telegram 報告，確認沒有誤殺才算穩定——不是一上線就信任自動 kill。
```

- [ ] **Step 4: Manual deploy + smoke test**

```bash
cd vps_oracle/inspector
sudo ln -sf "$(pwd)/systemd/docker-gitops-inspector.service" /etc/systemd/system/
sudo ln -sf "$(pwd)/systemd/docker-gitops-inspector.timer" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now docker-gitops-inspector.timer
sudo systemctl start docker-gitops-inspector.service
sudo systemctl status docker-gitops-inspector.service --no-pager
```
Expected: `status` shows the last run as `Succeeded` (`Type=oneshot`). Confirm a real report ("🔍 巡檢報告 vps_oracle · ...") landed in the "OCI System inspection" Telegram group — this run is **not** dry-run, so also confirm nothing unexpected got killed/deleted (`journalctl -u docker-gitops-inspector.service -n 50` shows what it did).

- [ ] **Step 5: Commit**

```bash
git add vps_oracle/inspector/systemd/ vps_oracle/inspector/README.md
git commit -m "Add systemd timer deployment and README for vps_oracle inspector"
```

---

## Definition of Done (Phase 1)

- [ ] `./tests/test-common.sh`, `test-stray-vscode-sessions.sh`, `test-vscode-server-versions.sh`, `test-inspect.sh` all pass
- [ ] `INSPECTOR_DRY_RUN=1 ./inspect.sh` run manually against real host state, output reviewed by a human, nothing surprising
- [ ] `docker-gitops-inspector.timer` installed and enabled; one real (non-dry-run) manual run completed via `systemctl start`, confirmed via `journalctl` that nothing was wrongly killed/deleted
- [ ] A real Telegram report received in "OCI System inspection" from the real timer-triggered or manual run
- [ ] All five tasks committed as separate commits (already true if each task's Step "Commit" was followed)
