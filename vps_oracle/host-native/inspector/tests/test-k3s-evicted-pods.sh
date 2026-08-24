#!/usr/bin/env bash
# tests/test-k3s-evicted-pods.sh — hermetic kubectl stub; kubeconfig is
# a dummy file (the check only tests existence, the stub ignores it).
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
  *" get pods -A "*)
    cat <<'JSON'
{"items":[
 {"metadata":{"name":"web-abc","namespace":"workloads"},"status":{"reason":"Evicted"}},
 {"metadata":{"name":"bad-pod","namespace":"dify"},"status":{"reason":"Error"}}
]}
JSON
    ;;
  *" delete pod "*)
    echo "kubectl $*" >> "$STUB_DIR/calls.log"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/kubectl"

check="$SCRIPT_DIR/../checks/k3s-evicted-pods.sh"
env_common=(PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/fake-kubeconfig")

echo "== dry run: both failed pods proposed, nothing deleted =="
out="$(env "${env_common[@]}" INSPECTOR_DRY_RUN=1 "$check")"
assert_true "would-delete for workloads/web-abc (Evicted)" \
  "$(grep -q '"target":"pod workloads/web-abc"' <<<"$out" && grep -q 'Evicted' <<<"$out" && echo true || echo false)"
assert_true "would-delete for dify/bad-pod (Error)" \
  "$(grep -q '"target":"pod dify/bad-pod"' <<<"$out" && echo true || echo false)"
assert_true "dry run issued no kubectl delete" \
  "$([ ! -f "$bin_dir/calls.log" ] && echo true || echo false)"

echo "== real run: both deleted =="
out="$(env "${env_common[@]}" "$check")"
assert_true "deleted lines for both pods" \
  "$([ "$(grep -c '"action":"deleted"' <<<"$out")" = "2" ] && echo true || echo false)"
assert_true "kubectl delete called per pod with namespace" \
  "$(grep -q 'delete pod -n workloads web-abc' "$bin_dir/calls.log" && grep -q 'delete pod -n dify bad-pod' "$bin_dir/calls.log" && echo true || echo false)"

echo "== missing kubeconfig: alert, not silence =="
out="$(env PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/nonexistent" "$check")"
assert_true "emits alert about missing kubeconfig" \
  "$(grep -q '"tier":"alert"' <<<"$out" && grep -q 'kubeconfig missing' <<<"$out" && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
