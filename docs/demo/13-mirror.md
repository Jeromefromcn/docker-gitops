# 13 — Traffic mirroring

## Purpose
Test v2 against real production traffic without any user depending on its
answer: every GET is copied to the canary and its response thrown away.
The same bad build as 10 — and this time no user gets a 500.

## Preconditions
Preflight passed; 11 reset.

## Commands
```bash
git pull --ff-only
git apply k3s/apps/lab-environment/demo/patches/mirror.patch
git --no-pager diff
git commit -m "demo: mirror customers-service GETs to v2-bad" -- k3s/apps/lab-environment/k8s
git push || echo "PUSH FAILED - stop here"
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
kubectl -n lab-environment rollout status deploy/customers-service-canary --timeout=6m
demo-window start mirror
for i in $(seq 1 60); do curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30097/api/customer/owners/3; sleep 0.5; done | sort | uniq -c
demo-window stop mirror
demo-evidence mirror
kubectl -n lab-environment logs deploy/customers-service-canary --since=5m | grep -m3 'more than one pet'
git revert --no-edit HEAD
git push || echo "PUSH FAILED - stop here"
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
```

## Expected result
`60 200`. The evidence shows the canary cluster returning 5xx to the
mirrored copies, no user request routed to the canary, the canary pod's
own 500s, and the generator all 200. The canary's log shows
`IllegalStateException: owner 3 has more than one pet`.

## Evidence
- **Envoy (waypoint cluster stats):** 5xx on the canary subset's cluster
  (`envoy_cluster_upstream_rq{response_code_class="5xx"}`); the access log
  shows every user request served by stable.
- **App:** the canary pod's own 500 count; the generator's log all 200.

## Talking points
- Mirroring is fire-and-forget: Envoy does not wait for the shadow and
  discards its response, so v2's latency and errors cost the user nothing.
- **The access log does not show the shadow.** Envoy logs the request it
  served, not the copy; the only platform record of the mirrored call is
  the per-cluster response counter — which is why the waypoint exports
  `upstream_rq_<class>xx` per cluster (measured while building this demo).
- **GET only, on purpose:** both versions share one database. Mirroring a
  POST would create every owner twice. Mirroring writes needs a separate
  data store — the reason teams often mirror only reads.
- The shadow gets 100 % of read load: size the canary for it.
- Compare 10: the same bug cost ~10 % of users there, zero here. The price
  is that a mirror cannot tell you how users *react* to v2 — only whether
  it breaks.

## Reset
The page's revert undoes it. `demo-reset mirror` waits for the canary pod to
go and verifies the baseline.
