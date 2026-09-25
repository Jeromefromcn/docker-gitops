#!/usr/bin/env bash
# tests/test-k3s-capacity-pressure.sh — hermetic kubectl stub; kubeconfig
# is a dummy file (the check only tests existence, the stub ignores it).
# Alert-only check: nothing is ever deleted, so there is no dry-run branch
# to exercise — the assertions are about which states get flagged, that
# both threshold boundaries behave, and that every degraded path (missing
# kubeconfig, unreachable API, absent fields) speaks up instead of
# falling silent.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
export STUB_DIR="$bin_dir"
touch "$work_dir/fake-kubeconfig"

check="$SCRIPT_DIR/../checks/k3s-capacity-pressure.sh"
env_common=(PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/fake-kubeconfig")

# Ages are computed inside the stub, never hardcoded.
write_main_stub() {
cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
old="$(date -u -d '-30 minutes' +%Y-%m-%dT%H:%M:%SZ)"
fresh="$(date -u -d '-1 minute' +%Y-%m-%dT%H:%M:%SZ)"
case " $* " in
  *" get resourcequota "*)
    cat <<JSON
{"items":[
 {"metadata":{"name":"lab-environment-quota","namespace":"lab-environment"},
  "status":{"hard":{"requests.cpu":"2","requests.memory":"8Gi"},
            "used":{"requests.cpu":"1900m","requests.memory":"7800Mi"}}},
 {"metadata":{"name":"roomy-quota","namespace":"lab-environment"},
  "status":{"hard":{"requests.memory":"1Gi"},"used":{"requests.memory":"100Mi"}}}
]}
JSON
    ;;
  *" get replicasets "*)
    cat <<JSON
{"items":[
 {"metadata":{"name":"customers-service-abc","namespace":"lab-environment","creationTimestamp":"$old"},
  "status":{"conditions":[{"type":"ReplicaFailure","status":"True","reason":"FailedCreate",
    "message":"pods \"customers-service-abc-x\" is forbidden: exceeded quota: lab-environment-quota"}]}},
 {"metadata":{"name":"customers-service-def","namespace":"lab-environment","creationTimestamp":"$old"},
  "status":{"conditions":[{"type":"Progressing","status":"True","reason":"NewReplicaSetAvailable"}]}}
]}
JSON
    ;;
  *" get pods "*)
    cat <<JSON
{"items":[
 {"metadata":{"name":"stuck-pending","namespace":"lab-environment","creationTimestamp":"$old"},"status":{"phase":"Pending"}},
 {"metadata":{"name":"just-created","namespace":"lab-environment","creationTimestamp":"$fresh"},"status":{"phase":"Pending"}},
 {"metadata":{"name":"serving","namespace":"lab-environment","creationTimestamp":"$old"},"status":{"phase":"Running"}}
]}
JSON
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/kubectl"
}

write_main_stub

echo "== quota near its hard limit is flagged, a roomy one is not =="
out="$(env "${env_common[@]}" "$check")"
assert_true "flags the cpu dimension of lab-environment-quota" \
  "$(grep -q '"target":"quota lab-environment/lab-environment-quota"' <<<"$out" && grep -q 'requests.cpu 95%' <<<"$out" && echo true || echo false)"
assert_true "flags the memory dimension too (8Gi hard, 7800Mi used)" \
  "$(grep -q 'requests.memory 95%' <<<"$out" && echo true || echo false)"
assert_true "roomy-quota (10%) not flagged" \
  "$(grep -q 'roomy-quota' <<<"$out" && echo false || echo true)"

echo "== an admission-rejected ReplicaSet is flagged, a progressing one is not =="
assert_true "flags the FailedCreate ReplicaSet and quotes the quota it hit" \
  "$(grep -q '"target":"replicaset lab-environment/customers-service-abc"' <<<"$out" && grep -q 'exceeded quota: lab-environment-quota' <<<"$out" && echo true || echo false)"
assert_true "healthy ReplicaSet not flagged" \
  "$(grep -q 'customers-service-def' <<<"$out" && echo false || echo true)"

echo "== only pods Pending past the age threshold are flagged =="
assert_true "flags the 30-minute Pending pod" \
  "$(grep -q '"target":"pod lab-environment/stuck-pending"' <<<"$out" && echo true || echo false)"
assert_true "1-minute Pending pod not flagged (still normal scheduling)" \
  "$(grep -q 'just-created' <<<"$out" && echo false || echo true)"
assert_true "Running pod not flagged" \
  "$(grep -q 'serving' <<<"$out" && echo false || echo true)"

echo "== alert-only: never proposes or performs a deletion =="
assert_true "no deleted/would-delete action emitted" \
  "$(grep -qE '"action":"(deleted|would-delete)"' <<<"$out" && echo false || echo true)"
assert_true "every result is alert tier and action=flagged" \
  "$([ "$(grep -c '"tier":"alert"' <<<"$out")" = "$(grep -c '"action":"flagged"' <<<"$out")" ] && [ "$(grep -c '"tier":"alert"' <<<"$out")" -gt 0 ] && echo true || echo false)"

echo "== both sides of the quota threshold =="
for spec in "7373Mi:above" "7372Mi:below"; do
  used="${spec%%:*}"; label="${spec##*:}"
  cat > "$bin_dir/kubectl" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" get resourcequota "*)
    echo '{"items":[{"metadata":{"name":"boundary","namespace":"lab-environment"},"status":{"hard":{"requests.memory":"8Gi"},"used":{"requests.memory":"$used"}}}]}'
    ;;
  *" get replicasets "*|*" get pods "*) echo '{"items":[]}' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$bin_dir/kubectl"
  out="$(env "${env_common[@]}" "$check")"
  if [ "$label" = "above" ]; then
    assert_true "8Gi hard / 7373Mi used (90.0%) is flagged" \
      "$(grep -q '"target":"quota lab-environment/boundary"' <<<"$out" && echo true || echo false)"
  else
    assert_true "8Gi hard / 7372Mi used (89.99%) is not flagged" \
      "$(grep -q 'boundary' <<<"$out" && echo false || echo true)"
  fi
done

echo "== missing fields degrade, they do not crash =="
cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" get resourcequota "*)
    echo '{"items":[{"metadata":{"name":"no-status","namespace":"lab-environment"}}]}' ;;
  *" get replicasets "*)
    echo '{"items":[{"metadata":{"name":"no-conditions","namespace":"lab-environment"},"status":{}}]}' ;;
  *" get pods "*)
    echo '{"items":[{"metadata":{"name":"no-phase","namespace":"lab-environment"}}]}' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/kubectl"
out="$(env "${env_common[@]}" "$check")"
assert_true "no crash and no bogus result on absent status/phase/conditions" \
  "$([ -z "$out" ] && echo true || echo false)"

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

echo "== Forbidden is reported as an RBAC gap, not as an unreachable cluster =="
# This is the real failure mode that was hit when the check was first run:
# the inspector's ClusterRole did not grant resourcequotas/replicasets, and
# the check blamed the network. The two must not share a sentence.
cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
echo 'Error from server (Forbidden): resourcequotas is forbidden: User "system:serviceaccount:inspector:docker-gitops-inspector" cannot list resource "resourcequotas" in API group "" in the namespace "lab-environment"' >&2
exit 1
EOF
chmod +x "$bin_dir/kubectl"
out="$(env "${env_common[@]}" "$check")"
assert_true "names the RBAC gap and points at k3s/rbac.yaml" \
  "$(grep -q 'inspector RBAC does not permit' <<<"$out" && grep -q 'k3s/rbac.yaml' <<<"$out" && echo true || echo false)"
assert_true "does NOT claim the cluster is unreachable" \
  "$(grep -q 'not reachable' <<<"$out" && echo false || echo true)"

rm -rf "$work_dir"
finish_tests
