# 15 — Header-triggered fault injection

## Purpose
Inject a delay and an abort into customers-service for marked requests only,
and show the blast radius is exactly those requests: the waypoint fakes the
failure, no pod is touched, and everyone else is served normally.

## Preconditions
Preflight passed; 14 reset.

## Commands
```bash
git pull --ff-only origin main
git apply k3s/apps/lab-environment/demo/patches/fault-injection.patch
git --no-pager diff
git commit -m "demo: inject faults into customers-service for marked requests" -- k3s/apps/lab-environment/k8s
git push || echo "PUSH FAILED - stop here"
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
U=http://10.0.0.95:30097
# Both waypoint replicas must have the new route before the window opens.
end=$((SECONDS + 120)); ok=0; until [ $ok -ge 10 ]; do [ $SECONDS -lt $end ] || { echo "ROUTE WAIT TIMED OUT - stop here"; break; }; if [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'x-fault: abort' $U/api/customer/owners/1)" != 200 ]; then ok=$((ok + 1)); else ok=0; fi; sleep 0.5; done
sleep 20   # quiet gap: keeps the warm-up out of the window
demo-window start fault-injection
echo "delay:";    for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -H 'x-fault: delay' $U/api/customer/owners/1; done
echo "abort:";    for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code}\n' -H 'x-fault: abort' $U/api/customer/owners/1; done | sort | uniq -c
echo "unmarked:"; for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code}\n' $U/api/customer/owners/1; done | sort | uniq -c
sleep 10   # let the window's last access-log lines land inside it
demo-window stop fault-injection
demo-evidence fault-injection
git revert --no-edit HEAD
git push || echo "PUSH FAILED - stop here"
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
demo-reset fault-injection
```

## Expected result
delay: ten lines `200 2.02s` (± a few ms); abort: `10 503`, each in under
20 ms; unmarked: `10 200`. Reset prints `baseline OK`.

## Evidence
- **Envoy (waypoint access log):** exactly 10 requests with `response_flags`
  `DI` (delay injected) and 10 with `FI` (fault injected) — the marked ones,
  no more.
- **Envoy (stats):** the customers-service cluster's upstream 5xx counter
  does not move — the 10 aborts never reached a pod.
- **App:** the traffic generator saw no non-200 in the window.

## Talking points
- **Blast radius = the marked requests.** The traffic generator never sends
  `x-fault`, and the rule sits first in the VirtualService; everything else
  falls through to the stable pin. This is how you test a client's timeout
  handling in production without hurting anyone else.
- **The header only works on `/api/customer/**`**: the gateway proxies that
  path as-is, headers included. `/api/gateway/owners/{id}` makes new calls
  from the gateway's own code and drops it (11).
- **The delay is not cut by the timeouts on the same rule** (measured
  2026-09-29): 2 s injected, 1 s `perTryTimeout`, yet every delayed request
  returns `200` after 2.02 s, logged `DI` alone with `attempts=1`. The fault
  filter runs before the router, so the per-try timer only starts once the
  delay is over. A delay tests the *caller's* timeout, not the mesh's.
- **A local abort is not retried** (measured): `503` is in `retryOn`, yet
  each abort is logged `FI` with `attempts=0` and returns in milliseconds —
  the router, which owns retries, never saw the request.
- **An abort never reaches a pod**, so it cannot trip outlier detection.
  That is why 14 needed a real bad pod (the fork's `fail-instance` toggle)
  instead of an injected 503.

## Reset
The page's revert undoes it. `demo-reset fault-injection` verifies the
routing baseline, which names a leftover `fault` rule if the revert was not
pushed.
