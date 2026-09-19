#!/usr/bin/env bash
# inspect.sh — vps_oracle host inspector, main entry.
#
# Runs every checks/*.sh script, collects their structured JSON-line
# output, and sends exactly one aggregated Telegram report via apprise
# -- regardless of whether anything needed attention, so "is the
# inspector still running" is itself observable (design spec's
# "notification format" section). All notification text is English by explicit
# user requirement (2026-08-16), even though repo docs are Chinese.
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

# Local checks, plus per-host remote checks that live under
# <repo>/<host>/inspector-checks/checks/ (they run here but inspect <host>).
REPO_ROOT="${INSPECTOR_REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
#
# Per-instance bookkeeping for the report: which instance a check inspects
# (local checks -> vps_oracle, <host>/inspector-checks/ -> <host>), how many
# checks ran, and how many result lines they produced. Without this a fully
# healthy report is identical whether or not a remote host was inspected.
declare -A inst_checks=() inst_lines=()
inst_order=()
for check in "$CHECKS_DIR"/*.sh "$REPO_ROOT"/*/inspector-checks/checks/*.sh; do
  [ -e "$check" ] || continue
  check_name="$(basename "$check")"
  case "$check" in
    "$CHECKS_DIR"/*) instance="vps_oracle" ;;
    *) instance="$(basename "$(dirname "$(dirname "$(dirname "$check")")")")" ;;
  esac
  if [ -z "${inst_checks[$instance]:-}" ]; then
    inst_order+=("$instance"); inst_checks[$instance]=0; inst_lines[$instance]=0
  fi
  inst_checks[$instance]=$((inst_checks[$instance] + 1))
  # Capture output unconditionally, THEN check the exit status -- a check
  # that emits a few valid result lines and then crashes partway through
  # must not have those already-emitted lines thrown away, on top of the
  # failure itself being reported. stderr is left to flow through to
  # inspect.sh's own stderr (systemd journal when run as a service)
  # rather than a temp file, so there's nothing here to leak/clean up.
  output="$("$check")"
  check_status=$?
  if [ -n "$output" ]; then
    printf '%s\n' "$output" >> "$results_file"
    inst_lines[$instance]=$((inst_lines[$instance] + $(grep -c . <<<"$output")))
  fi
  if [ "$check_status" -ne 0 ]; then
    emit_result "alert" "flagged" "check:$check_name" \
      "check script exited non-zero (status $check_status) -- see journalctl -u docker-gitops-inspector.service" \
      >> "$results_file"
    inst_lines[$instance]=$((inst_lines[$instance] + 1))
  fi
done

elapsed="$(awk -v s="$start_epoch" -v n="$(date +%s.%N)" 'BEGIN{printf "%.1f", n-s}')"

# Builds the HTML report body from collected JSON lines. Groups into
# "Auto-handled" (tier=auto) / "Needs manual review" (tier=alert)
# sections matching the spec's example format; a run with nothing to
# report prints a single reassuring line instead of two empty sections.
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

  # Always list every inspected instance, so "all clear" visibly covers
  # remote hosts too instead of looking like a vps_oracle-only run.
  local inst n l summary="Inspected"$'\n'
  for inst in "${inst_order[@]}"; do
    n="${inst_checks[$inst]}"; l="${inst_lines[$inst]}"
    local nw="checks" lw="result lines"
    [ "$n" -eq 1 ] && nw="check"
    [ "$l" -eq 1 ] && lw="result line"
    if [ "$l" -eq 0 ]; then
      summary+="✅ ${inst} — ${n} ${nw}, nothing flagged"$'\n'
    else
      summary+="⚠️ ${inst} — ${n} ${nw}, ${l} ${lw}"$'\n'
    fi
  done

  if [ -z "$auto_lines" ] && [ -z "$alert_lines" ]; then
    printf '✅ All clear — nothing needed attention\n\n%s\nRun took %ss' "$summary" "$elapsed"
    return
  fi

  local report=""
  [ -n "$auto_lines" ] && report+="Auto-handled"$'\n'"${auto_lines}"$'\n'
  [ -n "$alert_lines" ] && report+="Needs manual review"$'\n'"${alert_lines}"$'\n'
  report+="${summary}"$'\n'"Run took ${elapsed}s"
  printf '%s' "$report"
}

report_body="$(build_report)"
title="🔍 Inspection report · $(date '+%Y-%m-%d %H:%M')"
status="$(send_apprise "$title" "$report_body")"

if [ "$status" != "200" ]; then
  echo "WARNING: apprise notify returned HTTP $status" >&2
  exit 1
fi
