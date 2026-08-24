#!/usr/bin/env bash
# checks/k3s-completed-jobs.sh
#
# Deletes completed Jobs older than INSPECTOR_COMPLETED_JOB_MAX_AGE_
# SECONDS (default 3 days). Design spec's "k3s Completed Job 堆積" row
# (auto tier). Age-only on purpose: the spec's "超過 N 個或超過 N 天"
# offers count or age, and a count cap would delete fresh jobs whose
# output someone may still be reading — age is the low-misjudgment-cost
# dimension, matching the spec's own tiering philosophy.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

MAX_AGE_SECONDS="${INSPECTOR_COMPLETED_JOB_MAX_AGE_SECONDS:-259200}"
KUBECONFIG_FILE="${INSPECTOR_KUBECONFIG:-$INSPECTOR_STATE_DIR/kubeconfig}"

if [ ! -f "$KUBECONFIG_FILE" ]; then
  emit_result "alert" "flagged" "check:k3s-completed-jobs.sh" \
    "inspector kubeconfig missing at $KUBECONFIG_FILE — run k3s/setup-kubeconfig.sh once (see README)"
  exit 0
fi

kc() { kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"; }

jobs_json="$(kc get jobs -A -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:k3s-completed-jobs.sh" \
    "kubernetes API not reachable via inspector kubeconfig — check skipped"
  exit 0
}

now_epoch="$(date +%s)"

while read -r line; do
  [ -n "$line" ] || continue
  ns="$(jq -r '.ns' <<<"$line")"
  name="$(jq -r '.name' <<<"$line")"
  completed_at="$(jq -r '.ct' <<<"$line")"
  completed_epoch="$(date -d "$completed_at" +%s 2>/dev/null)" || continue
  age=$((now_epoch - completed_epoch))
  [ "$age" -ge "$MAX_AGE_SECONDS" ] || continue

  if [ "${INSPECTOR_DRY_RUN:-0}" = "1" ]; then
    emit_result "auto" "would-delete" "job $ns/$name" \
      "completed ${age}s ago (threshold ${MAX_AGE_SECONDS}s)"
  elif kc delete job -n "$ns" "$name" >/dev/null 2>&1; then
    emit_result "auto" "deleted" "job $ns/$name" \
      "completed ${age}s ago (threshold ${MAX_AGE_SECONDS}s)"
  else
    emit_result "alert" "flagged" "job $ns/$name" \
      "kubectl delete failed (completed ${age}s ago) — manual investigation needed"
  fi
done < <(jq -c '.items[] | select(.status.completionTime != null) | {ns: .metadata.namespace, name: .metadata.name, ct: .status.completionTime}' <<<"$jobs_json")
