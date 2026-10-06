# 12 — Blue-green switch

## Purpose
Bring up a complete second copy of customers-service (green, v2, five pods
like blue), move all traffic to it in one step, and move it back in one
step, with no user-visible error either way.

## Preconditions
Preflight passed; 13 reset (no canary pod). The lab memory quota (9.25Gi)
was sized for a five-pod green alongside a full release; dify was
decommissioned on vps-oracle2 to make room. No PR lane pod (18): a lane
uses the same memory headroom as the green.

## Before you start: open the views
1. **ArgoCD — the `lab-environment` app**, tree view, name filter
   `customers-service`:
   <https://argocd.jerome.cloudns.asia/applications/argocd/lab-environment>
2. **Grafana — Explore**, data source **Loki**, last 30 minutes, **Query
   type Range**, auto-refresh 10 s. Requests through the waypoint to
   customers-service over time, one line per build that answered. Blue
   (v1) sends no version header, so its line has no label:
   ```logql
   sum by (app_version) (count_over_time({service="istio-proxy"} | json | authority=~"customers-service.*" [30s]))
   ```
3. **Grafana — Lab Mesh Overview**, last 30 minutes, auto-refresh 10 s:
   <https://grafana.lab.jerome.cloudns.asia/d/lab-mesh-overview/lab-mesh-overview?from=now-30m&to=now&refresh=10s>
   **customers-service RPS per pod**: five blue pods.

## Steps

### 1. Bring up green
```bash
# Bring the checkout up to date with origin/main
git pull --ff-only origin main
```
In `k3s/apps/lab-environment/k8s/customers-service-canary.yaml`, change
`replicas: 0` to `replicas: 5`. The image is v2-good (`# fork
c44d33230743`). This is the green: a full second copy, not a canary.

```bash
# Review: one line, 0 -> 5
git diff

# Commit to main with the demo: prefix
git commit -m "demo: bring up green customers-service (5 x v2)" -- k3s/apps/lab-environment/k8s

# Push; ArgoCD deploys from git
git push
```
In ArgoCD, click **Refresh**. Five pods appear under
`customers-service-canary`, one at a time, ~3 minutes in all.

```bash
# Blue and green side by side (track label)
kubectl -n lab-environment get pods -l app=customers-service -L track

# The memory requests used against the namespace quota
kubectl -n lab-environment describe resourcequota lab-environment-quota | grep requests.memory
```
Ten pods, five `stable` and five `canary`. Green takes no traffic yet: the
Loki graph still has only the unlabeled line, and the RPS-per-pod panel
shows the new pods at zero.

### 2. Switch to green
Only when all five green pods are Ready (`5/5` under
`customers-service-canary` in ArgoCD). A switch onto a subset with no
ready pods would fail every request.

In `k3s/apps/lab-environment/k8s/resilience.yaml`, `customers-service`
VirtualService, change both `subset: stable` lines to `subset: canary`.

```bash
# Review: two lines, stable -> canary
git diff

# Commit the switch to main with the demo: prefix
git commit -m "demo: switch customers-service to green" -- k3s/apps/lab-environment/k8s

# Push; ArgoCD deploys from git
git push
```
In ArgoCD, click **Refresh**. Then watch:
- **Loki graph**: a `c44d33230743` line rises as the unlabeled (blue)
  line falls to zero. It is not a single step. The waypoint applies the
  new route to new connections at once, but api-gateway's existing
  keep-alive connections finish on the old route until Envoy's 45 s drain
  ends.
- **RPS per pod**: the traffic moves from the five blue pods to the five
  green pods.

```bash
# 20 requests: every response should now carry the v2 build
for i in $(seq 1 20); do curl -s -o /dev/null -w '%header{x-app-version}\n' http://10.0.0.95:30097/api/customer/owners/1; sleep 1; done | sort | uniq -c
```
`20 c44d33230743`.

### 3. Switch back
```bash
# Roll back: revert the switch, traffic returns to blue
git revert --no-edit HEAD

# Push; ArgoCD deploys from git
git push
```
In ArgoCD, click **Refresh**. The Loki graph mirrors step 2: the unlabeled
line comes back and the green line falls to zero within ~45 s.

### 4. No user saw either switch
Explore, Loki, last 30 minutes, **Query type Instant**:
```logql
sum by (code) (count_over_time({service="traffic-generator"} | regexp `^\S+ (?P<code>\d{3}) ` [30m]))
```
Expect one row, `code="200"`: the generator called the lab every half
second through both switches.

This is not guaranteed to be zero. The first rehearsal (2026-09-28) had
0 errors in 523 requests. The 2026-10-06 rehearsal had 2 errors, both
within 15 s of the switch to green. To see them:
```logql
{service="istio-proxy"} | json | response_code=~"5.." | authority=~"customers-service.*"
```
Both were `503` with `response_flags="UC"` on the canary (green) subset:
the waypoint's connection to a green pod was closed under the request.
One reached the generator as a 503, and the other as a 500 through the
gateway's aggregation path. The GET route's `retryOn` does not include
`reset`, so the waypoint does not retry this.

### 5. Tear down green
```bash
# Tear down green: revert the bring-up commit
git revert --no-edit $(git log -1 --grep='^demo: bring up green customers-service' --format=%H)

# Push; ArgoCD deploys from git
git push
```
In ArgoCD, click **Refresh**: the five green pods terminate. In **History
and rollback** the four commits are listed in order: bring up, switch,
switch back, tear down.

## Talking points
- The switch is one field in git (`subset: stable` → `canary`), and the
  rollback is the same size. **It is not instantaneous per connection:**
  the waypoint's routes live in its listener, so an update reaches new
  connections at once, while existing keep-alive connections (the
  gateway's pool) finish on the old route until Envoy's 45 s drain ends.
  Measured in the first rehearsal (2026-09-28): one request still reached
  green 28 s after the rollback had synced.
- **Cost:** double capacity for the duration — five more JVMs, 1920Mi of
  requests. On this node that meant decommissioning dify and resizing the
  quota (derivation in `namespace.yaml`).
- Green starts cold: its first minute's P99 is higher (JIT), visible in
  Lab Mesh Overview's **P99 latency** panel right after the switch. Warm
  green before switching. Production would replay traffic or mirror to it
  (scenario 13) first.
- Both colours share one database schema, so v2 cannot ship an
  incompatible migration. Blue-green switches code, not data — the schema
  must be compatible with both (expand/contract).

## Reset
Step 5 scales green back to 0. Before the next page, check:
```bash
# Expect only the five customers-service pods, all track=stable
kubectl -n lab-environment get pods -l app=customers-service -L track
```
