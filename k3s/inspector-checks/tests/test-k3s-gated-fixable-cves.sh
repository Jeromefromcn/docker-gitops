#!/usr/bin/env bash
# tests/test-k3s-gated-fixable-cves.sh — hermetic kubectl stub; kubeconfig is
# a dummy file. Alert-only check: the assertions are about which ReplicaSets
# get flagged (gated app, running pods, fixable CRITICAL in their report) and
# that every unreachable path still speaks up.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../vps_oracle/host-native/inspector/tests/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
export STUB_DIR="$bin_dir"
touch "$work_dir/fake-kubeconfig"

cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" get clusterpolicy require-vuln-scan-clean "*)
    [ -n "${NO_POLICY:-}" ] && exit 1
    cat <<'JSON'
{"spec":{"rules":[{"name":"block-critical-fixable-cves","match":{"any":[{"resources":{"kinds":["Pod"],"selector":{"matchExpressions":[{"key":"app","operator":"In","values":["hello-backend","visits-service","vets-service"]}]}}}]}}]}}
JSON
    ;;
  *" get pods "*)
    cat <<'JSON'
{"items":[
 {"metadata":{"namespace":"lab-environment","name":"visits-service-aaa-1","labels":{"app":"visits-service"},"ownerReferences":[{"kind":"ReplicaSet","name":"visits-service-aaa"}]},"spec":{"nodeName":"vps-oracle2"}},
 {"metadata":{"namespace":"lab-environment","name":"vets-service-bbb-1","labels":{"app":"vets-service"},"ownerReferences":[{"kind":"ReplicaSet","name":"vets-service-bbb"}]},"spec":{"nodeName":"vps-oracle2"}},
 {"metadata":{"namespace":"pr-lanes","name":"hello-backend-ccc-1","labels":{"app":"hello-backend"},"ownerReferences":[{"kind":"ReplicaSet","name":"hello-backend-ccc"}]},"spec":{"nodeName":"instance-20260321-2043"}},
 {"metadata":{"namespace":"argocd","name":"argocd-server-ddd-1","labels":{"app":"argocd-server"},"ownerReferences":[{"kind":"ReplicaSet","name":"argocd-server-ddd"}]},"spec":{"nodeName":"instance-20260321-2043"}},
 {"metadata":{"namespace":"lab-environment","name":"bare","labels":{"app":"visits-service"}},"spec":{}}
]}
JSON
    ;;
  *" get vulnerabilityreports "*)
    cat <<'JSON'
{"items":[
 {"metadata":{"namespace":"lab-environment","labels":{"trivy-operator.resource.kind":"ReplicaSet","trivy-operator.resource.name":"visits-service-aaa"}},
  "report":{"artifact":{"repository":"jeromefromcn/petclinic-visits-service","digest":"sha256:111"},"vulnerabilities":[
   {"vulnerabilityID":"CVE-2026-0001","severity":"CRITICAL","fixedVersion":"1.2.3"},
   {"vulnerabilityID":"CVE-2026-0002","severity":"CRITICAL","fixedVersion":"4.5"},
   {"vulnerabilityID":"CVE-2026-0003","severity":"CRITICAL","fixedVersion":""},
   {"vulnerabilityID":"CVE-2026-0004","severity":"HIGH","fixedVersion":"9"}]}},
 {"metadata":{"namespace":"lab-environment","labels":{"trivy-operator.resource.kind":"ReplicaSet","trivy-operator.resource.name":"vets-service-bbb"}},
  "report":{"artifact":{"repository":"jeromefromcn/petclinic-vets-service"},"vulnerabilities":[
   {"vulnerabilityID":"CVE-2026-0005","severity":"CRITICAL","fixedVersion":""},
   {"vulnerabilityID":"CVE-2026-0006","severity":"HIGH","fixedVersion":"1"}]}},
 {"metadata":{"namespace":"pr-lanes","labels":{"trivy-operator.resource.kind":"ReplicaSet","trivy-operator.resource.name":"hello-backend-old"}},
  "report":{"artifact":{"repository":"jeromefromcn/hello-backend"},"vulnerabilities":[
   {"vulnerabilityID":"CVE-2026-0007","severity":"CRITICAL","fixedVersion":"2"}]}},
 {"metadata":{"namespace":"argocd","labels":{"trivy-operator.resource.kind":"ReplicaSet","trivy-operator.resource.name":"argocd-server-ddd"}},
  "report":{"artifact":{"repository":"argoproj/argocd"},"vulnerabilities":[
   {"vulnerabilityID":"CVE-2026-0008","severity":"CRITICAL","fixedVersion":"3"}]}},
 {"metadata":{"namespace":"lab-environment","labels":{}},"report":{}}
]}
JSON
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/kubectl"

check="$SCRIPT_DIR/../checks/k3s-gated-fixable-cves.sh"
env_common=(PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/fake-kubeconfig")

echo "== a gated, running ReplicaSet with fixable CRITICALs is flagged =="
out="$(env "${env_common[@]}" "$check")"
assert_true "flags visits-service-aaa with its namespace" \
  "$(grep -q '"target":"ReplicaSet lab-environment/visits-service-aaa"' <<<"$out" && echo true || echo false)"
assert_true "detail counts only CRITICAL with a fix (2), names them, the image and the node" \
  "$(grep -q '2 fixable CRITICAL' <<<"$out" && grep -q 'CVE-2026-0001' <<<"$out" && grep -q 'CVE-2026-0002' <<<"$out" \
     && grep -q 'petclinic-visits-service' <<<"$out" && grep -q 'vps-oracle2' <<<"$out" && echo true || echo false)"
assert_true "detail says what happens next" \
  "$(grep -q 'next pod' <<<"$out" && echo true || echo false)"

echo "== what should not match does not =="
assert_true "unfixable CRITICAL only (vets) not flagged" \
  "$(grep -q 'vets-service-bbb' <<<"$out" && echo false || echo true)"
assert_true "report of a ReplicaSet with no running pod (hello-backend-old) not flagged" \
  "$(grep -q 'hello-backend-old' <<<"$out" && echo false || echo true)"
assert_true "ungated app (argocd) not flagged" \
  "$(grep -q 'argocd' <<<"$out" && echo false || echo true)"
assert_true "exactly one result" \
  "$([ "$(grep -c '"tier"' <<<"$out")" = "1" ] && echo true || echo false)"

echo "== alert-only: never proposes or performs a deletion =="
assert_true "no deleted/would-delete action emitted" \
  "$(grep -qE '"action":"(deleted|would-delete)"' <<<"$out" && echo false || echo true)"
assert_true "the result is tier=alert, action=flagged" \
  "$(grep -q '"tier":"alert","action":"flagged"' <<<"$out" && echo true || echo false)"

echo "== missing kubeconfig: alert, not silence =="
out="$(env PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/nonexistent" "$check")"
assert_true "emits alert about missing kubeconfig" \
  "$(grep -q '"tier":"alert"' <<<"$out" && grep -q 'kubeconfig missing' <<<"$out" && echo true || echo false)"

echo "== policy unreadable: alert, not silence =="
out="$(env "${env_common[@]}" NO_POLICY=1 "$check")"
assert_true "emits alert about the unreadable policy" \
  "$(grep -q '"tier":"alert"' <<<"$out" && grep -q 'require-vuln-scan-clean' <<<"$out" && grep -q 'rbac.yaml' <<<"$out" && echo true || echo false)"

echo "== unreachable API: alert, not silence =="
cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$bin_dir/kubectl"
out="$(env "${env_common[@]}" "$check")"
assert_true "emits alert about unreachable API" \
  "$(grep -q '"tier":"alert"' <<<"$out" && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
