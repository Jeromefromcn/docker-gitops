# 12 — Blue-green switch

## Purpose
Bring up a complete second copy of customers-service (green, v2, five pods
like blue), move all traffic to it in one step, and move it back in one
step — with no user-visible error either way.

## Preconditions
Preflight passed; 13 reset. The lab memory quota (9.25Gi) was sized for a
five-pod green alongside a full release; dify was decommissioned on
vps-oracle2 to make room.

## Commands
```bash
git pull --ff-only
git apply k3s/apps/lab-environment/demo/patches/blue-green-up.patch
git diff
git commit -m "demo: bring up green customers-service (5 x v2)" -- k3s/apps/lab-environment/k8s
git push || echo "PUSH FAILED - stop here"
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
kubectl -n lab-environment rollout status deploy/customers-service-canary --timeout=8m
kubectl -n lab-environment get pods -l app=customers-service -L track
kubectl -n lab-environment describe resourcequota lab-environment-quota | grep requests.memory
demo-window start blue-green
sleep 30
git apply k3s/apps/lab-environment/demo/patches/blue-green-switch.patch
git diff
git commit -m "demo: switch customers-service to green" -- k3s/apps/lab-environment/k8s
git push || echo "PUSH FAILED - stop here"
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
for i in $(seq 1 20); do curl -s -o /dev/null -D- http://10.0.0.95:30097/api/customer/owners/1 | tr -d '\r' | awk -F': ' 'tolower($1)=="x-app-version"{v=$2} END{print (v ? v : "none (v1)")}'; sleep 1; done | sort | uniq -c
sleep 60   # past the 45 s listener drain, so the evidence has a green-only stretch
git revert --no-edit HEAD
git push || echo "PUSH FAILED - stop here"
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
sleep 75   # past the drain again, for a blue-only stretch after the rollback
demo-window stop blue-green
demo-evidence blue-green
git revert --no-edit "$(git log -1 --grep='^demo: bring up green customers-service' --format=%H)"
git push || echo "PUSH FAILED - stop here"
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
```

## Expected result
After the switch every response carries `ce942c9e7124` (v2-good). The
evidence shows all traffic on blue before the switch, all on green after
it, all on blue after the rollback, both syncs deployed, and zero
generator errors over the whole window; green's P99 in its first minute is
noted.

## Evidence
- **Envoy (waypoint access log):** subset per request in three segments
  cut at the two syncs — the 50 s after each sync, while old connections
  drain, are excluded.
- **ArgoCD:** the switch and its revert in the deploy history, with their
  start/end times — the segment boundaries.
- **App:** the traffic generator all 200 across both switches.

## Talking points
- The switch is one field in git (`subset: stable` → `canary`), and the
  rollback is the same size. **It is not instantaneous per connection:**
  the waypoint's routes live in its listener, so an update reaches new
  connections at once, while existing keep-alive connections (the
  gateway's pool) finish on the old route until Envoy's 45 s drain ends.
  Measured in the first rehearsal (2026-09-28): one request still reached
  green 28 s after the rollback had synced. The evidence therefore judges
  each side only from 50 s after its sync.
- **Cost:** double capacity for the duration — five more JVMs, 1920Mi of
  requests. On this node that meant decommissioning dify and resizing the
  quota (derivation in `namespace.yaml`).
- Green starts cold: its first minute's P99 is higher (JIT). Warm green
  before switching — this page waits 30 s; production would replay traffic
  or mirror to it (scenario 13) first.
- Both colours share one database schema, so v2 cannot ship an
  incompatible migration. Blue-green switches code, not data — the schema
  must be compatible with both (expand/contract).

## Reset
The page's last revert scales green back to 0. `demo-reset blue-green`
waits for the five green pods to terminate and verifies the baseline.
