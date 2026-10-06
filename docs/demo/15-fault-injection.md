# 15 — Header-triggered fault injection

## Purpose
Inject a delay and an abort into customers-service for marked requests
only, and show the blast radius is exactly those requests: the waypoint
fakes the failure, no pod is touched, and everyone else is served
normally.

## Preconditions
Preflight passed; 14 reset (chaos toggle `false`). The traffic generator
never sends `x-fault`, so every injected fault on screen is yours.

## Before you start: open the views
1. **Grafana — Lab Mesh Overview**, last 15 minutes, auto-refresh 10 s:
   <https://grafana.lab.jerome.cloudns.asia/d/lab-mesh-overview/lab-mesh-overview?from=now-15m&to=now&refresh=10s>
   - **Envoy response flags**: requests the waypoint marked with a flag.
     `DI` is delay injected and `FI` is fault (abort) injected. No such
     lines yet.
   - **Mesh requests by service and code (waypoint)**.
2. **Grafana — Explore**, data source **Loki**, last 5 minutes, **Query
   type Instant**. customers-service requests by Envoy's response flag and
   status:
   ```logql
   sum by (response_flags, response_code) (count_over_time({service="istio-proxy"} | json | authority=~"customers-service.*" [5m]))
   ```
   One row: `response_flags="-"` (no flag), `200`.

## Steps

### 1. Add the fault rules
```bash
# Bring the checkout up to date with origin/main
git pull --ff-only origin main
```
In `k3s/apps/lab-environment/k8s/resilience.yaml`, `customers-service`
VirtualService, add these two rules as the **first** entries under
`http:`, above the `GET` rule. Each copies the GET rule's route and retry
policy and adds a `fault`:
```yaml
    # Demo-only fault injection (docs/demo/15): requests carrying x-fault get
    # a delay or an abort; everything else falls through to the stable pin.
    - match:
        - headers:
            x-fault:
              exact: delay
      fault:
        delay:
          percentage:
            value: 100
          fixedDelay: 2s
      route:
        - destination:
            host: customers-service.lab-environment.svc.cluster.local
            subset: stable
      timeout: 3s
      retries:
        attempts: 2
        perTryTimeout: 1s
        retryOn: connect-failure,refused-stream,unavailable,503
    - match:
        - headers:
            x-fault:
              exact: abort
      fault:
        abort:
          percentage:
            value: 100
          httpStatus: 503
      route:
        - destination:
            host: customers-service.lab-environment.svc.cluster.local
            subset: stable
      timeout: 3s
      retries:
        attempts: 2
        perTryTimeout: 1s
        retryOn: connect-failure,refused-stream,unavailable,503
```

```bash
# Review: two new rules at the top of the VirtualService
git diff

# Commit to main with the demo: prefix
git commit -m "demo: inject faults into customers-service for marked requests" -- k3s/apps/lab-environment/k8s

# Push; ArgoCD deploys from git
git push
```
In ArgoCD, click **Refresh** and wait for `Synced`.

### 2. Wait until the route is live
Each of the two waypoint replicas picks up the new rules on its own.
```bash
# Lab ingress (lab-ingress-istio NodePort on vps_oracle)
U=http://10.0.0.95:30097

# Send abort requests until 10 in a row are aborted
n=0; until [ $n -ge 10 ]; do c=$(curl -s -o /dev/null -w '%{http_code}' -H 'x-fault: abort' $U/api/customer/owners/1); [ "$c" != 200 ] && n=$((n+1)) || n=0; sleep 0.5; done; echo "route live"
```

### 3. Marked and unmarked requests
```bash
# 10 requests with x-fault: delay; expect 200 after ~2 s
for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -H 'x-fault: delay' $U/api/customer/owners/1; done

# 10 requests with x-fault: abort; expect fast 503s
for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -H 'x-fault: abort' $U/api/customer/owners/1; done

# 10 unmarked requests; expect 200
for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code}\n' $U/api/customer/owners/1; done | sort | uniq -c
```
delay: ten lines `200 2.0…s`. abort: ten lines `503`, each in a few
milliseconds. unmarked: `10 200`.

### 4. What the waypoint recorded
Run the Loki query again. New rows:
- `response_flags="DI"`, `200`: the delayed requests. They were held for
  2 s and then served normally.
- `response_flags="FI"`, `503`: the aborts, the 10 in step 3 plus the
  warm-up in step 2. The waypoint answered these itself.

Every other row is still `-` / `200`. The generator's requests, hundreds
of them, were not touched.

On **Lab Mesh Overview**, the **Envoy response flags** panel now has a
`customers-service DI` line and an `unknown FI` line. The aborts show
under `unknown` because the waypoint answered before the request was
handed to any destination.

### 5. No pod was touched
The aborts never reached a pod. Explore, **Prometheus**, **Query type
Instant**:
```promql
sum by (response_code_class) (increase(envoy_cluster_upstream_rq{job="envoy-stats", cluster_name=~".*http/stable.*customers-service.*"}[5m]))
```
`5xx` is 0. Envoy counts upstream responses per cluster, and no upstream
ever returned a 5xx. The 503s in step 3 were made in the waypoint.

### 6. Roll back
```bash
# Roll back: revert the demo commit
git revert --no-edit HEAD

# Push; ArgoCD deploys the rollback
git push
```
In ArgoCD, click **Refresh**. A request with `x-fault: abort` returns
`200` again.

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
The page's revert undoes it.
