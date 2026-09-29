#!/usr/bin/env bash
# checks/k3s-gated-fixable-cves.sh
#
# Flags a running ReplicaSet whose Trivy VulnerabilityReport shows a CRITICAL
# vulnerability with a fix available, for the workloads Kyverno's
# require-vuln-scan-clean gates (its `app in (...)` list, read from the live
# policy so this check never drifts from it). Such a ReplicaSet runs fine
# today, but the policy refuses its next pod - an eviction, a scale-up, a
# demo deleting a pod - with FailedCreate. This says so before that happens.
# ALERT ONLY: the fix is a patched image release, which needs a human.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/kube.sh"

KUBECONFIG_FILE="${INSPECTOR_KUBECONFIG:-$INSPECTOR_STATE_DIR/kubeconfig}"
RBAC=vps_oracle/host-native/inspector/kubeconfig/rbac.yaml

if [ ! -f "$KUBECONFIG_FILE" ]; then
  emit_result "alert" "flagged" "check:k3s-gated-fixable-cves.sh" \
    "inspector kubeconfig missing at $KUBECONFIG_FILE — run vps_oracle/host-native/inspector/kubeconfig/setup-kubeconfig.sh once (see the inspector README)"
  exit 0
fi
kc() { kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"; }

policy="$(kc get clusterpolicy require-vuln-scan-clean -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:k3s-gated-fixable-cves.sh" \
    "cannot read ClusterPolicy require-vuln-scan-clean (API unreachable, policy gone, or Forbidden - see $RBAC) — check skipped"
  exit 0
}
apps="$(jq -c '[.spec.rules[] | select(.name == "block-critical-fixable-cves") | .match.any[]?.resources.selector.matchExpressions[]?
               | select(.key == "app" and .operator == "In") | .values[]] | unique' <<<"$policy")"

pods="$(kc get pods -A -o json 2>/dev/null)" && reports="$(kc get vulnerabilityreports -A -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:k3s-gated-fixable-cves.sh" \
    "cannot list pods or vulnerabilityreports via inspector kubeconfig (unreachable or Forbidden - see $RBAC) — check skipped"
  exit 0
}

# Running ReplicaSets of gated apps: "<ns>/<rs>" -> the node(s) their pods run on.
running="$(jq -c --argjson apps "$apps" '
  [.items[] | select((.metadata.labels.app // "") as $a | $apps | index($a))
            | select(.metadata.ownerReferences[0].kind? == "ReplicaSet")
            | {k: "\(.metadata.namespace)/\(.metadata.ownerReferences[0].name)", n: (.spec.nodeName // "unscheduled")}]
  | group_by(.k) | map({key: .[0].k, value: ([.[].n] | unique | join(","))}) | from_entries' <<<"$pods")"

while read -r line; do
  [ -n "$line" ] || continue
  emit_result "alert" "flagged" "ReplicaSet $(jq -r '.rs' <<<"$line")" \
    "$(jq -r '"\(.n) fixable CRITICAL in \(.image) (\(.ids)) on node \(.node) — require-vuln-scan-clean will refuse its next pod (FailedCreate); release a patched image"' <<<"$line")"
done < <(jq -c --argjson running "$running" '
  .items[]
  | select(.metadata.labels["trivy-operator.resource.kind"]? == "ReplicaSet")
  | {rs: "\(.metadata.namespace)/\(.metadata.labels["trivy-operator.resource.name"])",
     image: (.report.artifact.repository // "unknown image"),
     fixable: [.report.vulnerabilities[]? | select(.severity == "CRITICAL" and (.fixedVersion // "") != "") | .vulnerabilityID]}
  | select($running[.rs] != null and (.fixable | length) > 0)
  | {rs, image, n: (.fixable | length), ids: (.fixable | unique | .[:5] | join(", ")), node: $running[.rs]}' <<<"$reports")
