#!/usr/bin/env bash
# checks/k3s-oom-killed-containers.sh
#
# Flags containers whose last termination was OOMKilled within the
# lookback window. Design spec's "只告警" table, same reasoning as
# "Docker 重啟風暴" — whether to raise the memory limit or cut the
# workload down is a human call, not hygiene the inspector should do
# itself. Added after the 2026-08-17 io_pressure_critical incident:
# jaeger and a trivy scan job were both OOMKilled and silently
# restarted (pod stayed Running, so k3s-evicted-pods.sh never saw
# them) — this check closes that gap.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# 24h: comfortably covers the twice-daily run cadence (09:00/21:00)
# even if one run is missed, without the report going stale silently.
LOOKBACK_SECONDS="${INSPECTOR_OOM_LOOKBACK_SECONDS:-86400}"
KUBECONFIG_FILE="${INSPECTOR_KUBECONFIG:-$INSPECTOR_STATE_DIR/kubeconfig}"

if [ ! -f "$KUBECONFIG_FILE" ]; then
  emit_result "alert" "flagged" "check:k3s-oom-killed-containers.sh" \
    "inspector kubeconfig missing at $KUBECONFIG_FILE — run k3s/setup-kubeconfig.sh once (see README)"
  exit 0
fi

pods_json="$(kubectl --kubeconfig "$KUBECONFIG_FILE" get pods -A -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:k3s-oom-killed-containers.sh" \
    "kubernetes API not reachable via inspector kubeconfig — check skipped"
  exit 0
}

now_epoch="$(date +%s)"

while read -r line; do
  [ -n "$line" ] || continue
  ns="$(jq -r '.ns' <<<"$line")"
  pod="$(jq -r '.pod' <<<"$line")"
  container="$(jq -r '.container' <<<"$line")"
  finished_at="$(jq -r '.finishedAt' <<<"$line")"
  restart_count="$(jq -r '.restartCount' <<<"$line")"

  finished_epoch="$(date -d "$finished_at" +%s 2>/dev/null)" || continue
  age=$((now_epoch - finished_epoch))
  [ "$age" -ge 0 ] && [ "$age" -le "$LOOKBACK_SECONDS" ] || continue

  emit_result "alert" "flagged" "pod $ns/$pod container $container" \
    "OOMKilled ${age}s ago (restartCount=${restart_count}) — container's memory limit was hit, review resources.limits.memory or the workload"
done < <(jq -c '
  .items[] | .metadata.namespace as $ns | .metadata.name as $pod |
  (.status.containerStatuses // [])[] |
  select(.lastState.terminated.reason? == "OOMKilled") |
  {ns: $ns, pod: $pod, container: .name, finishedAt: .lastState.terminated.finishedAt, restartCount: .restartCount}
' <<<"$pods_json")
