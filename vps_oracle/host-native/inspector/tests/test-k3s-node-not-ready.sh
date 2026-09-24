#!/usr/bin/env bash
# tests/test-k3s-node-not-ready.sh — hermetic kubectl stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
touch "$work_dir/fake-kubeconfig"

since="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"

cat > "$work_dir/nodes.json" <<EOF
{"items":[
 {"metadata":{"name":"server-node"},"status":{"conditions":[
   {"type":"MemoryPressure","status":"False"},
   {"type":"Ready","status":"True","reason":"KubeletReady","lastTransitionTime":"$since"}]}},
 {"metadata":{"name":"lab-node"},"status":{"conditions":[
   {"type":"Ready","status":"Unknown","reason":"NodeStatusUnknown","lastTransitionTime":"$since"}]}},
 {"metadata":{"name":"broken-node"},"status":{"conditions":[
   {"type":"Ready","status":"False","reason":"KubeletNotReady"}]}},
 {"metadata":{"name":"no-conditions-node"},"status":{}}
]}
EOF

cat > "$bin_dir/kubectl" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" get nodes -o json "*) cat "$work_dir/nodes.json" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/kubectl"

check="$SCRIPT_DIR/../checks/k3s-node-not-ready.sh"
env_common=(PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/fake-kubeconfig")

echo "== not-ready nodes are flagged with reason and duration =="
out="$(env "${env_common[@]}" "$check")"
assert_true "lab-node (Ready=Unknown) flagged with reason" \
  "$(grep -q '"target":"node lab-node"' <<<"$out" && grep -q 'NodeStatusUnknown' <<<"$out" && echo true || echo false)"
assert_true "lab-node detail says how long it has been not ready" \
  "$(grep '"target":"node lab-node"' <<<"$out" | grep -q 'for 2h' && echo true || echo false)"
assert_true "broken-node (Ready=False, no transition time) flagged without crashing" \
  "$(grep -q '"target":"node broken-node"' <<<"$out" && grep -q 'KubeletNotReady' <<<"$out" && echo true || echo false)"
assert_true "node without any Ready condition flagged as unknown" \
  "$(grep '"target":"node no-conditions-node"' <<<"$out" | grep -q 'unknown' && echo true || echo false)"
assert_true "Ready node is not flagged" \
  "$(grep -q 'server-node' <<<"$out" && echo false || echo true)"

echo "== alert tier only, never deletes =="
assert_true "every line is alert/flagged" \
  "$(grep -qE '"action":"(deleted|would-delete)"' <<<"$out" && echo false || echo true)"

echo "== dependency failures alert instead of skipping silently =="
out="$(PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/missing" "$check")"
assert_true "missing kubeconfig raises an alert" \
  "$(grep -q 'kubeconfig missing' <<<"$out" && echo true || echo false)"
printf '#!/usr/bin/env bash\nexit 1\n' > "$bin_dir/kubectl"
out="$(env "${env_common[@]}" "$check")"
assert_true "unreachable API raises an alert" \
  "$(grep -q 'not reachable' <<<"$out" && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
