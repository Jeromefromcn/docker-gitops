#!/usr/bin/env bash
# tests/test-k3s-alerts.sh — covers k3s-released-pvs.sh and
# k3s-stuck-terminating.sh (structurally identical read-only checks).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
touch "$work_dir/fake-kubeconfig"

old_dt="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
new_dt="$(date -u -d '-1 minute' +%Y-%m-%dT%H:%M:%SZ)"

cat > "$work_dir/pv.json" <<EOF
{"items":[
 {"metadata":{"name":"pvc-stale"},"spec":{"capacity":{"storage":"5Gi"},"claimRef":{"name":"vikunja"}},"status":{"phase":"Released"}},
 {"metadata":{"name":"pvc-live"},"spec":{"capacity":{"storage":"1Gi"},"claimRef":{"name":"apprise"}},"status":{"phase":"Bound"}}
]}
EOF
cat > "$work_dir/pods.json" <<EOF
{"items":[
 {"metadata":{"name":"stuck-pod","namespace":"workloads","deletionTimestamp":"$old_dt"}},
 {"metadata":{"name":"fresh-delete","namespace":"dify","deletionTimestamp":"$new_dt"}},
 {"metadata":{"name":"normal-pod","namespace":"dify"}}
]}
EOF

cat > "$bin_dir/kubectl" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" get pv -o json "*) cat "$work_dir/pv.json" ;;
  *" get pods -A -o json "*) cat "$work_dir/pods.json" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/kubectl"

env_common=(PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/fake-kubeconfig")

echo "== released PVs: only the Released one is flagged =="
out="$(env "${env_common[@]}" "$SCRIPT_DIR/../checks/k3s-released-pvs.sh")"
assert_true "flags pvc-stale with claim and capacity" \
  "$(grep -q '"target":"PV pvc-stale"' <<<"$out" && grep -q 'vikunja' <<<"$out" && grep -q '5Gi' <<<"$out" && echo true || echo false)"
assert_true "Bound PV is not flagged" \
  "$(grep -q 'pvc-live' <<<"$out" && echo false || echo true)"

echo "== stuck terminating: only deletionTimestamp older than 900s is flagged =="
out="$(env "${env_common[@]}" "$SCRIPT_DIR/../checks/k3s-stuck-terminating.sh")"
assert_true "flags stuck-pod (deleting for ~1h)" \
  "$(grep -q '"target":"pod workloads/stuck-pod"' <<<"$out" && echo true || echo false)"
assert_true "1-minute-old deletion is under threshold, not flagged" \
  "$(grep -q 'fresh-delete' <<<"$out" && echo false || echo true)"
assert_true "pod without deletionTimestamp is not flagged" \
  "$(grep -q 'normal-pod' <<<"$out" && echo false || echo true)"

rm -rf "$work_dir"
finish_tests
