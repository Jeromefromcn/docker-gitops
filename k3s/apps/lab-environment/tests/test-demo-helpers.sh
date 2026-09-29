#!/bin/bash
# Behaviour tests for the demo helpers against stubbed curl/kubectl/argocd.
# No cluster access: every external call goes to a stub in $WORK/bin.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DEMO=$HERE/../demo
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export DEMO_STATE_DIR=$WORK/state DEMO_SCENARIO_DIR=$WORK/scenarios DEMO_RESET_TIMEOUT=0
export FAKE_LOG=$WORK/calls.log FAKE_DEPLOYS=$WORK/deploys
mkdir -p "$WORK/bin" "$DEMO_SCENARIO_DIR"
export PATH=$WORK/bin:$PATH

cat > "$WORK/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$FAKE_LOG"
if [ -n "${FAKE_CURL_HOOK:-}" ] && out=$("$FAKE_CURL_HOOK" "$*"); then printf '%s\n' "$out"; exit 0; fi
case "$*" in
  *FAILME*) exit 22 ;;
  *"/v1/kv/chaos/"*) [ -z "${FAKE_CONSUL_DOWN:-}" ] || exit 7 ;;&
  *"/v1/kv/chaos/"*)
    if [ -n "${FAKE_CHAOS_ON:-}" ]; then v=${FAKE_CHAOS_VALUE:-dHJ1ZQ==}; else v=ZmFsc2U=; fi
    echo "[{\"Key\":\"${FAKE_CHAOS_ON:-chaos/visits-service/redis-timeout}\",\"Value\":\"$v\"}]" ;;
  *"/loki/api/v1/query"*)
    if [ -n "${FAKE_LOKI_EMPTY:-}" ]; then echo '{"data":{"result":[]}}'; else echo '{"data":{"result":[{"metric":{},"value":[0,"7"]}]}}'; fi ;;
  *) echo '{"data":{"result":[]}}' ;;
esac
EOF
cat > "$WORK/bin/kubectl" <<'EOF'
#!/bin/bash
echo "kubectl $*" >> "$FAKE_LOG"
if [ -n "${FAKE_KUBECTL_HOOK:-}" ] && out=$("$FAKE_KUBECTL_HOOK" "$*"); then printf '%s\n' "$out"; exit 0; fi
case "$*" in
  *"get deploy customers-service-canary"*"spec.replicas"*) echo "${FAKE_CANARY_REPLICAS:-0}" ;;
  *"get deploy customers-service-canary"*"image"*) echo "${FAKE_CANARY_IMAGE:-$(grep -m1 -oP 'image: \K\S+' "$FAKE_LAB_K8S/customers-service-canary.yaml")}" ;;
  *"get pods -l app=customers-service,track=canary -o name"*) printf '%s' "${FAKE_CANARY_PODS:-}" ;;
  *"get virtualservice customers-service -o json"*) cat "${FAKE_VS:-$FAKE_VS_PINNED}" ;;
  *"get trafficextension vets-service-ratelimit"*) [ -n "${FAKE_NO_RATELIMIT:-}" ] || echo "trafficextension.extensions.istio.io/vets-service-ratelimit" ;;
  *"get deploy visits-service -o jsonpath"*"env"*) echo "${FAKE_VISITS_ENV:-TZ SPRING_CLOUD_CONSUL_HOST SPRING_CLOUD_CONSUL_PORT DATA_DB_PASSWORD}" ;;
  *"get authorizationpolicy postgres-clients redis-clients"*) echo "{\"items\":[{\"spec\":{\"rules\":[{\"from\":[{\"source\":{\"principals\":[\"cluster.local/ns/lab-environment/sa/visits-service\"${FAKE_TOXI_PRINCIPAL:+,\"cluster.local/ns/lab-environment/sa/toxiproxy\"}]}}]}]}}]}" ;;
  *" get deploy "*) d=$(sed -E 's/.* get deploy ([^ ]+).*/\1/' <<< "$*"); grep "^$d " "$FAKE_DEPLOYS" | cut -d' ' -f2- ;;
  *"logs statefulset/argocd-application-controller"*) printf '%s\n' "${FAKE_CTRL_LOG:-}" ;;
  *"logs deploy/traffic-generator"*) for i in 1 2 3; do echo "2026-09-27T00:00:0${i}+00:00 ${FAKE_GEN_CODE:-200} /api/vet/vets"; done ;;
esac
EOF
cat > "$WORK/bin/argocd" <<'EOF'
#!/bin/bash
if [ -n "${FAKE_ARGOCD_HOOK:-}" ] && out=$("$FAKE_ARGOCD_HOOK" "$*"); then printf '%s\n' "$out"; exit 0; fi
echo "{\"status\":{\"sync\":{\"status\":\"${FAKE_SYNC:-Synced}\"},\"health\":{\"status\":\"Healthy\"},\"history\":${FAKE_HISTORY:-[]}}}"
EOF
chmod +x "$WORK/bin/"*

export FAKE_LAB_K8S=$HERE/../k8s
export FAKE_VS_PINNED=$WORK/vs-pinned.json
cat > "$FAKE_VS_PINNED" <<'EOF'
{"spec":{"http":[
 {"match":[{"method":{"exact":"GET"}}],"route":[{"destination":{"host":"customers-service.lab-environment.svc.cluster.local","subset":"stable"}}]},
 {"route":[{"destination":{"host":"customers-service.lab-environment.svc.cluster.local","subset":"stable"}}]}]}}
EOF
jq '.spec.http[1].route = [{"destination":{"subset":"stable"},"weight":90},{"destination":{"subset":"canary"},"weight":10}]' "$FAKE_VS_PINNED" > "$WORK/vs-weights.json"
jq '.spec.http[0].mirror = {"subset":"canary"}' "$FAKE_VS_PINNED" > "$WORK/vs-mirror.json"
jq '.spec.http = [{"match":[{"headers":{"x-canary":{"exact":"true"}}}],"route":[{"destination":{"subset":"canary"}}]}] + .spec.http' "$FAKE_VS_PINNED" > "$WORK/vs-header.json"
jq '.spec.http[0].route[0].destination.subset = "canary"' "$FAKE_VS_PINNED" > "$WORK/vs-switched.json"
jq 'del(.spec.http[0].route[0].destination.subset)' "$FAKE_VS_PINNED" > "$WORK/vs-unpinned.json"
jq '.spec.http = [{"match":[{"headers":{"x-fault":{"exact":"abort"}}}],"fault":{"abort":{"httpStatus":503}},"route":[{"destination":{"subset":"stable"}}]}] + .spec.http' "$FAKE_VS_PINNED" > "$WORK/vs-fault.json"

# Fixture: every business Deployment ready at the replica count git declares.
: > "$FAKE_DEPLOYS"
for d in api-gateway customers-service vets-service visits-service; do
  r=$(grep -m1 -E '^\s+replicas:' "$HERE/../k8s/$d.yaml" | awk '{print $2}')
  echo "$d $r $r" >> "$FAKE_DEPLOYS"
done

cp "$DEMO/scenarios/preflight.sh" "$DEMO_SCENARIO_DIR/"   # created in Step 4; the reset tests use it
cat > "$DEMO_SCENARIO_DIR/t1.sh" <<'EOF'
evidence_t1() {
  n=$(loki_count '{service="x"}' "$WINDOW_START" "$WINDOW_END")
  record envoy ok "loki said $n"
  record argocd ok "second infra piece"
}
reset_t1() { touch "$STATE_DIR/reset-called"; }
EOF
cat > "$DEMO_SCENARIO_DIR/one.sh" <<'EOF'
evidence_one() { record envoy ok "only piece"; }
EOF
cat > "$DEMO_SCENARIO_DIR/apponly.sh" <<'EOF'
evidence_apponly() { record app ok "a"; record postgres ok "b"; }
EOF
cat > "$DEMO_SCENARIO_DIR/withfail.sh" <<'EOF'
evidence_withfail() { record envoy ok "a"; record argocd ok "b"; rec_if app "c" [ 1 -eq 2 ]; }
EOF
cat > "$DEMO_SCENARIO_DIR/borrow.sh" <<'EOF'
WINDOW_FROM=t1
evidence_borrow() { record envoy ok "start $WINDOW_START"; record kubernetes ok "end $WINDOW_END"; }
EOF
cat > "$DEMO_SCENARIO_DIR/settled.sh" <<'EOF'
evidence_settled() { settle; record envoy ok "at $SETTLED_AT range $SETTLED_RANGE"; record argocd ok "b"; }
EOF
cat > "$DEMO_SCENARIO_DIR/qfail.sh" <<'EOF'
evidence_qfail() { record envoy ok "a"; v=$(prom 'FAILME'); record argocd ok "never $v"; }
EOF

fails=0
check() { # check <name> <expected-exit> <cmd...>
  local name=$1 want=$2 got=0; shift 2
  "$@" > "$WORK/out" 2>&1 || got=$?
  if [ "$got" = "$want" ]; then echo "PASS $name"; else echo "FAIL $name (exit $got, want $want)"; sed 's/^/    /' "$WORK/out"; fails=$((fails+1)); fi
}
has() { grep -qF -- "$2" "$1" || { echo "FAIL expected '$2' in $1"; fails=$((fails+1)); }; }

# --- demo-window ---------------------------------------------------------
check "unknown scenario" 2 "$DEMO/demo-window" start nosuch
has "$WORK/out" "unknown scenario"
check "stop without start" 2 "$DEMO/demo-window" stop one
DEMO_NOW=1000 check "start" 0 "$DEMO/demo-window" start t1
check "evidence refuses open window" 2 "$DEMO/demo-evidence" t1
DEMO_NOW=1300 check "stop" 0 "$DEMO/demo-window" stop t1
has "$DEMO_STATE_DIR/t1.window" "WINDOW_START=1000"
has "$DEMO_STATE_DIR/t1.window" "WINDOW_END=1300"
DEMO_NOW=1400 check "restart" 0 "$DEMO/demo-window" start one
DEMO_NOW=1500 "$DEMO/demo-window" stop one >/dev/null
DEMO_NOW=2000 "$DEMO/demo-window" start one >/dev/null
if grep -q WINDOW_END "$DEMO_STATE_DIR/one.window"; then echo "FAIL restart clears end"; fails=$((fails+1)); else echo "PASS restart clears end"; fi
DEMO_NOW=2100 "$DEMO/demo-window" stop one >/dev/null

# --- demo-evidence -------------------------------------------------------
: > "$FAKE_LOG"
check "two infra pieces pass" 0 "$DEMO/demo-evidence" t1
has "$WORK/out" "== OK"
has "$FAKE_LOG" "[300s]"
has "$FAKE_LOG" "time=1300000000000"
check "one piece is insufficient" 1 "$DEMO/demo-evidence" one
for s in apponly withfail; do
  DEMO_NOW=1 "$DEMO/demo-window" start $s >/dev/null; DEMO_NOW=2 "$DEMO/demo-window" stop $s >/dev/null
done
check "app-only evidence is insufficient" 1 "$DEMO/demo-evidence" apponly
check "a failed piece fails the run" 1 "$DEMO/demo-evidence" withfail
check "WINDOW_FROM borrows a window" 0 "$DEMO/demo-evidence" borrow
has "$WORK/out" "start 1000"
DEMO_NOW=1 "$DEMO/demo-window" start qfail >/dev/null; DEMO_NOW=2 "$DEMO/demo-window" stop qfail >/dev/null
check "query failure aborts" 1 "$DEMO/demo-evidence" qfail
has "$WORK/out" "aborted"
if grep -q "== OK" "$WORK/out"; then echo "FAIL query failure printed OK"; fails=$((fails+1)); fi
# settle: short windows are read 20 s past their end, over >= 60 s.
DEMO_NOW=100 "$DEMO/demo-window" start settled >/dev/null; DEMO_NOW=110 "$DEMO/demo-window" stop settled >/dev/null
check "settle widens a short window" 0 "$DEMO/demo-evidence" settled
has "$WORK/out" "at 130 range 60"
DEMO_NOW=100 "$DEMO/demo-window" start settled >/dev/null; DEMO_NOW=300 "$DEMO/demo-window" stop settled >/dev/null
check "settle keeps a long window" 0 "$DEMO/demo-evidence" settled
has "$WORK/out" "at 320 range 220"
DEMO_SAVE_DIR=$WORK/saved; mkdir -p "$DEMO_SAVE_DIR"
DEMO_SAVE_DIR=$DEMO_SAVE_DIR check "save copies output" 0 "$DEMO/demo-evidence" t1
has "$DEMO_SAVE_DIR/t1.txt" "== OK"

# --- demo-reset ----------------------------------------------------------
check "reset at baseline" 0 "$DEMO/demo-reset" t1
[ -f "$DEMO_STATE_DIR/reset-called" ] && echo "PASS reset hook ran" || { echo "FAIL reset hook ran"; fails=$((fails+1)); }
FAKE_CHAOS_ON=chaos/customers-service/slow-query-enabled check "reset fails on any chaos key" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "chaos/customers-service/slow-query-enabled"
FAKE_CHAOS_ON=chaos/customers-service/fail-instance FAKE_CHAOS_VALUE=$(printf customers-service-abc | base64) \
  check "reset fails while fail-instance names a pod" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "chaos/customers-service/fail-instance"
sed -i 's/^customers-service .*/customers-service 4 5/' "$FAKE_DEPLOYS"
check "reset fails on replica mismatch" 1 "$DEMO/demo-reset" preflight
sed -i 's/^customers-service .*/customers-service 5 5/' "$FAKE_DEPLOYS"
FAKE_GEN_CODE=503 check "reset fails on generator errors" 1 "$DEMO/demo-reset" preflight
FAKE_SYNC=OutOfSync check "reset fails when ArgoCD is not synced" 1 "$DEMO/demo-reset" preflight
FAKE_CONSUL_DOWN=1 check "reset fails when Consul is unreachable" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "Consul unreachable"

# --- routing baseline (2b) ------------------------------------------------
for v in weights mirror header switched unpinned; do
  FAKE_VS=$WORK/vs-$v.json check "reset fails on a VirtualService left $v" 1 "$DEMO/demo-reset" preflight
  has "$WORK/out" "off the stable pin"
done
FAKE_CANARY_REPLICAS=1 check "reset fails while the canary is scaled up" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "customers-service-canary spec.replicas '1'"
FAKE_CANARY_PODS='pod/customers-service-canary-abc' check "reset waits for terminating canary pods" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "canary pods still present"
FAKE_CANARY_IMAGE=ops-lab/customers-service:badbadbadbad check "reset fails on a canary image off git" 1 "$DEMO/demo-reset" preflight
check "reset passes at the routing baseline" 0 "$DEMO/demo-reset" preflight

# --- routing primitives (in a subshell: lib.sh sets -e and its own state) --
prims=$( (
  . "$DEMO/lib.sh"
  got=$(printf '%s\n' '7 inbound-vip|8081|http/canary|customers-service.lab-environment.svc.cluster.local;' \
                      '30 inbound-vip|8081|http/stable|customers-service.lab-environment.svc.cluster.local;' \
                      '5 inbound-vip|8081|http/stable|customers-service.lab-environment.svc.cluster.local;' \
                      '2 inbound-vip|8081|http|customers-service.lab-environment.svc.cluster.local;' | by_subset | sort -k2)
  [ "$got" = "$(printf '7 canary\n2 none\n35 stable')" ] && echo "PASS by_subset" || echo "FAIL by_subset: $got"
  { [ "$(printf '7 canary\n35 stable\n' | count_of stable)" = 35 ] && [ "$(printf '7 canary\n' | count_of stable)" = 0 ]; } \
    && echo "PASS count_of" || echo "FAIL count_of"
  { [ "$(pct 1 6)" = 16 ] && [ "$(pct 3 0)" = 0 ]; } && echo "PASS pct" || echo "FAIL pct"
  { in_band 8 8 30 && in_band 30 8 30 && ! in_band 7 8 30 && ! in_band 31 8 30; } && echo "PASS in_band edges" || echo "FAIL in_band"
) 2>&1 ) || true
echo "$prims"
fails=$((fails + $(echo "$prims" | grep -c '^FAIL' || true)))
echo "$prims" | grep -q '^PASS in_band' || { echo "FAIL routing primitives did not all run"; fails=$((fails+1)); }

# --- demo patches still apply to the tree ---------------------------------
shopt -s nullglob
# drift_check <root>: every demo patch applies to <root>'s lab manifests. Works
# on a copy, where any patch already applied (a live demo in progress) is
# reversed first. GIT_CEILING_DIRECTORIES keeps git apply from treating an
# enclosing repository as the root for the copy's paths.
# unapply_demos <dir>: reverse, in <dir>, every demo patch that is applied there.
unapply_demos() {
  local p
  for p in "$DEMO"/patches/*.patch; do
    if (cd "$1" && GIT_CEILING_DIRECTORIES="$1" git apply --check -R "$p" 2>/dev/null && GIT_CEILING_DIRECTORIES="$1" git apply -R "$p"); then
      echo "note $(basename "$p") is applied (a demo in progress) - checked against its revert"
    fi
  done
}
drift_check() {
  local t p bad=0
  t=$(mktemp -d "$WORK/drift.XXXX")
  mkdir -p "$t/k3s/apps/lab-environment" && cp -r "$1/k3s/apps/lab-environment/k8s" "$t/k3s/apps/lab-environment/"
  unapply_demos "$t"
  for p in "$DEMO"/patches/*.patch; do
    if (cd "$t" && GIT_CEILING_DIRECTORIES="$t" git apply --check "$p" 2>"$WORK/apply.err"); then echo "PASS patch applies: $(basename "$p")"
    else echo "FAIL patch no longer applies: $(basename "$p")"; sed 's/^/    /' "$WORK/apply.err"; bad=1; fi
  done
  return $bad
}
out=$(drift_check "$HERE/../../../.." || true)
echo "$out"
fails=$((fails + $(grep -c '^FAIL' <<< "$out" || true)))
# While a live demo is in progress its patch is applied on main, so that patch
# (and any other touching the same lines) cannot apply again. The check must
# pass then, and still catch real drift.
# Fixtures start from the at-rest manifests, even if this run itself happens mid-demo.
fx_tree() { mkdir -p "$1/k3s/apps/lab-environment" && cp -r "$HERE/../k8s" "$1/k3s/apps/lab-environment/" && unapply_demos "$1" >/dev/null; }
fx_tree "$WORK/fx-demo"
(cd "$WORK/fx-demo" && GIT_CEILING_DIRECTORIES="$WORK" git apply "$DEMO/patches/fault-injection.patch")
out=$(drift_check "$WORK/fx-demo" 2>&1 || true)
if grep -q '^FAIL' <<< "$out"; then echo "FAIL drift check fails while a demo patch is applied"; sed 's/^/    /' <<< "$out" | grep FAIL; fails=$((fails+1))
else echo "PASS drift check passes while a demo patch is applied"; fi
grep -q 'fault-injection.patch is applied' <<< "$out" && echo "PASS drift check names the applied demo patch" || { echo "FAIL drift check did not name the applied patch"; fails=$((fails+1)); }
fx_tree "$WORK/fx-drift"
sed -i 's/# Pinned to the stable subset: this pin is the routing baseline every/# Pinned (edited) to the stable subset/' "$WORK/fx-drift/k3s/apps/lab-environment/k8s/resilience.yaml"
out=$(drift_check "$WORK/fx-drift" 2>&1 || true)
grep -q '^FAIL patch no longer applies: fault-injection.patch' <<< "$out" && echo "PASS drift check still catches real drift" || { echo "FAIL drift check missed real drift"; fails=$((fails+1)); }
# A reverted serviceAccountName does not revert: the API server backfills the
# deprecated serviceAccount field, which then re-defaults the name (17, 2026-09-29).
for p in "$DEMO"/patches/*.patch; do
  if grep -qE '^[-+][[:space:]]+serviceAccount(Name)?:' "$p"; then echo "FAIL patch changes a pod's service account: $(basename "$p")"; fails=$((fails+1))
  else echo "PASS patch leaves service accounts alone: $(basename "$p")"; fi
done
shopt -u nullglob

# --- scenario evidence (real scenario files) ---------------------------
cp "$DEMO/scenarios/rolling-update.sh" "$DEMO_SCENARIO_DIR/"
printf 'WINDOW_START=1000\nWINDOW_END=1300\n' > "$DEMO_STATE_DIR/rolling-update.window"
FAKE_LOKI_EMPTY=1 check "02 with no Envoy lines is insufficient" 1 "$DEMO/demo-evidence" rolling-update
if grep -q '\[envoy *\] PASS' "$WORK/out"; then echo "FAIL 02 envoy piece passed on an empty log stream"; fails=$((fails+1)); else echo "PASS 02 envoy piece fails on an empty log stream"; fi

# 07: selfHeal is a partial sync of the drifted Deployment, at whatever
# revision is current — another commit may have landed since 02.
cp "$DEMO/scenarios/gitops-selfheal-rollback.sh" "$DEMO_SCENARIO_DIR/"
printf 'WINDOW_START=1000\nWINDOW_END=1300\n' > "$DEMO_STATE_DIR/gitops-selfheal-rollback.window"
export FAKE_CTRL_LOG='time="1970-01-01T00:17:00Z" level=info msg="Initialized new operation: {&SyncOperation{Revision:0123abcd,Prune:true,Resources:[]SyncOperationResource{SyncOperationResource{Group:apps,Kind:Deployment,Name:customers-service,Namespace:,},},}}" application=lab-environment'
check "07 evidence runs" 1 "$DEMO/demo-evidence" gitops-selfheal-rollback
has "$WORK/out" "[argocd        ] PASS  selfHeal"
export FAKE_CTRL_LOG='time="1970-01-01T00:17:00Z" level=info msg="Initialized new operation: {&SyncOperation{Revision:0123abcd,Prune:true,Resources:[]SyncOperationResource{},}}" application=lab-environment'
check "07 evidence runs on a full sync" 1 "$DEMO/demo-evidence" gitops-selfheal-rollback
has "$WORK/out" "[argocd        ] FAIL  selfHeal"
unset FAKE_CTRL_LOG

# --- 2b routing scenarios: evidence against hook-driven stubs -------------
# A hook gets the stubbed command's arguments as one string in $1; it prints
# a response and exits 0, or exits 1 to fall through to the stub's defaults.
cl() { printf '{"metric":{"upstream_cluster":"inbound-vip|8081|http/%s|customers-service.lab-environment.svc.cluster.local;"},"value":[0,"%s"]}' "$1" "$2"; }
res() { printf '{"data":{"result":[%s]}}' "$1"; }
val() { printf '{"data":{"result":[{"metric":{},"value":[0,"%s"]}]}}' "$1"; }
win() { printf 'WINDOW_START=%s\nWINDOW_END=%s\n' "$2" "$3" > "$DEMO_STATE_DIR/$1.window"; }
export -f cl res val

# 09: one canary pod of six gets ~1/6 of the waypoint's requests.
cp "$DEMO/scenarios/canary-instance-ratio.sh" "$DEMO_SCENARIO_DIR/"
win canary-instance-ratio 1000 1300
cat > "$WORK/hook09" <<'EOF'
#!/bin/bash
c=${C09:-20}
case "$1" in
  *"track=canary"*"podIP"*) echo "10.42.1.99" ;;
  *"sum by (upstream_host)"*)
    res "{\"metric\":{\"upstream_host\":\"envoy://connect_originate/10.42.1.99:8081\"},\"value\":[0,\"$c\"]},{\"metric\":{\"upstream_host\":\"envoy://connect_originate/10.42.1.40:8081\"},\"value\":[0,\"100\"]}" ;;
  *"customers-service-canary"*"time=1000"*) val 10 ;;
  *"customers-service-canary"*"time=1320"*) val $((10 + c)) ;;
  *"time=1000"*) val 500 ;;
  *"time=1320"*) val $((500 + 100 + c)) ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook09"
FAKE_CURL_HOOK=$WORK/hook09 FAKE_KUBECTL_HOOK=$WORK/hook09 check "09 passes at 1 of 6" 0 "$DEMO/demo-evidence" canary-instance-ratio
has "$WORK/out" "sent 20 of 120 customers-service requests to the canary pod: 16%"
has "$WORK/out" "canary pod's own count: 20 of 120 requests, 16%"
C09=0 FAKE_CURL_HOOK=$WORK/hook09 FAKE_KUBECTL_HOOK=$WORK/hook09 check "09 fails when the canary got nothing" 1 "$DEMO/demo-evidence" canary-instance-ratio
C09=100 FAKE_CURL_HOOK=$WORK/hook09 FAKE_KUBECTL_HOOK=$WORK/hook09 check "09 fails at a 50% share" 1 "$DEMO/demo-evidence" canary-instance-ratio

# 10: every 5xx on the canary subset, the rollback deployed.
cp "$DEMO/scenarios/canary-weight.sh" "$DEMO_SCENARIO_DIR/"
export DEMO_REPO_ROOT=$WORK/repo10; git init -q "$DEMO_REPO_ROOT"
git -C "$DEMO_REPO_ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'demo: canary customers-service v2-bad at 10%'
git -C "$DEMO_REPO_ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'Revert "demo: canary customers-service v2-bad at 10%"'
REVERT10=$(git -C "$DEMO_REPO_ROOT" rev-parse HEAD)
win canary-weight 1000 1300
export J10_ALL="$(cl canary 12),$(cl stable 100)" J10_ERR="$(cl canary 12)"
cat > "$WORK/hook10" <<'EOF'
#!/bin/bash
case "$1" in
  *'response_code=~'*) res "${E10:-$J10_ERR}" ;;
  *"sum by (upstream_cluster)"*) res "$J10_ALL" ;;
  *'customers-service-canary'*'status="500"'*"time=1320"*) val 12 ;;
  *'status="500"'*"time=1320"*) val 12 ;;
  *'status="500"'*) res "" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook10"
H10='[{"revision":"'$REVERT10'","deployStartedAt":"1970-01-01T00:22:00Z","deployedAt":"1970-01-01T00:22:10Z"}]'
FAKE_HISTORY=$H10 FAKE_CURL_HOOK=$WORK/hook10 check "10 passes: 5xx only on the canary, rollback deployed" 0 "$DEMO/demo-evidence" canary-weight
has "$WORK/out" "canary took 10% of customers-service requests"
has "$WORK/out" "5xx: canary 12, stable 0"
E10="$(cl canary 12),$(cl stable 3)" FAKE_HISTORY=$H10 FAKE_CURL_HOOK=$WORK/hook10 check "10 fails when stable also returned 5xx" 1 "$DEMO/demo-evidence" canary-weight
FAKE_CURL_HOOK=$WORK/hook10 check "10 fails when the rollback never deployed" 1 "$DEMO/demo-evidence" canary-weight
# A forgotten revert: reset refuses at once (no 3-minute wait for pods that
# cannot go) and still names what is left.
: > "$FAKE_LOG"
FAKE_CANARY_REPLICAS=1 FAKE_VS=$WORK/vs-weights.json check "reset after a forgotten revert fails fast" 1 "$DEMO/demo-reset" canary-weight
has "$WORK/out" "still scaled to '1'"
has "$WORK/out" "off the stable pin: weights"
if grep -q "wait --for=delete" "$FAKE_LOG"; then echo "FAIL reset waited for canary pods that cannot go"; fails=$((fails+1)); else echo "PASS reset did not wait"; fi
FAKE_VS=$WORK/vs-header.json check "reset names a leftover header rule" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "off the stable pin: subset canary+header match"
FAKE_VS=$WORK/vs-fault.json check "reset names a leftover fault rule" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "off the stable pin: header match+fault"
FAKE_VISITS_ENV="TZ DATA_DB_HOST DATA_REDIS_HOST" check "reset fails while visits still points at toxiproxy" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "visits-service still points at toxiproxy"
FAKE_TOXI_PRINCIPAL=1 check "reset fails while postgres/redis still admit toxiproxy" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "still admit sa/toxiproxy"
FAKE_NO_RATELIMIT=1 check "reset fails when the resident rate limit is gone" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "vets-service-ratelimit TrafficExtension missing"
unset DEMO_REPO_ROOT

# 11: exactly the marked requests reach the canary.
cp "$DEMO/scenarios/header-canary.sh" "$DEMO_SCENARIO_DIR/"
win header-canary 1000 1300
export J11_STABLE="$(cl stable 90)"
cat > "$WORK/hook11" <<'EOF'
#!/bin/bash
case "$1" in
  *"sum by (upstream_cluster)"*) res "$(cl canary "${C11:-40}"),$J11_STABLE" ;;
  *"customers-service-canary"*"time=1000"*) val 3 ;;
  *"customers-service-canary"*"time=1320"*) val 43 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook11"
FAKE_CURL_HOOK=$WORK/hook11 check "11 passes: exactly the 40 marked requests hit the canary" 0 "$DEMO/demo-evidence" header-canary
C11=41 FAKE_CURL_HOOK=$WORK/hook11 check "11 fails when an unmarked request reached the canary" 1 "$DEMO/demo-evidence" header-canary

# 13: the shadow failed on the canary cluster; users were all served by stable.
cp "$DEMO/scenarios/mirror.sh" "$DEMO_SCENARIO_DIR/"
win mirror 1000 1300
export J13_STABLE="$(cl stable 150)"
cat > "$WORK/hook13" <<'EOF'
#!/bin/bash
case "$1" in
  *"envoy_cluster_upstream_rq{"*"time=1000"*) val 0 ;;
  *"envoy_cluster_upstream_rq{"*"time=1320"*) val 25 ;;
  *"sum by (upstream_cluster)"*) res "$J13_STABLE" ;;
  *"traffic-generator"*'!~'*) val "${G13:-0}" ;;
  *"traffic-generator"*) val 300 ;;
  *'status="500"'*"time=1000"*) res "" ;;
  *'status="500"'*"time=1320"*) val 25 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook13"
FAKE_CURL_HOOK=$WORK/hook13 check "13 passes: shadow failed, users all 200" 0 "$DEMO/demo-evidence" mirror
has "$WORK/out" "answered 25 mirrored requests with 5xx"
G13=2 FAKE_CURL_HOOK=$WORK/hook13 check "13 fails when a user saw an error" 1 "$DEMO/demo-evidence" mirror

# 12: blue before the switch, green after it, blue after the rollback; the
# seconds while each sync propagates are never judged.
cp "$DEMO/scenarios/blue-green.sh" "$DEMO_SCENARIO_DIR/"
export DEMO_REPO_ROOT=$WORK/repo12; git init -q "$DEMO_REPO_ROOT"
git -C "$DEMO_REPO_ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'demo: switch customers-service to green'; SW12=$(git -C "$DEMO_REPO_ROOT" rev-parse HEAD)
git -C "$DEMO_REPO_ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'Revert "demo: switch customers-service to green"'; BK12=$(git -C "$DEMO_REPO_ROOT" rev-parse HEAD)
win blue-green 1000 2000
H12='[{"revision":"'$SW12'","deployStartedAt":"1970-01-01T00:20:00Z","deployedAt":"1970-01-01T00:20:10Z"},{"revision":"'$BK12'","deployStartedAt":"1970-01-01T00:26:40Z","deployedAt":"1970-01-01T00:26:50Z"}]'
export J12_STABLE="$(cl stable 200)" J12_GREEN="$(cl canary 350)" J12_BACK="$(cl stable 350)" J12_LEAK="$(cl canary 3)"
cat > "$WORK/hook12" <<'EOF'
#!/bin/bash
case "$1" in
  *"sum by (upstream_cluster)"*"time=1200000000000"*) res "$J12_STABLE${A12:+,$J12_LEAK}" ;;
  *"sum by (upstream_cluster)"*"time=1600000000000"*) res "$J12_GREEN" ;;
  *"sum by (upstream_cluster)"*"time=2000000000000"*) res "$J12_BACK" ;;
  *"traffic-generator"*'!~'*) val 0 ;;
  *"traffic-generator"*) val 1000 ;;
  *"quantile_over_time"*) val 412 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook12"
: > "$FAKE_LOG"
FAKE_HISTORY=$H12 FAKE_CURL_HOOK=$WORK/hook12 check "12 passes: blue, then green, then blue" 0 "$DEMO/demo-evidence" blue-green
has "$FAKE_LOG" "[200s]"
# Existing connections keep the old route until Envoy's 45 s listener drain
# ends, so each judged segment starts 50 s after its sync finished.
grep -q '\[340s\].*time=1600000000000' "$FAKE_LOG" && echo "PASS 12 green segment starts at deployedAt + 50" || { echo "FAIL 12 green segment range"; fails=$((fails+1)); }
grep -q '\[340s\].*time=2000000000000' "$FAKE_LOG" && echo "PASS 12 after segment starts at deployedAt + 50" || { echo "FAIL 12 after segment range"; fails=$((fails+1)); }
A12=1 FAKE_HISTORY=$H12 FAKE_CURL_HOOK=$WORK/hook12 check "12 fails on green traffic before the switch" 1 "$DEMO/demo-evidence" blue-green
FAKE_CURL_HOOK=$WORK/hook12 check "12 fails without the switch in ArgoCD history" 1 "$DEMO/demo-evidence" blue-green
unset DEMO_REPO_ROOT

# 14: the bad pod was ejected; retries hid it from every user.
cp "$DEMO/scenarios/bad-pod.sh" "$DEMO_SCENARIO_DIR/"
win bad-pod 1000 1300
echo customers-service-abc > "$DEMO_STATE_DIR/bad-pod.name"
cat > "$WORK/hook14" <<'EOF'
#!/bin/bash
case "$1" in
  *"ejections_active"*) val "${E14:-1}" ;;
  *"attempts > 1"*) val "${R14:-9}" ;;
  *"response_code != "*) val "${F14:-0}" ;;
  *"customers-service-abc"*"time=1000"*) val 0 ;;
  *"customers-service-abc"*"time=1320"*) val 10 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook14"
FAKE_CURL_HOOK=$WORK/hook14 check "14 passes: ejected, retried, no user error" 0 "$DEMO/demo-evidence" bad-pod
has "$WORK/out" "answered 10 requests with 503 itself"
E14=0 FAKE_CURL_HOOK=$WORK/hook14 check "14 fails when nothing was ejected" 1 "$DEMO/demo-evidence" bad-pod
F14=2 FAKE_CURL_HOOK=$WORK/hook14 check "14 fails when a user saw an error" 1 "$DEMO/demo-evidence" bad-pod

# 15: exactly the marked requests were delayed / aborted; aborts never
# reached a pod; the generator never noticed.
cp "$DEMO/scenarios/fault-injection.sh" "$DEMO_SCENARIO_DIR/"
win fault-injection 1000 1300
cat > "$WORK/hook15" <<'EOF'
#!/bin/bash
case "$1" in
  *".*DI.*"*) val "${D15:-10}" ;;
  *".*FI.*"*) val "${A15:-10}" ;;
  *"envoy_cluster_upstream_rq{"*"time=1000"*) val 4 ;;
  *"envoy_cluster_upstream_rq{"*"time=1320"*) val "${U15:-4}" ;;
  *"traffic-generator"*'!~'*) val 0 ;;
  *"traffic-generator"*) val 300 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook15"
FAKE_CURL_HOOK=$WORK/hook15 check "15 passes: 10 delayed, 10 aborted locally" 0 "$DEMO/demo-evidence" fault-injection
A15=11 FAKE_CURL_HOOK=$WORK/hook15 check "15 fails when an unmarked request was aborted" 1 "$DEMO/demo-evidence" fault-injection
U15=9 FAKE_CURL_HOOK=$WORK/hook15 check "15 fails when an abort reached a pod" 1 "$DEMO/demo-evidence" fault-injection

# 17: the mesh's 1 s per-try timeout cut the toxic's latency on visits.
cp "$DEMO/scenarios/toxiproxy.sh" "$DEMO_SCENARIO_DIR/"
win toxiproxy 1000 1300
cat > "$WORK/hook17" <<'EOF'
#!/bin/bash
case "$1" in
  *'response_flags="UT"'*) res "{\"metric\":{\"upstream_cluster\":\"inbound-vip|8082|http|visits-service.lab-environment.svc.cluster.local;\"},\"value\":[0,\"${T17:-6}\"]}" ;;
  *"http_server_requests_seconds_max"*) val 2.01 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook17"
FAKE_CURL_HOOK=$WORK/hook17 check "17 passes: visits timed out at the mesh" 0 "$DEMO/demo-evidence" toxiproxy
T17=0 FAKE_CURL_HOOK=$WORK/hook17 check "17 fails without an upstream timeout on visits" 1 "$DEMO/demo-evidence" toxiproxy

# 16: the burst was limited at the waypoint; vets itself saw only the
# admitted requests; steady traffic was untouched.
cp "$DEMO/scenarios/rate-limit.sh" "$DEMO_SCENARIO_DIR/"
win rate-limit 1000 1300
cat > "$WORK/hook16" <<'EOF'
#!/bin/bash
case "$1" in
  *"sum by (pod_name)"*) res "{\"metric\":{\"pod_name\":\"waypoint-a\"},\"value\":[0,\"${L16:-20}\"]},{\"metric\":{\"pod_name\":\"waypoint-b\"},\"value\":[0,\"18\"]}" ;;
  *"vets-service"*"time=1000"*) val 100 ;;
  *"vets-service"*"time=1320"*) val "${V16:-125}" ;;
  *"traffic-generator"*'(200|429)'*) val "${GO16:-0}" ;;
  *"traffic-generator"*'|= " 429 /api/vet/vets"'*) val "${GV16:-0}" ;;
  *"traffic-generator"*'!~'*'!= "/api/vet/vets"'*) val "${G16:-0}" ;;
  *"traffic-generator"*'!~'*) val $(( ${G16:-0} + ${GV16:-0} )) ;;
  *"traffic-generator"*) val 300 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook16"
FAKE_CURL_HOOK=$WORK/hook16 check "16 passes: 38 limited, vets saw only the rest" 0 "$DEMO/demo-evidence" rate-limit
has "$WORK/out" "waypoint-a 20"
V16=170 FAKE_CURL_HOOK=$WORK/hook16 check "16 fails when every request reached vets" 1 "$DEMO/demo-evidence" rate-limit
G16=3 FAKE_CURL_HOOK=$WORK/hook16 check "16 fails when the generator's other paths failed" 1 "$DEMO/demo-evidence" rate-limit
# The bucket is shared: a generator /api/vet/vets call inside the burst's
# second is limited like any other caller (rehearsal 2026-09-29).
GV16=1 FAKE_CURL_HOOK=$WORK/hook16 check "16 passes when the burst also limited a generator vets call" 0 "$DEMO/demo-evidence" rate-limit
has "$WORK/out" "generator's own /api/vet/vets calls limited in the burst: 1"
GO16=1 FAKE_CURL_HOOK=$WORK/hook16 check "16 fails when a generator vets call failed with something other than 429" 1 "$DEMO/demo-evidence" rate-limit

# 08: shed fast, admitted P99 flat, node and pool out of saturation; the
# minute table survives a run across UTC midnight.
cp "$DEMO/scenarios/load-test.sh" "$DEMO_SCENARIO_DIR/"
win load-test 86100 86520
mr() { printf '{"data":{"result":[{"metric":{},"values":[[86280,"%s"],[86340,"%s"],[86400,"%s"],[86460,"%s"],[86520,"%s"]]}]}}' "$@"; }
export -f mr
cat > "$WORK/hook08" <<'EOF'
#!/bin/bash
case "$1" in
  *"query_range"*"histogram_quantile"*)
    if [ -n "${GAP08:-}" ]; then printf '{"data":{"result":[{"metric":{},"values":[[86280,"70"],[86400,"90"],[86460,"95"],[86520,"99"]]}]}}'
    else mr 70 80 90 95 99; fi ;;
  *"query_range"*) mr 10 20 40 60 80 ;;
  *'response_code="429"'*) val "${S08:-500}" ;;
  *'response_code="200"'*) val "${P08:-180}" ;;
  *'id="/"'*) val "${N08:-1.1}" ;;
  *"cfs_throttled"*) res '{"metric":{"pod":"vets-service-x"},"value":[0,"0.1"]}' ;;
  *"hikaricp_connections_acquire_seconds_max"*) res "{\"metric\":{\"service\":\"vets-service\"},\"value\":[0,\"${H08:-0.1}\"]}" ;;
  *"container_memory_working_set_bytes"*) val 402653184 ;;
  *"/api/prometheus/grafana"*) echo '{"data":{"alerts":[]}}' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook08"
FAKE_CURL_HOOK=$WORK/hook08 check "08 passes: shed, flat, unsaturated" 0 "$DEMO/demo-evidence" load-test
for m in "23:58" "23:59" "00:00" "00:01" "00:02"; do has "$WORK/out" "      $m "; done
got=$(grep -oE '^      [0-9]{2}:[0-9]{2} ' "$WORK/out" | tr -d ' ' | paste -sd' ')
[ "$got" = "23:58 23:59 00:00 00:01 00:02" ] && echo "PASS 08 minute table in time order across midnight" || { echo "FAIL 08 minute table order: '$got'"; fails=$((fails+1)); }
GAP08=1 FAKE_CURL_HOOK=$WORK/hook08 check "08 run with a minute missing from one series (4 P99 points: fails the >= 5 rule)" 1 "$DEMO/demo-evidence" load-test
got=$(grep -oE '^      [0-9]{2}:[0-9]{2} ' "$WORK/out" | tr -d ' ' | paste -sd' ')
[ "$got" = "23:58 23:59 00:00 00:01 00:02" ] && echo "PASS 08 minute table keeps a minute missing from one series" || { echo "FAIL 08 minute table with a gap: '$got'"; fails=$((fails+1)); }
grep -q '^      23:59    20  -$' "$WORK/out" && echo "PASS 08 missing P99 shown as -" || { echo "FAIL 08 missing P99 not shown as -"; fails=$((fails+1)); }
N08=1.8 FAKE_CURL_HOOK=$WORK/hook08 check "08 fails when the node saturated" 1 "$DEMO/demo-evidence" load-test
S08=0 FAKE_CURL_HOOK=$WORK/hook08 check "08 fails when nothing was shed" 1 "$DEMO/demo-evidence" load-test
H08=2.9 FAKE_CURL_HOOK=$WORK/hook08 check "08 fails when vets still queued for connections" 1 "$DEMO/demo-evidence" load-test

# --- 2a scenarios: evidence against hook-driven stubs ----------------------
# 03: the PreSync hook of 02's sync finished before the first new pod.
cp "$DEMO/scenarios/schema-migration.sh" "$DEMO_SCENARIO_DIR/"
export DEMO_REPO_ROOT=$WORK/repo03; git init -q "$DEMO_REPO_ROOT"
git -C "$DEMO_REPO_ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'demo: rolling-restart customers-service'
SHA03=$(git -C "$DEMO_REPO_ROOT" rev-parse HEAD); export SHA03
printf 'WINDOW_START=1000\nWINDOW_END=1300\nOWNERS_BEFORE=10\n' > "$DEMO_STATE_DIR/rolling-update.window"
cat > "$WORK/hook03" <<'EOF'
#!/bin/bash
case "$1" in
  *"app get lab-environment"*) echo "{\"status\":{\"operationState\":{\"syncResult\":{\"revision\":\"$SHA03\",\"resources\":[{\"kind\":\"Job\",\"name\":\"db-init\",\"syncPhase\":\"PreSync\",\"hookPhase\":\"Succeeded\"}]}}}}" ;;
  *"get job db-init"*) echo "1970-01-01T00:17:00Z" ;;
  *"get pods -l app=customers-service -o json"*)
    if [ -n "${NOPODS03:-}" ]; then echo '{"items":[]}'
    else echo '{"items":[{"metadata":{"creationTimestamp":"1970-01-01T00:17:30Z"}},{"metadata":{"creationTimestamp":"1970-01-01T00:16:00Z","deletionTimestamp":"1970-01-01T00:17:40Z"}}]}'; fi ;;
  *"exec deploy/postgres"*) echo "${OWN03:-10}" ;;
  *"logs job/db-init"*) echo "applying customers.sql" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook03"
FAKE_ARGOCD_HOOK=$WORK/hook03 FAKE_KUBECTL_HOOK=$WORK/hook03 check "03 passes: hook first, data untouched" 0 "$DEMO/demo-evidence" schema-migration
has "$WORK/out" "first new customers pod 1970-01-01T00:17:30Z"
NOPODS03=1 FAKE_ARGOCD_HOOK=$WORK/hook03 FAKE_KUBECTL_HOOK=$WORK/hook03 check "03 fails with no running customers pod" 1 "$DEMO/demo-evidence" schema-migration
has "$WORK/out" "[kubernetes    ] FAIL"
OWN03=12 FAKE_ARGOCD_HOOK=$WORK/hook03 FAKE_KUBECTL_HOOK=$WORK/hook03 check "03 fails when the re-run changed the data" 1 "$DEMO/demo-evidence" schema-migration
unset DEMO_REPO_ROOT

# 04: 403s at the mesh, RBAC denials, and three ztunnel L4 rejections.
cp "$DEMO/scenarios/zero-trust.sh" "$DEMO_SCENARIO_DIR/"
win zero-trust 1000 1300
cat > "$WORK/hook04" <<'EOF'
#!/bin/bash
case "$1" in
  *"envoy_http_rbac"*) val "${D04:-2}" ;;
  *"logs -l app=ztunnel"*)
    echo 'warn access connection complete src.addr=10.0.0.95:40000 dst.service="customers-service.lab-environment.svc.cluster.local" error="policy rejection"'
    echo 'warn access connection complete src.addr=10.42.1.7:40001 src.workload="traffic-generator-abc" dst.service="customers-service.lab-environment.svc.cluster.local" error="policy rejection"'
    echo "warn access connection complete ${ODD04:-src.addr=10.42.1.8:40002} dst.service=\"postgres.lab-environment.svc.cluster.local\" error=\"policy rejection\""
    echo 'info access connection complete src.workload="api-gateway-x" dst.service="customers-service.lab-environment.svc.cluster.local"' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook04"
FAKE_CURL_HOOK=$WORK/hook04 FAKE_KUBECTL_HOOK=$WORK/hook04 check "04 passes: 403s, RBAC denials, 3 L4 rejections" 0 "$DEMO/demo-evidence" zero-trust
has "$WORK/out" "traffic-generator-abc -> customers-service"
has "$WORK/out" "ztunnel L4 policy rejections: 3"
D04=0 FAKE_CURL_HOOK=$WORK/hook04 FAKE_KUBECTL_HOOK=$WORK/hook04 check "04 fails without an RBAC denial" 1 "$DEMO/demo-evidence" zero-trust
ODD04=peer=unknown FAKE_CURL_HOOK=$WORK/hook04 FAKE_KUBECTL_HOOK=$WORK/hook04 check "04 runs on through a rejection with no source field" 0 "$DEMO/demo-evidence" zero-trust
has "$WORK/out" "? -> postgres"

# --- runbook pages: a secret never goes on a command line (visible in ps) --
if grep -nE -- '--from-literal=password|PGPASSWORD=[^"]*\$NEW|--password[= ]' "$HERE/../../../../docs/demo/"*.md; then
  echo "FAIL a runbook page puts a password on argv"; fails=$((fails+1))
else echo "PASS no password on argv in the runbook pages"; fi

# --- runbook pages: nothing in a pasted block can hang the demo -------------
# Ctrl-C out of a watch also drops the rest of the pasted block, and a wait
# with no deadline spins silently after a rejected push.
if grep -nE 'kubectl[^|]* get [^|]*(-w|--watch)( |$)' "$HERE/../../../../docs/demo/"*.md; then
  echo "FAIL a runbook page watches with kubectl get -w"; fails=$((fails+1))
else echo "PASS no kubectl watch in the runbook pages"; fi
out=$(awk '/^```bash/ { code = 1; next } /^```/ { code = 0; loop = 0; next }
  code && !loop && /(^|;[ \t]*)(until|while)[ \t]/ { loop = 1; start = FNR; body = "" }
  code && loop { body = body $0 }
  code && loop && /(^|;[ \t]*)done([ ;]|$)/ { if (body !~ /SECONDS/) print FILENAME ":" start; loop = 0 }' \
  "$HERE/../../../../docs/demo/"*.md)
if [ -n "$out" ]; then echo "FAIL runbook wait loops without a deadline:"; sed 's/^/    /' <<< "$out"; fails=$((fails+1))
else echo "PASS every runbook wait loop has a deadline"; fi

[ $fails -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
