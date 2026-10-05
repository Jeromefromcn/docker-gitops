# 11 — Header / cookie gray release (A/B)

## Purpose
Send only chosen users to v2 — testers with a header, a cohort with a
cookie — while everyone else stays on v1, and show where a routing header
stops working.

## Preconditions
Preflight passed; 10 reset.

## Commands
```bash
# Bring the checkout up to date with origin/main
git pull --ff-only origin main

# Apply the scenario's prepared manifest patch to the working tree
git apply k3s/apps/lab-environment/demo/patches/header-canary.patch

# Review the change before committing it
git --no-pager diff

# Commit to main with the demo: prefix
git commit -m "demo: route marked requests to the customers-service canary" -- k3s/apps/lab-environment/k8s

# Push to main; ArgoCD deploys from git
git push || echo "PUSH FAILED - stop here"

# Make ArgoCD re-read git now instead of waiting for its next poll
argocd app get lab-environment --core --refresh >/dev/null

# Wait (up to 5 min) until ArgoCD has synced this commit successfully
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done

# Wait until the customers-service-canary rollout completes
kubectl -n lab-environment rollout status deploy/customers-service-canary --timeout=6m

# Lab ingress (lab-ingress-istio NodePort on vps_oracle)
U=http://10.0.0.95:30097

# Ready is not yet routable: wait until both waypoint replicas have the canary
# endpoint - 10 marked requests in a row answered by v2.
end=$((SECONDS + 120)); ok=0; until [ $ok -ge 10 ]; do [ $SECONDS -lt $end ] || { echo "ROUTE WAIT TIMED OUT - stop here"; break; }; if curl -s -o /dev/null -D- -H 'x-canary: true' $U/api/customer/owners/1 | grep -qi '^x-app-version'; then ok=$((ok + 1)); else ok=0; fi; sleep 0.5; done

sleep 20   # quiet gap: keeps the warm-up out of the window's log lines and its first metrics sample

# Open the evidence window: every evidence query is bounded by it
demo-window start header-canary

# 20 requests with the x-canary header; expect all on v2
echo "header:";   for i in $(seq 1 20); do curl -s -o /dev/null -D- -H 'x-canary: true' $U/api/customer/owners/1 | tr -d '\r' | awk -F': ' 'tolower($1)=="x-app-version"{v=$2} END{print (v ? v : "none (v1)")}'; done | sort | uniq -c

# 20 requests with the canary cookie; expect all on v2
echo "cookie:";   for i in $(seq 1 20); do curl -s -o /dev/null -D- -b 'canary=1' $U/api/customer/owners/1 | tr -d '\r' | awk -F': ' 'tolower($1)=="x-app-version"{v=$2} END{print (v ? v : "none (v1)")}'; done | sort | uniq -c

# 20 unmarked requests; expect all on v1
echo "unmarked:"; for i in $(seq 1 20); do curl -s -o /dev/null -D- $U/api/customer/owners/1 | tr -d '\r' | awk -F': ' 'tolower($1)=="x-app-version"{v=$2} END{print (v ? v : "none (v1)")}'; done | sort | uniq -c

# 10 marked requests via the gateway's aggregation path: the gateway drops the header, so these land on stable
echo "aggregation path, with header:"; for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code}\n' -H 'x-canary: true' $U/api/gateway/owners/1; done | sort | uniq -c

sleep 10   # Envoy flushes its access log in batches: let the window's last lines land inside it

# Close the evidence window
demo-window stop header-canary

# Run the evidence queries for the window; ends with a Grafana link
demo-evidence header-canary

# Roll back: revert the demo commit
git revert --no-edit HEAD

# Push to main; ArgoCD deploys from git
git push || echo "PUSH FAILED - stop here"

# Make ArgoCD re-read git now instead of waiting for its next poll
argocd app get lab-environment --core --refresh >/dev/null

# Wait (up to 5 min) until ArgoCD has synced this commit successfully
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
```

## Expected result
header: `20 c44d33230743`; cookie: `20 c44d33230743`; unmarked:
`20 none (v1)`; aggregation path: `10 200`. The evidence shows exactly 40
requests on the canary subset and 40 counted by the canary pod.

## Evidence
- **Envoy (waypoint access log):** requests per subset — the canary count
  equals the number of marked requests exactly (the traffic generator
  sends neither mark, so nothing else can reach the canary).
- **App (Spring metrics):** the canary pod's own request count.

## Talking points
- The VirtualService rule order is the policy: the marked-request rule sits
  first; everything else falls through to the stable pin.
- **Where it breaks:** `/api/customer/**` is proxied by the gateway as-is,
  headers included, so the mark reaches the waypoint in front of
  customers-service. `/api/gateway/owners/{id}` makes *new* requests from
  the gateway's own code and drops it — those calls land on stable. A
  routing header only works across hops if every app propagates it; that
  is sub-project 3's lane work (Micrometer baggage).
- Cookie-based routing is how an A/B cohort sticks to one variant across
  requests; the header is how a tester opts in.
- **Ready is not routable yet.** `rollout status` returns when the pod is
  Ready; the waypoint learns the new endpoint a moment later. In the first
  rehearsal (2026-09-28) the three marked requests sent in that gap got
  `503 UH` (no healthy upstream in the canary subset), and the second
  rehearsal showed the two waypoint replicas learn it independently — hence
  "10 in a row" before the window. The quiet gaps on both sides of the
  window are what make an *exact* count possible: access-log lines land
  1-2 s after the request, and Prometheus samples every 15 s. A header route to a subset with no
  endpoints fails; it does not fall back to stable.

## Reset
The page's revert undoes it. `demo-reset header-canary` waits for the
canary pod to go and verifies the baseline.
