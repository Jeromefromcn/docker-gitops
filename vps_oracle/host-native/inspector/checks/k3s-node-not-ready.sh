#!/usr/bin/env bash
# checks/k3s-node-not-ready.sh
#
# Flags any k3s Node whose Ready condition is not True. Added 2026-09-24 when
# vps-oracle2 joined as an agent node: with a single node, "node down" meant
# "apiserver down" and the ArgoCD/Headlamp blackbox probes caught it; an
# agent node can now go NotReady while everything on vps_oracle stays
# healthy, and nothing else notices. ALERT ONLY — a NotReady node needs a
# human (tailscale, k3s-agent, host), there is nothing safe to auto-clean.
#
# This is the 12h backstop; the minutes-level signal is the blackbox probe
# on oracle2's kubelet port in compose monitoring.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

KUBECONFIG_FILE="${INSPECTOR_KUBECONFIG:-$INSPECTOR_STATE_DIR/kubeconfig}"

if [ ! -f "$KUBECONFIG_FILE" ]; then
  emit_result "alert" "flagged" "check:k3s-node-not-ready.sh" \
    "inspector kubeconfig missing at $KUBECONFIG_FILE — run k3s/setup-kubeconfig.sh once (see README)"
  exit 0
fi

nodes_json="$(kubectl --kubeconfig "$KUBECONFIG_FILE" get nodes -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:k3s-node-not-ready.sh" \
    "kubernetes API not reachable via inspector kubeconfig — check skipped"
  exit 0
}

now_epoch="$(date +%s)"

while read -r line; do
  [ -n "$line" ] || continue
  name="$(jq -r '.name' <<<"$line")"
  status="$(jq -r '.status' <<<"$line")"
  reason="$(jq -r '.reason' <<<"$line")"
  since="$(jq -r '.since' <<<"$line")"

  duration=""
  if [ -n "$since" ] && since_epoch="$(date -d "$since" +%s 2>/dev/null)"; then
    duration=" for $(human_duration $((now_epoch - since_epoch)))"
  fi
  emit_result "alert" "flagged" "node $name" \
    "Ready=$status ($reason)$duration — check k3s/k3s-agent service and tailscale on that host"
done < <(jq -c '.items[]
  | {name: .metadata.name,
     ready: ([.status.conditions[]? | select(.type == "Ready")] | first)}
  | select(.ready == null or .ready.status != "True")
  | {name,
     status: (.ready.status // "unknown"),
     reason: (.ready.reason // "no Ready condition"),
     since: (.ready.lastTransitionTime // "")}' <<<"$nodes_json")
