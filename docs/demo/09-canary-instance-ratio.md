# 09 — Canary by instance ratio

## Purpose
Release v2 of customers-service to a share of traffic the way plain
Kubernetes does it: add one v2 pod next to five v1 pods behind the same
Service. The share is whatever the pod count makes it: 1 of 6.

## Preconditions
Preflight passed: the canary slot `customers-service-canary` is at
`replicas: 0` and the VirtualService pins customers-service to the
`stable` subset. Working tree clean.

## Before you start: open the views
1. **ArgoCD — the `lab-environment` app**, tree view, name filter
   `customers-service`:
   <https://argocd.jerome.cloudns.asia/applications/argocd/lab-environment>
   Two Deployments: `customers-service` with five pods and
   `customers-service-canary` with none.
2. **Grafana — Lab Endpoint Detail for `GET /owners/{ownerId}`**, the
   endpoint the traffic generator calls, last 15 minutes, auto-refresh 10 s:
   <https://grafana.lab.jerome.cloudns.asia/d/lab-endpoint-detail/lab-endpoint-detail?var-service=customers-service&var-method=GET&var-uri=%2Fowners%2F%7BownerId%7D&var-window_s=60&from=now-15m&to=now&refresh=10s>
   Scroll to **Per instance**: five pods.
3. **Grafana — Explore**, data source **Loki**, last 5 minutes, **Query
   type Instant**. The waypoint logs the `X-App-Version` response header,
   which only the v2 build sends:
   ```logql
   sum by (app_version) (count_over_time({service="istio-proxy"} | json | authority=~"customers-service.*" [2m]))
   ```
   Run it: one unlabeled row. Every response came from v1.

## Steps

### 1. Add one v2 pod and drop the subset pin
```bash
# Bring the checkout up to date with origin/main
git pull --ff-only origin main
```
Make two edits in the editor:

- `k3s/apps/lab-environment/k8s/customers-service-canary.yaml`: change
  `replicas: 0` to `replicas: 1`. The image is already the v2-good build
  (`# fork c44d33230743`).
- `k3s/apps/lab-environment/k8s/resilience.yaml`, in the
  `customers-service` VirtualService: delete both `subset: stable` lines,
  one under each route. Without a subset the waypoint balances across
  every pod the Service selects, v1 and v2 alike.

```bash
# Review: replicas 0 -> 1, and two "subset: stable" lines removed
git diff

# Commit to main with the demo: prefix
git commit -m "demo: canary customers-service by instance ratio (5 + 1)" -- k3s/apps/lab-environment/k8s

# Push; ArgoCD deploys from git
git push
```
In ArgoCD, click **Refresh**. A pod appears under
`customers-service-canary`. It is Ready after ~70 s (JVM startup).

### 2. Send traffic and see who answers
```bash
# 120 requests; print which build answered (v2 sends X-App-Version, v1 sends nothing)
for i in $(seq 1 120); do curl -s -o /dev/null -w '%header{x-app-version}\n' http://10.0.0.95:30097/api/customer/owners/1; sleep 0.3; done | sort | uniq -c
```
About 100 blank lines (v1) and 20 `c44d33230743` (v2): about 1 in 6.

### 3. The same share from the platform's side
- **Loki** (run the query again): a second row,
  `app_version="c44d33230743"`, about a sixth of the total. This is the
  waypoint's record of which build answered.
- **Grafana, Per instance**: six pods now. The canary pod
  (`customers-service-canary-…`) carries about a sixth of the calls in
  **Calls per instance (now, Window)**. The generator's traffic is split
  the same way: every request has the same chance of landing on any of
  the six pods.

### 4. Roll back
```bash
# Roll back: revert the demo commit
git revert --no-edit HEAD

# Push; ArgoCD deploys the rollback
git push
```
In ArgoCD, click **Refresh**. The canary pod terminates. The Loki query
falls back to one unlabeled row once the 2-minute range has passed.

## Talking points
- No mesh feature is involved: removing the subset pin lets the waypoint
  balance across all six endpoints of the Service. This is the canary
  every Kubernetes cluster can do.
- Its limit: the share is tied to replica counts. 10 % needs 9 v1 pods per
  v2 pod; 1 % needs 99. Scenario 10 decouples the two.
- v1 pods answer without `X-App-Version`. That header is the v2 build's
  change (the commit id, which is also the image tag), and the waypoint
  logs it as `app_version`. So the version that answered is on the
  platform's record, not only the client's.
- Canary pods reuse stable's ServiceAccount, so every identity-based
  AuthorizationPolicy already covers them — a new version needs no new
  policy.

## Reset
The page's `git revert` undoes it. Before the next page, check that the
canary pod is gone:
```bash
# Expect only the five customers-service pods, all track=stable
kubectl -n lab-environment get pods -l app=customers-service -L track
```
