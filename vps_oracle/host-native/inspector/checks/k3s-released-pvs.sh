#!/usr/bin/env bash
# checks/k3s-released-pvs.sh
#
# Flags PersistentVolumes in Released phase — unbound but still holding
# disk. Design spec's "k3s Released PV" row (ALERT ONLY — same
# asymmetric-misjudgment reasoning as docker volumes: a Released PV may
# still be the only copy of data someone wants).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

KUBECONFIG_FILE="${INSPECTOR_KUBECONFIG:-$INSPECTOR_STATE_DIR/kubeconfig}"

if [ ! -f "$KUBECONFIG_FILE" ]; then
  emit_result "alert" "flagged" "check:k3s-released-pvs.sh" \
    "inspector kubeconfig missing at $KUBECONFIG_FILE — run k3s/setup-kubeconfig.sh once (see README)"
  exit 0
fi

pv_json="$(kubectl --kubeconfig "$KUBECONFIG_FILE" get pv -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:k3s-released-pvs.sh" \
    "kubernetes API not reachable via inspector kubeconfig — check skipped"
  exit 0
}

while read -r line; do
  [ -n "$line" ] || continue
  name="$(jq -r '.name' <<<"$line")"
  cap="$(jq -r '.cap' <<<"$line")"
  claim="$(jq -r '.claim' <<<"$line")"
  emit_result "alert" "flagged" "PV $name" \
    "Released (was $claim, capacity $cap) — still holds storage, manual review needed"
done < <(jq -c '.items[] | select(.status.phase == "Released") | {name: .metadata.name, cap: (.spec.capacity.storage // "unknown"), claim: (.spec.claimRef.name // "unknown")}' <<<"$pv_json")
