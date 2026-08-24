#!/usr/bin/env bash
# checks/k3s-evicted-pods.sh
#
# Deletes leftover pods in Failed phase (Evicted/Error/etc.). Design
# spec's "k3s Evicted/Failed pod" row (auto tier — deleting terminal
# Failed pods is standard k8s hygiene; their controllers recreate
# anything that should exist). No age threshold: a Failed pod is
# already terminal.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

KUBECONFIG_FILE="${INSPECTOR_KUBECONFIG:-$INSPECTOR_STATE_DIR/kubeconfig}"

if [ ! -f "$KUBECONFIG_FILE" ]; then
  emit_result "alert" "flagged" "check:k3s-evicted-pods.sh" \
    "inspector kubeconfig missing at $KUBECONFIG_FILE — run k3s/setup-kubeconfig.sh once (see README)"
  exit 0
fi

kc() { kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"; }

pods_json="$(kc get pods -A --field-selector=status.phase=Failed -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:k3s-evicted-pods.sh" \
    "kubernetes API not reachable via inspector kubeconfig — check skipped"
  exit 0
}

[ "$(jq '.items | length' <<<"$pods_json")" -gt 0 ] || exit 0

while read -r line; do
  [ -n "$line" ] || continue
  ns="$(jq -r '.ns' <<<"$line")"
  name="$(jq -r '.name' <<<"$line")"
  reason="$(jq -r '.reason' <<<"$line")"

  if [ "${INSPECTOR_DRY_RUN:-0}" = "1" ]; then
    emit_result "auto" "would-delete" "pod $ns/$name" "phase=Failed reason=$reason"
  elif kc delete pod -n "$ns" "$name" >/dev/null 2>&1; then
    emit_result "auto" "deleted" "pod $ns/$name" "phase=Failed reason=$reason"
  else
    emit_result "alert" "flagged" "pod $ns/$name" \
      "kubectl delete failed (phase=Failed reason=$reason) — manual investigation needed"
  fi
done < <(jq -c '.items[] | {ns: .metadata.namespace, name: .metadata.name, reason: (.status.reason // "unknown")}' <<<"$pods_json")
