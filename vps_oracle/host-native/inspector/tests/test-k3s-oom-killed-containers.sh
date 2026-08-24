#!/usr/bin/env bash
# tests/test-k3s-oom-killed-containers.sh — hermetic kubectl stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
touch "$work_dir/fake-kubeconfig"

recent="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
stale="$(date -u -d '-2 days' +%Y-%m-%dT%H:%M:%SZ)"

cat > "$work_dir/pods.json" <<EOF
{"items":[
 {"metadata":{"name":"jaeger-abc","namespace":"lab-environment"},
  "status":{"containerStatuses":[
    {"name":"jaeger","restartCount":1,
     "lastState":{"terminated":{"reason":"OOMKilled","finishedAt":"$recent"}}}
  ]}},
 {"metadata":{"name":"old-oom","namespace":"workloads"},
  "status":{"containerStatuses":[
    {"name":"app","restartCount":3,
     "lastState":{"terminated":{"reason":"OOMKilled","finishedAt":"$stale"}}}
  ]}},
 {"metadata":{"name":"clean-exit","namespace":"dify"},
  "status":{"containerStatuses":[
    {"name":"worker","restartCount":1,
     "lastState":{"terminated":{"reason":"Completed","finishedAt":"$recent"}}}
  ]}},
 {"metadata":{"name":"never-restarted","namespace":"dify"},
  "status":{"containerStatuses":[
    {"name":"web","restartCount":0}
  ]}}
]}
EOF

cat > "$bin_dir/kubectl" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" get pods -A -o json "*) cat "$work_dir/pods.json" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/kubectl"

check="$SCRIPT_DIR/../checks/k3s-oom-killed-containers.sh"
env_common=(PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/fake-kubeconfig")

echo "== recent OOMKilled within lookback: flagged =="
out="$(env "${env_common[@]}" "$check")"
assert_true "flags lab-environment/jaeger-abc container jaeger" \
  "$(grep -q '"target":"pod lab-environment/jaeger-abc container jaeger"' <<<"$out" && grep -q 'restartCount=1' <<<"$out" && echo true || echo false)"
assert_true "flagged as alert tier, not auto" \
  "$(grep -q '"tier":"alert"' <<<"$out" && echo true || echo false)"

echo "== OOMKilled outside lookback window: not flagged =="
assert_true "old-oom (2 days ago) is not flagged" \
  "$(grep -q 'old-oom' <<<"$out" && echo false || echo true)"

echo "== non-OOM termination reason: not flagged =="
assert_true "clean-exit (Completed) is not flagged" \
  "$(grep -q 'clean-exit' <<<"$out" && echo false || echo true)"

echo "== container with no lastState at all: not flagged =="
assert_true "never-restarted is not flagged" \
  "$(grep -q 'never-restarted' <<<"$out" && echo false || echo true)"

echo "== custom lookback window excludes the recent one too =="
out_narrow="$(env "${env_common[@]}" INSPECTOR_OOM_LOOKBACK_SECONDS=60 "$check")"
assert_true "60s lookback excludes the 1-hour-old OOM" \
  "$(grep -q 'jaeger-abc' <<<"$out_narrow" && echo false || echo true)"

echo "== missing kubeconfig: alert, not silence =="
out="$(env PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/nonexistent" "$check")"
assert_true "emits alert about missing kubeconfig" \
  "$(grep -q '"tier":"alert"' <<<"$out" && grep -q 'kubeconfig missing' <<<"$out" && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
