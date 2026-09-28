# 09 — Canary by instance ratio

## Purpose
Release v2 of customers-service to a share of traffic the way plain
Kubernetes does it: add one v2 pod next to five v1 pods behind the same
Service. The share is whatever the pod count makes it — 1 of 6.

## Preconditions
Preflight passed (`demo-reset preflight` → `baseline OK`; the canary slot is empty).

## Commands
```bash
git pull --ff-only
git apply k3s/apps/lab-environment/demo/patches/canary-instance-ratio.patch
git diff
git commit -m "demo: canary customers-service by instance ratio (5 + 1)" -- k3s/apps/lab-environment/k8s
git push || echo "PUSH FAILED - stop here"
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
kubectl -n lab-environment rollout status deploy/customers-service-canary --timeout=6m
demo-window start canary-instance-ratio
for i in $(seq 1 120); do curl -s -o /dev/null -D- http://10.0.0.95:30097/api/customer/owners/1 | tr -d '\r' | awk -F': ' 'tolower($1)=="x-app-version"{v=$2} END{print (v ? v : "none (v1)")}'; sleep 0.3; done | sort | uniq -c
demo-window stop canary-instance-ratio
demo-evidence canary-instance-ratio
git revert --no-edit HEAD
git push || echo "PUSH FAILED - stop here"
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
```

## Expected result
Roughly 100 `none (v1)` and 20 `ce942c9e7124` (the v2-good build) — about
1 in 6. The evidence shows the canary pod's share at 8-30 % in both the
waypoint's log and the pod's own request count.

## Evidence
- **Envoy (waypoint access log):** customers-service requests by
  `upstream_host`, the canary pod's IP picked out — its share of the total.
- **App (Spring metrics):** the canary pod's request count over the window
  as a share of all customers-service pods.

## Talking points
- No mesh feature is involved: the patch removes the VirtualService's
  subset pin, so the waypoint balances across all six endpoints of the
  Service. This is the canary every Kubernetes cluster can do.
- Its limit: the share is tied to replica counts. 10 % needs 9 v1 pods per
  v2 pod; 1 % needs 99. Scenario 10 decouples the two.
- v1 pods answer without `X-App-Version` — that header is the v2 build's
  change (the commit id, which is also the image tag), and the waypoint
  logs it as `app_version`, so the version that answered is on the
  platform's record, not only the client's.
- Canary pods reuse stable's ServiceAccount, so every identity-based
  AuthorizationPolicy already covers them — a new version needs no new
  policy.

## Reset
The page's `git revert` undoes it. `demo-reset canary-instance-ratio` waits
for the canary pod to terminate and verifies the baseline, including the
stable pin.
