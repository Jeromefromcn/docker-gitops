#!/usr/bin/env bash
# checks/k3s-stuck-terminating.sh
#
# Flags pods stuck in Terminating (deletionTimestamp set longer than
# INSPECTOR_TERMINATING_STUCK_SECONDS ago). Design spec's "k3s 卡住的
# Terminating pod" row (ALERT ONLY — usually a finalizer/node problem;
# force-deleting is a human decision).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

THRESHOLD_SECONDS="${INSPECTOR_TERMINATING_STUCK_SECONDS:-900}"
KUBECONFIG_FILE="${INSPECTOR_KUBECONFIG:-$INSPECTOR_STATE_DIR/kubeconfig}"

if [ ! -f "$KUBECONFIG_FILE" ]; then
  emit_result "alert" "flagged" "check:k3s-stuck-terminating.sh" \
    "inspector kubeconfig missing at $KUBECONFIG_FILE — run k3s/setup-kubeconfig.sh once (see README)"
  exit 0
fi

pods_json="$(kubectl --kubeconfig "$KUBECONFIG_FILE" get pods -A -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:k3s-stuck-terminating.sh" \
    "kubernetes API not reachable via inspector kubeconfig — check skipped"
  exit 0
}

now_epoch="$(date +%s)"

while read -r line; do
  [ -n "$line" ] || continue
  ns="$(jq -r '.ns' <<<"$line")"
  name="$(jq -r '.name' <<<"$line")"
  dt="$(jq -r '.dt' <<<"$line")"
  dt_epoch="$(date -d "$dt" +%s 2>/dev/null)" || continue
  age=$((now_epoch - dt_epoch))
  [ "$age" -ge "$THRESHOLD_SECONDS" ] || continue
  emit_result "alert" "flagged" "pod $ns/$name" \
    "Terminating for ${age}s (threshold ${THRESHOLD_SECONDS}s) — likely stuck finalizer, manual review needed"
done < <(jq -c '.items[] | select(.metadata.deletionTimestamp != null) | {ns: .metadata.namespace, name: .metadata.name, dt: .metadata.deletionTimestamp}' <<<"$pods_json")
