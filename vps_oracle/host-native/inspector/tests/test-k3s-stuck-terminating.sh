#!/usr/bin/env bash
# tests/test-k3s-stuck-terminating.sh — hermetic kubectl stub; kubeconfig
# is a dummy file (the check only tests existence, the stub ignores it).
# Timestamps are generated relative to now inside the stub so the fixture
# never goes stale. Alert-only check: nothing is ever deleted.
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
old="$(date -u -d '-30 minutes' +%Y-%m-%dT%H:%M:%SZ)"
recent="$(date -u -d '-1 minute' +%Y-%m-%dT%H:%M:%SZ)"
case " $* " in
  *" get pods -A "*)
    cat <<JSON
{"items":[
 {"metadata":{"name":"stuck-pod","namespace":"pr-lanes","deletionTimestamp":"$old"}},
 {"metadata":{"name":"just-deleted","namespace":"pr-lanes","deletionTimestamp":"$recent"}},
 {"metadata":{"name":"healthy-pod","namespace":"argocd"}},
 {"metadata":{"name":"bad-timestamp","namespace":"argocd","deletionTimestamp":"not-a-date"}}
]}
JSON
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/kubectl"

check="$SCRIPT_DIR/../checks/k3s-stuck-terminating.sh"
env_common=(PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/fake-kubeconfig")

echo "== default 900s threshold: only the long-terminating pod is flagged =="
out="$(env "${env_common[@]}" "$check" 2>/dev/null)"
assert_true "flags pr-lanes/stuck-pod" \
  "$(grep -q '"target":"pod pr-lanes/stuck-pod"' <<<"$out" && echo true || echo false)"
assert_true "detail names the threshold it crossed" \
  "$(grep -q 'threshold 900s' <<<"$out" && echo true || echo false)"
assert_true "pod terminating for only 60s not flagged" \
  "$(grep -q 'just-deleted' <<<"$out" && echo false || echo true)"
assert_true "pod without deletionTimestamp not flagged" \
  "$(grep -q 'healthy-pod' <<<"$out" && echo false || echo true)"
assert_true "exactly one result" \
  "$([ "$(grep -c '"tier":"alert"' <<<"$out")" = "1" ] && echo true || echo false)"

echo "== unparseable deletionTimestamp is skipped, not fatal =="
assert_true "bad-timestamp pod not flagged" \
  "$(grep -q 'bad-timestamp' <<<"$out" && echo false || echo true)"
assert_true "the other pod is still reported (loop did not abort)" \
  "$(grep -q 'stuck-pod' <<<"$out" && echo true || echo false)"

echo "== threshold is configurable =="
out="$(env "${env_common[@]}" INSPECTOR_TERMINATING_STUCK_SECONDS=3600 "$check" 2>/dev/null)"
assert_true "raising threshold to 3600s clears the 30-minute pod" \
  "$([ -z "$out" ] && echo true || echo false)"
out="$(env "${env_common[@]}" INSPECTOR_TERMINATING_STUCK_SECONDS=30 "$check" 2>/dev/null)"
assert_true "lowering threshold to 30s catches both terminating pods" \
  "$([ "$(grep -c '"tier":"alert"' <<<"$out")" = "2" ] && echo true || echo false)"

echo "== alert-only: never proposes or performs a deletion =="
assert_true "no deleted/would-delete action emitted" \
  "$(grep -qE '"action":"(deleted|would-delete)"' <<<"$out" && echo false || echo true)"

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
