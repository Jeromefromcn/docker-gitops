#!/bin/bash
# Behaviour tests for demo-baseline against stubbed curl/kubectl/argocd, plus
# the rules every runbook page in docs/demo/ must keep.
# No cluster access: every external call goes to a stub in $WORK/bin.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DEMO=$HERE/../demo
DOCS=$HERE/../../../../docs/demo
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export DEMO_BASELINE_TIMEOUT=0
export FAKE_DEPLOYS=$WORK/deploys
mkdir -p "$WORK/bin"
export PATH=$WORK/bin:$PATH

cat > "$WORK/bin/curl" <<'EOF'
#!/bin/bash
case "$*" in
  *"/v1/kv/chaos/"*) [ -z "${FAKE_CONSUL_DOWN:-}" ] || exit 7 ;;&
  *"/v1/kv/chaos/"*)
    if [ -n "${FAKE_CHAOS_ON:-}" ]; then v=${FAKE_CHAOS_VALUE:-dHJ1ZQ==}; else v=ZmFsc2U=; fi
    echo "[{\"Key\":\"${FAKE_CHAOS_ON:-chaos/visits-service/redis-timeout}\",\"Value\":\"$v\"}]" ;;
esac
EOF
cat > "$WORK/bin/kubectl" <<'EOF'
#!/bin/bash
case "$*" in
  *"get deploy customers-service-canary"*"spec.replicas"*) echo "${FAKE_CANARY_REPLICAS:-0}" ;;
  *"get deploy customers-service-canary"*"image"*) echo "${FAKE_CANARY_IMAGE:-$(grep -m1 -oP 'image: \K\S+' "$FAKE_LAB_K8S/customers-service-canary.yaml")}" ;;
  *"get pods -l app=customers-service,track=canary -o name"*) printf '%s' "${FAKE_CANARY_PODS:-}" ;;
  *"get virtualservice customers-service -o json"*) cat "${FAKE_VS:-$FAKE_VS_PINNED}" ;;
  *"get trafficextension vets-service-ratelimit"*) [ -n "${FAKE_NO_RATELIMIT:-}" ] || echo "trafficextension.extensions.istio.io/vets-service-ratelimit" ;;
  *"get deploy visits-service -o jsonpath"*"env"*) echo "${FAKE_VISITS_ENV:-TZ SPRING_CLOUD_CONSUL_HOST SPRING_CLOUD_CONSUL_PORT DATA_DB_PASSWORD}" ;;
  *"get authorizationpolicy postgres-clients redis-clients"*) echo "{\"items\":[{\"spec\":{\"rules\":[{\"from\":[{\"source\":{\"principals\":[\"cluster.local/ns/lab-environment/sa/visits-service\"${FAKE_TOXI_PRINCIPAL:+,\"cluster.local/ns/lab-environment/sa/toxiproxy\"}]}}]}]}}]}" ;;
  *"get deploy,pods -l lab.jerome/lane -o name"*) printf '%s' "${FAKE_LANE_OBJS:-}" ;;
  *" get deploy "*) d=$(sed -E 's/.* get deploy ([^ ]+).*/\1/' <<< "$*"); grep "^$d " "$FAKE_DEPLOYS" | cut -d' ' -f2- ;;
  *"logs deploy/traffic-generator"*) for i in 1 2 3; do echo "2026-09-27T00:00:0${i}+00:00 ${FAKE_GEN_CODE:-200} /api/vet/vets"; done ;;
esac
EOF
cat > "$WORK/bin/argocd" <<'EOF'
#!/bin/bash
echo "{\"status\":{\"sync\":{\"status\":\"${FAKE_SYNC:-Synced}\"},\"health\":{\"status\":\"Healthy\"}}}"
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

fails=0
check() { # check <name> <expected-exit> <cmd...>
  local name=$1 want=$2 got=0; shift 2
  "$@" > "$WORK/out" 2>&1 || got=$?
  if [ "$got" = "$want" ]; then echo "PASS $name"; else echo "FAIL $name (exit $got, want $want)"; sed 's/^/    /' "$WORK/out"; fails=$((fails+1)); fi
}
has() { grep -qF -- "$2" "$1" || { echo "FAIL expected '$2' in $1"; fails=$((fails+1)); }; }
B=$DEMO/demo-baseline

# --- demo-baseline -------------------------------------------------------
check "rejects arguments" 2 "$B" preflight
check "passes at the baseline" 0 "$B"
has "$WORK/out" "baseline OK"
FAKE_CHAOS_ON=chaos/customers-service/slow-query-enabled check "fails on any chaos key" 1 "$B"
has "$WORK/out" "chaos/customers-service/slow-query-enabled"
FAKE_CHAOS_ON=chaos/customers-service/fail-instance FAKE_CHAOS_VALUE=$(printf customers-service-abc | base64) \
  check "fails while fail-instance names a pod" 1 "$B"
has "$WORK/out" "chaos/customers-service/fail-instance"
# One pod short of git's count, then back to the fixture's line.
cust=$(grep '^customers-service ' "$FAKE_DEPLOYS"); r=${cust##* }
sed -i "s/^customers-service .*/customers-service $((r - 1)) $r/" "$FAKE_DEPLOYS"
check "fails on replica mismatch" 1 "$B"
sed -i "s/^customers-service .*/$cust/" "$FAKE_DEPLOYS"
FAKE_GEN_CODE=503 check "fails on generator errors" 1 "$B"
FAKE_SYNC=OutOfSync check "fails when ArgoCD is not synced" 1 "$B"
FAKE_CONSUL_DOWN=1 check "fails when Consul is unreachable" 1 "$B"
has "$WORK/out" "Consul unreachable"

# --- routing baseline ------------------------------------------------------
for v in weights mirror header switched unpinned; do
  FAKE_VS=$WORK/vs-$v.json check "fails on a VirtualService left $v" 1 "$B"
  has "$WORK/out" "off the stable pin"
done
FAKE_VS=$WORK/vs-header.json check "names a leftover header rule" 1 "$B"
has "$WORK/out" "off the stable pin: subset canary+header match"
FAKE_VS=$WORK/vs-fault.json check "names a leftover fault rule" 1 "$B"
has "$WORK/out" "off the stable pin: header match+fault"
FAKE_CANARY_REPLICAS=1 check "fails while the canary is scaled up" 1 "$B"
has "$WORK/out" "customers-service-canary spec.replicas '1'"
FAKE_CANARY_PODS='pod/customers-service-canary-abc' check "fails while canary pods are terminating" 1 "$B"
has "$WORK/out" "canary pods still present"
FAKE_CANARY_IMAGE=ghcr.io/jeromefromcn/petclinic-customers-service@sha256:bad check "fails on a canary image off git" 1 "$B"
FAKE_LANE_OBJS='pod/visits-service-pr-42-abc' check "fails while a PR lane pod exists" 1 "$B"
has "$WORK/out" "lane objects still present: pod/visits-service-pr-42-abc"
FAKE_LANE_OBJS='deployment.apps/visits-service-pr-42' check "fails on a lane Deployment stuck without a pod (FailedCreate)" 1 "$B"
has "$WORK/out" "lane objects still present: deployment.apps/visits-service-pr-42"

# --- dependency chaos and the limiter ------------------------------------
FAKE_VISITS_ENV="TZ DATA_DB_HOST DATA_REDIS_HOST" check "fails while visits still points at toxiproxy" 1 "$B"
has "$WORK/out" "visits-service still points at toxiproxy"
FAKE_TOXI_PRINCIPAL=1 check "fails while postgres/redis still admit toxiproxy" 1 "$B"
has "$WORK/out" "still admit sa/toxiproxy"
FAKE_NO_RATELIMIT=1 check "fails when the resident rate limit is gone" 1 "$B"
has "$WORK/out" "vets-service-ratelimit TrafficExtension missing"

# --- runbook pages: a secret never goes on a command line (visible in ps) --
if grep -nE -- '--from-literal=password|PGPASSWORD=[^"]*\$NEW|--password[= ]' "$DOCS/"*.md; then
  echo "FAIL a runbook page puts a password on argv"; fails=$((fails+1))
else echo "PASS no password on argv in the runbook pages"; fi

# --- runbook pages: nothing in a pasted block can hang the demo -------------
# Ctrl-C out of a watch also drops the rest of the pasted block, and a wait
# with no deadline spins silently after a rejected push.
if grep -nE 'kubectl[^|]* get [^|]*(-w|--watch)( |$)' "$DOCS/"*.md; then
  echo "FAIL a runbook page watches with kubectl get -w"; fails=$((fails+1))
else echo "PASS no kubectl watch in the runbook pages"; fi
out=$(awk '/^```bash/ { code = 1; next } /^```/ { code = 0; loop = 0; next }
  code && !loop && /(^|;[ \t]*)(until|while)[ \t]/ { loop = 1; start = FNR; body = "" }
  code && loop { body = body $0 }
  code && loop && /(^|;[ \t]*)done([ ;]|$)/ { if (body !~ /SECONDS/) print FILENAME ":" start; loop = 0 }' \
  "$DOCS/"*.md)
if [ -n "$out" ]; then echo "FAIL runbook wait loops without a deadline:"; sed 's/^/    /' <<< "$out"; fails=$((fails+1))
else echo "PASS every runbook wait loop has a deadline"; fi

# --- runbook pages: evidence is shown live, not collected by a helper --------
if grep -nE 'demo-(window|evidence|reset)|demo/patches/' "$DOCS/"*.md; then
  echo "FAIL a runbook page uses a removed demo helper"; fails=$((fails+1))
else echo "PASS no removed demo helper in the runbook pages"; fi

[ $fails -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
