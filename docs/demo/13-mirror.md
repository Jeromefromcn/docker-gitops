# 13 — Traffic mirroring

## Purpose
Test v2 against real production traffic without any user depending on its
answer: every GET is copied to the canary and its response thrown away.
This is the same bad build as 10, and this time no user gets a 500.

## Preconditions
Preflight passed; 11 reset (no canary pod).

## Before you start: open the views
1. **ArgoCD — the `lab-environment` app**, tree view, name filter
   `customers-service`:
   <https://argocd.jerome.cloudns.asia/applications/argocd/lab-environment>
2. **Grafana — Explore**, data source **Prometheus**, last 15 minutes,
   **Query type Range**. The waypoint's own counter of responses per
   upstream cluster (stable subset, canary subset) and status class:
   ```promql
   sum by (cluster_name, response_code_class) (rate(envoy_cluster_upstream_rq{job="envoy-stats", cluster_name=~".*customers-service.*"}[1m]))
   ```
   Lines for `http/stable … 2xx` above zero. Nothing for the canary. A
   line flat at 0 with no subset (`http|customers-service…`) is left over
   from scenario 09, which routed without one.
3. **Grafana — Explore** in a second tab (split view works too), data
   source **Loki**, last 5 minutes, **Query type Instant**. What users got:
   ```logql
   sum by (app_version, response_code) (count_over_time({service="istio-proxy"} | json | authority=~"customers-service.*" [2m]))
   ```

## Steps

### 1. Mirror every GET to the bad build
```bash
# Bring the checkout up to date with origin/main
git pull --ff-only origin main
```
Make three edits in the editor.

`k3s/apps/lab-environment/k8s/customers-service-canary.yaml`:
- `replicas: 0` → `replicas: 1`
- Replace the container's `image:` line with the v2-bad build:
  ```yaml
          image: ghcr.io/jeromefromcn/petclinic-customers-service@sha256:51479efaae977a7069e05836180344281910c9531808646fc05fcb638a32c315 # fork 77962eada66c
  ```

`k3s/apps/lab-environment/k8s/resilience.yaml`, `customers-service`
VirtualService, the **GET** rule only. Its route keeps `subset: stable`.
Below the route, before `timeout: 3s`, add:
```yaml
      # Shadow every GET to the canary; its responses are discarded. GET
      # only: both versions share one database, so a mirrored POST would
      # write twice.
      mirror:
        host: customers-service.lab-environment.svc.cluster.local
        subset: canary
      mirrorPercentage:
        value: 100
```

```bash
# Review: replicas, image, and a mirror on the GET rule
git diff

# Commit to main with the demo: prefix
git commit -m "demo: mirror customers-service GETs to v2-bad" -- k3s/apps/lab-environment/k8s

# Push; ArgoCD deploys from git
git push
```
In ArgoCD, click **Refresh**, and wait until the canary pod is Ready
(~70 s).

### 2. Send traffic at a two-pet owner
```bash
# 60 GETs for owner 3: users get 200 from stable while the mirrored copies fail on the canary
for i in $(seq 1 60); do curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30097/api/customer/owners/3; sleep 0.5; done | sort | uniq -c
```
`60 200`. Not one user saw the bug.

### 3. The copies, seen by the waypoint (infrastructure layer)
Refresh the **Prometheus** query. Two new lines:
- `http/canary … 2xx`. The canary answers the mirrored copies for owners
  with zero or one pet. It takes as many requests as stable does: the
  mirror copies 100 % of GETs.
- `http/canary … 5xx`. The copies for owners 3, 6 and 10 fail, from the
  generator and from your loop. Envoy counts these responses and then
  throws them away.

`http/stable … 5xx` stays at zero.

### 4. What users got
Refresh the **Loki** query. There is no row with
`app_version="77962eada66c"`: no user response came from the canary. The
access log records the request Envoy served, not the shadow copy, which is
why step 3 reads the per-cluster counter instead.

The canary's own log shows what the copies hit:
```logql
{pod_name=~"customers-service-canary-.*"} |= "more than one pet"
```
`Could not write JSON: owner 3 has more than one pet`. This is the same
bug as in 10, found with no user exposed to it.

### 5. Roll back
```bash
# Roll back: revert the demo commit
git revert --no-edit HEAD

# Push; ArgoCD deploys the rollback
git push
```
In ArgoCD, click **Refresh**. The canary pod terminates and the canary
lines in the Prometheus query drop to zero.

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
The page's revert undoes it. Before the next page, check that the canary
pod is gone:
```bash
# Expect only the five customers-service pods, all track=stable
kubectl -n lab-environment get pods -l app=customers-service -L track
```
