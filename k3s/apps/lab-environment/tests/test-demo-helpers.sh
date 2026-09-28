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
    if [ -n "${FAKE_CHAOS_ON:-}" ]; then v=dHJ1ZQ==; else v=ZmFsc2U=; fi
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
  *" get deploy "*) d=$(sed -E 's/.* get deploy ([^ ]+).*/\1/' <<< "$*"); grep "^$d " "$FAKE_DEPLOYS" | cut -d' ' -f2- ;;
  *"logs statefulset/argocd-application-controller"*) printf '%s\n' "${FAKE_CTRL_LOG:-}" ;;
  *"logs deploy/traffic-generator"*) for i in 1 2 3; do echo "2026-09-27T00:00:0${i}+00:00 ${FAKE_GEN_CODE:-200} /api/vet/vets"; done ;;
esac
EOF
cat > "$WORK/bin/argocd" <<'EOF'
#!/bin/bash
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
for p in "$DEMO"/patches/*.patch; do
  if git -C "$HERE/../../../.." apply --check "$p" 2>"$WORK/apply.err"; then echo "PASS patch applies: $(basename "$p")"
  else echo "FAIL patch no longer applies: $(basename "$p")"; sed 's/^/    /' "$WORK/apply.err"; fails=$((fails+1)); fi
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
unset DEMO_REPO_ROOT

# --- runbook pages: a secret never goes on a command line (visible in ps) --
if grep -nE -- '--from-literal=password|PGPASSWORD=[^"]*\$NEW|--password[= ]' "$HERE/../../../../docs/demo/"*.md; then
  echo "FAIL a runbook page puts a password on argv"; fails=$((fails+1))
else echo "PASS no password on argv in the runbook pages"; fi

[ $fails -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
