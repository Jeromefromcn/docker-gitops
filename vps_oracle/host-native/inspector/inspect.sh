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
# One results file per inspected instance, so the report can group by instance.
results_dir="$(mktemp -d)"
trap 'rm -rf "$results_dir"' EXIT

start_epoch="$(date +%s.%N)"

# Local checks, plus per-host remote checks that live under
# <repo>/<host>/inspector-checks/checks/ (they run here but inspect <host>).
REPO_ROOT="${INSPECTOR_REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
# Which instance a check inspects: local checks -> vps_oracle,
# <host>/inspector-checks/ -> <host>. The report is one logical inspection
# grouped by instance, so it never matters which machine ran the script.
declare -A inst_checks=()
inst_order=()
for check in "$CHECKS_DIR"/*.sh "$REPO_ROOT"/*/inspector-checks/checks/*.sh; do
  [ -e "$check" ] || continue
  check_name="$(basename "$check")"
  case "$check" in
    "$CHECKS_DIR"/*) instance="vps_oracle" ;;
    *) instance="$(basename "$(dirname "$(dirname "$(dirname "$check")")")")" ;;
  esac
  if [ -z "${inst_checks[$instance]:-}" ]; then
    inst_order+=("$instance"); inst_checks[$instance]=0
  fi
  inst_checks[$instance]=$((inst_checks[$instance] + 1))
  results_file="$results_dir/$instance"
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

# Builds the HTML report body: one block per inspected instance. Each block
# has a status header (all clear / N auto-handled / N need review) and, only
# when there is something to say, "Auto-handled" (tier=auto) and "Needs manual
# review" (tier=alert) lines. Every instance always appears, so an all-clear
# run visibly covers remote hosts too.
build_report() {
  local inst file line tier action target detail n nw
  local auto_lines alert_lines n_auto n_alert header body=""

  for inst in "${inst_order[@]}"; do
    file="$results_dir/$inst"
    auto_lines=""; alert_lines=""; n_auto=0; n_alert=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      jq -e . >/dev/null 2>&1 <<<"$line" || continue
      tier="$(jq -r '.tier' <<<"$line")"
      action="$(jq -r '.action' <<<"$line")"
      target="$(jq -r '.target' <<<"$line")"
      detail="$(jq -r '.detail' <<<"$line")"
      if [ "$tier" = "auto" ]; then
        auto_lines+="   ✅ ${action}: ${target}"$'\n'"      ${detail}"$'\n'; n_auto=$((n_auto + 1))
      elif [ "$tier" = "alert" ]; then
        alert_lines+="   ⚠️ ${target}"$'\n'"      ${detail}"$'\n'; n_alert=$((n_alert + 1))
      fi
    done < <([ -f "$file" ] && cat "$file")

    n="${inst_checks[$inst]}"; nw="checks"; [ "$n" -eq 1 ] && nw="check"
    if [ "$n_alert" -gt 0 ]; then
      header="⚠️ ${inst} — ${n} ${nw}, ${n_alert} need review"
      [ "$n_auto" -gt 0 ] && header+=", ${n_auto} auto-handled"
    elif [ "$n_auto" -gt 0 ]; then
      header="✅ ${inst} — ${n} ${nw}, ${n_auto} auto-handled"
    else
      header="✅ ${inst} — ${n} ${nw}, all clear"
    fi
    body+="${header}"$'\n'
    [ -n "$auto_lines" ] && body+="   Auto-handled"$'\n'"${auto_lines}"
    [ -n "$alert_lines" ] && body+="   Needs manual review"$'\n'"${alert_lines}"
  done

  printf '%s\nRun took %ss' "$body" "$elapsed"
}

report_body="$(build_report)"
title="🔍 Inspection report · $(date '+%Y-%m-%d %H:%M')"
status="$(send_apprise "$title" "$report_body")"

if [ "$status" != "200" ]; then
  echo "WARNING: apprise notify returned HTTP $status" >&2
  exit 1
fi
