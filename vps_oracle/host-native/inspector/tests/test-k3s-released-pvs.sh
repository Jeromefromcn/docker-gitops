#!/usr/bin/env bash
# tests/test-k3s-released-pvs.sh — hermetic kubectl stub; kubeconfig is
# a dummy file (the check only tests existence, the stub ignores it).
# Alert-only check: nothing is ever deleted, so there is no dry-run
# branch to exercise — the assertions are about which phases get
# flagged and that both unreachable paths still speak up.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
export STUB_DIR="$bin_dir"
touch "$work_dir/fake-kubeconfig"

cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" get pv "*)
    cat <<'JSON'
{"items":[
 {"metadata":{"name":"pvc-released-1"},"spec":{"capacity":{"storage":"8Gi"},"claimRef":{"name":"trilium-data"}},"status":{"phase":"Released"}},
 {"metadata":{"name":"pvc-bound-1"},"spec":{"capacity":{"storage":"20Gi"},"claimRef":{"name":"vikunja-data"}},"status":{"phase":"Bound"}},
 {"metadata":{"name":"pvc-available-1"},"spec":{"capacity":{"storage":"1Gi"}},"status":{"phase":"Available"}},
 {"metadata":{"name":"pvc-released-nocap"},"spec":{},"status":{"phase":"Released"}}
]}
JSON
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/kubectl"

check="$SCRIPT_DIR/../checks/k3s-released-pvs.sh"
env_common=(PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/fake-kubeconfig")

echo "== only Released PVs are flagged =="
out="$(env "${env_common[@]}" "$check")"
assert_true "flags pvc-released-1 with capacity and former claim" \
  "$(grep -q '"target":"PV pvc-released-1"' <<<"$out" && grep -q 'was trilium-data, capacity 8Gi' <<<"$out" && echo true || echo false)"
assert_true "Bound PV not flagged" \
  "$(grep -q 'pvc-bound-1' <<<"$out" && echo false || echo true)"
assert_true "Available PV not flagged" \
  "$(grep -q 'pvc-available-1' <<<"$out" && echo false || echo true)"
assert_true "exactly two results, both alert tier" \
  "$([ "$(grep -c '"tier":"alert"' <<<"$out")" = "2" ] && echo true || echo false)"

echo "== alert-only: never proposes or performs a deletion =="
assert_true "no deleted/would-delete action emitted" \
  "$(grep -qE '"action":"(deleted|would-delete)"' <<<"$out" && echo false || echo true)"
assert_true "every result is action=flagged" \
  "$([ "$(grep -c '"action":"flagged"' <<<"$out")" = "2" ] && echo true || echo false)"

echo "== missing fields degrade to 'unknown', not to a crash =="
assert_true "PV without capacity/claimRef still flagged as unknown" \
  "$(grep -q '"target":"PV pvc-released-nocap"' <<<"$out" && grep -q 'was unknown, capacity unknown' <<<"$out" && echo true || echo false)"

echo "== missing kubeconfig: alert, not silence =="
out="$(env PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/nonexistent" "$check")"
assert_true "emits alert about missing kubeconfig" \
  "$(grep -q '"tier":"alert"' <<<"$out" && grep -q 'kubeconfig missing' <<<"$out" && echo true || echo false)"

echo "== unreachable API: alert, not silence =="
cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$bin_dir/kubectl"
out="$(env "${env_common[@]}" "$check")"
assert_true "emits alert about unreachable API" \
  "$(grep -q '"tier":"alert"' <<<"$out" && grep -q 'not reachable' <<<"$out" && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
