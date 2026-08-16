#!/usr/bin/env bash
# tests/test-k3s-completed-jobs.sh — hermetic kubectl stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
export STUB_DIR="$bin_dir"
touch "$work_dir/fake-kubeconfig"

old_ct="$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)"
new_ct="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
cat > "$work_dir/jobs.json" <<EOF
{"items":[
 {"metadata":{"name":"job-old","namespace":"workloads"},"status":{"completionTime":"$old_ct"}},
 {"metadata":{"name":"job-fresh","namespace":"workloads"},"status":{"completionTime":"$new_ct"}},
 {"metadata":{"name":"job-running","namespace":"kyverno"},"status":{}}
]}
EOF

cat > "$bin_dir/kubectl" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" get jobs -A "*) cat "$work_dir/jobs.json" ;;
  *" delete job "*)
    echo "kubectl \$*" >> "\$STUB_DIR/calls.log"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/kubectl"

check="$SCRIPT_DIR/../checks/k3s-completed-jobs.sh"
env_common=(PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/fake-kubeconfig")

echo "== dry run: only the 10-day-old job is proposed =="
out="$(env "${env_common[@]}" INSPECTOR_DRY_RUN=1 "$check")"
assert_true "would-delete for workloads/job-old" \
  "$(grep -q '"target":"job workloads/job-old"' <<<"$out" && echo true || echo false)"
assert_true "1h-old completed job is not proposed" \
  "$(grep -q 'job-fresh' <<<"$out" && echo false || echo true)"
assert_true "incomplete job is not proposed" \
  "$(grep -q 'job-running' <<<"$out" && echo false || echo true)"
assert_true "dry run issued no kubectl delete" \
  "$([ ! -f "$bin_dir/calls.log" ] && echo true || echo false)"

echo "== real run: only job-old deleted =="
out="$(env "${env_common[@]}" "$check")"
assert_true "one deleted line" \
  "$([ "$(grep -c '"action":"deleted"' <<<"$out")" = "1" ] && echo true || echo false)"
assert_true "kubectl delete job called for job-old only" \
  "$(grep -q 'delete job -n workloads job-old' "$bin_dir/calls.log" && [ "$(grep -c 'delete job' "$bin_dir/calls.log")" = "1" ] && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
