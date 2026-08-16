#!/usr/bin/env bash
# k3s/setup-kubeconfig.sh — one-time bootstrap for the inspector's k3s
# access. Applies rbac.yaml with the admin kubeconfig, waits for the SA
# token secret, and writes a least-privilege token kubeconfig to
# state/kubeconfig (gitignored). Safe to re-run: apply is idempotent and
# the existing token is reused, not rotated.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSPECTOR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$INSPECTOR_ROOT/state"
KUBECONFIG_FILE="$STATE_DIR/kubeconfig"
mkdir -p "$STATE_DIR"

kubectl apply -f "$SCRIPT_DIR/rbac.yaml"

echo "waiting for token secret to be populated..." >&2
token=""
for _ in $(seq 1 30); do
  token="$(kubectl -n workloads get secret docker-gitops-inspector-token \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)" && [ -n "$token" ] && break
  sleep 1
done
[ -n "$token" ] || { echo "ERROR: token secret never populated" >&2; exit 1; }

# Reuse the cluster CA from the admin config rather than
# insecure-skip-tls-verify.
ca_data="$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
[ -n "$ca_data" ] || { echo "ERROR: could not read cluster CA from admin kubeconfig" >&2; exit 1; }

umask 077
cat > "$KUBECONFIG_FILE" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: inspector
  cluster:
    server: https://127.0.0.1:6443
    certificate-authority-data: ${ca_data}
users:
- name: inspector
  user:
    token: ${token}
contexts:
- name: inspector
  context:
    cluster: inspector
    user: inspector
current-context: inspector
EOF
chmod 600 "$KUBECONFIG_FILE"

echo "verifying the kubeconfig works AND is not over-privileged..." >&2
kubectl --kubeconfig "$KUBECONFIG_FILE" get pods -A >/dev/null
kubectl --kubeconfig "$KUBECONFIG_FILE" get jobs -A >/dev/null
kubectl --kubeconfig "$KUBECONFIG_FILE" get pv >/dev/null
if kubectl --kubeconfig "$KUBECONFIG_FILE" -n workloads get secrets >/dev/null 2>&1; then
  echo "ERROR: kubeconfig can read secrets — RBAC is broader than intended" >&2
  exit 1
fi
echo "OK: wrote $KUBECONFIG_FILE (SA workloads/docker-gitops-inspector)" >&2
