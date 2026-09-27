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
case "$*" in
  *FAILME*) exit 22 ;;
  *"/v1/kv/chaos/"*)
    if [ -n "${FAKE_CHAOS_ON:-}" ]; then v=dHJ1ZQ==; else v=ZmFsc2U=; fi
    echo "[{\"Key\":\"${FAKE_CHAOS_ON:-chaos/visits-service/redis-timeout}\",\"Value\":\"$v\"}]" ;;
  *"/loki/api/v1/query"*) echo '{"data":{"result":[{"metric":{},"value":[0,"7"]}]}}' ;;
  *) echo '{"data":{"result":[]}}' ;;
esac
EOF
cat > "$WORK/bin/kubectl" <<'EOF'
#!/bin/bash
echo "kubectl $*" >> "$FAKE_LOG"
case "$*" in
  *" get deploy "*) d=$(sed -E 's/.* get deploy ([^ ]+).*/\1/' <<< "$*"); grep "^$d " "$FAKE_DEPLOYS" | cut -d' ' -f2- ;;
  *"logs deploy/traffic-generator"*) for i in 1 2 3; do echo "2026-09-27T00:00:0${i}+00:00 ${FAKE_GEN_CODE:-200} /api/vet/vets"; done ;;
esac
EOF
cat > "$WORK/bin/argocd" <<'EOF'
#!/bin/bash
echo "{\"status\":{\"sync\":{\"status\":\"${FAKE_SYNC:-Synced}\"},\"health\":{\"status\":\"Healthy\"}}}"
EOF
chmod +x "$WORK/bin/"*

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

[ $fails -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
