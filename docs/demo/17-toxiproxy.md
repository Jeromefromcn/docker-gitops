# 17 — Network faults on a dependency (Toxiproxy)

## Purpose
Put Toxiproxy between visits-service and its data stores, then make the
network misbehave — first slow Redis, then a black hole in front of
Postgres — and show the mesh's 1 s per-try timeout answering for the caller
while the app keeps waiting on its own, far longer, timeouts.

## Preconditions
Preflight passed; 15 reset. Costs two visits-service rollouts (in and out).

## Commands
```bash
git pull --ff-only
git apply k3s/apps/lab-environment/demo/patches/toxiproxy.patch
git --no-pager diff
git commit -m "demo: route visits-service's data stores through toxiproxy" -- k3s/apps/lab-environment/k8s
git push || echo "PUSH FAILED - stop here"
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
kubectl -n lab-environment rollout status deploy/toxiproxy --timeout=3m
kubectl -n lab-environment rollout status deploy/visits-service --timeout=6m
T="kubectl -n lab-environment exec deploy/toxiproxy -- /toxiproxy-cli"
U=http://10.0.0.95:30097/api/customer/owners
$T list
# visits just restarted: a cold JVM's first requests can take over 1 s and
# would 504 before any toxic. Warm it on owners the steps below do not use
# (3, 5, 7 must stay out of the 60 s Redis cache).
for i in $(seq 1 10); do curl -s -o /dev/null $U/6/visits; curl -s -o /dev/null $U/9/visits; done
demo-window start toxiproxy
echo "through the proxy, no toxic:"; for i in 1 2 3; do curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' $U/6/visits; done
$T toxic add -t latency -a latency=1500 redis
echo "redis +1.5 s:";             for i in 1 2 3; do curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' $U/6/visits; done
$T toxic remove -n latency_downstream redis
$T toxic add -t timeout -a timeout=0 postgres
# Owners the traffic generator never reads: their visits are not in the
# 60 s Redis cache, so the request really goes to Postgres.
echo "postgres black hole:";      for o in 3 5 7; do curl -s -o /dev/null -w "owner $o %{http_code} %{time_total}s\n" $U/$o/visits; done
$T toxic remove -n timeout_downstream postgres
echo "toxic removed:";            for o in 3 5 7; do curl -s -o /dev/null -w "owner $o %{http_code} %{time_total}s\n" $U/$o/visits; done
kubectl -n istio-system logs "$(kubectl -n istio-system get pods -l app=ztunnel --field-selector spec.nodeName=vps-oracle2 -o name)" --since=3m | grep -c 'src.identity="spiffe://cluster.local/ns/lab-environment/sa/toxiproxy".*dst.service="postgres'
sleep 10   # let the window's last access-log lines land inside it
demo-window stop toxiproxy
demo-evidence toxiproxy
git revert --no-edit HEAD
git push || echo "PUSH FAILED - stop here"
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
demo-reset toxiproxy
```

## Expected result
- `list`: two proxies, `postgres` and `redis`, no toxics.
- No toxic: `200` in ~0.2 s.
- Redis +1.5 s: `504` at ~1.01 s (occasionally a fast `502` — Envoy logs
  `503 UC` on visits: the connection the timed-out request left behind was
  closed under the next one).
- Postgres black hole: `504` at ~1.01 s for owners 3, 5, 7.
- Toxic removed: `200` at once — no rollout needed.
- ztunnel: a non-zero count of connections from `sa/toxiproxy` to postgres.
- Reset prints `baseline OK`.

## Evidence
- **Envoy (waypoint access log):** `UT` (upstream per-try timeout, 1 s)
  logged against visits-service.
- **App (Spring metrics):** visits-service's slowest request in the window,
  well above 1 s — it kept working after the mesh had already answered 504.
  (Rehearsal 2026-09-29: 6.5 s, ending `200` for a client long gone.)

## Talking points
- **Network faults vs 05's toggle.** 05's chaos is the app cooperating
  (`redis-timeout` makes it throw on purpose). Here the app opted into
  nothing: it just finds its network slow or silent.
- **The mesh is the backstop.** visits' own Redis timeout is 2 s and
  Hikari waits 30 s for a connection; the waypoint's 1 s `perTryTimeout`
  answers the caller long before either. The app, meanwhile, keeps the
  thread and the connection busy — the slowest request in the evidence.
  504/UT is not in `retryOn`, so there is one attempt, not three.
- **Recovery without a restart.** When the black hole is removed, Hikari
  fails validation on the stalled connections, drops them and opens new
  ones — the next request is already `200`.
- **Least privilege is weaker for exactly as long as the demo lasts.** While
  the proxy sits in the path, Postgres and Redis see toxiproxy's identity,
  not visits': the patch grants `sa/toxiproxy` on both. The revert takes
  the grant away, and `demo-reset` refuses to call the lab healthy while
  either policy still admits it or visits still points at the proxy.
- **Ready is not warm.** visits' first requests after the rollout can take
  over 1 s (cold JVM) and hit the same 504 the toxics produce — hence the
  warm-up before the window (rehearsal 2026-09-29, twice: one 504 before
  any toxic without it).
- **Toxiproxy is not resident in the data path** — production would not
  have it. It stays deployed with its own (unprivileged) identity; only the
  wiring is temporary.

## Reset
The page's revert undoes the wiring and the grant (one more visits
rollout). `demo-reset toxiproxy` waits for that rollout and verifies the
baseline, including the toxiproxy checks.
