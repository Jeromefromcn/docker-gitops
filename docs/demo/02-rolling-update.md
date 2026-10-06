# 02 — Zero-downtime rolling update

## Purpose
Roll all five customers-service pods through git while live traffic flows,
and watch ArgoCD, the pods and the mesh's own error counters while it
happens: no request fails.

## Preconditions
Preflight passed. Working tree clean (`git status`). The background traffic
generator keeps running throughout: it is the live traffic.

## Before you start: open the views
1. **ArgoCD — the `lab-environment` app**, tree view:
   <https://argocd.jerome.cloudns.asia/applications/argocd/lab-environment>
   Type `customers-service` in the name filter, so the tree shows the
   Deployment, its ReplicaSet and the five pods. Status reads
   `Synced` / `Healthy`.
2. **Grafana — Lab Mesh Overview**, last 15 minutes, auto-refresh 10 s:
   <https://grafana.lab.jerome.cloudns.asia/d/lab-mesh-overview/lab-mesh-overview?from=now-15m&to=now&refresh=10s>
   Two panels matter:
   - **Mesh requests by service and code (waypoint)** — Istio's own counter
     per service and status code. `customers-service 200` is the only line
     above zero. A `500`/`504` line flat at 0 is left over from an earlier
     scenario and has no new requests.
   - **customers-service RPS per pod (load balancing)** — five lines.
3. **A second terminal pane**, watching the pods:
   ```bash
   # Refresh the customers-service pod list every 2 s; leave it running
   watch -n 2 kubectl -n lab-environment get pods -l app=customers-service
   ```

## Steps

### 1. Change the manifest by hand
```bash
# Bring the checkout up to date with origin/main
git pull --ff-only origin main
```
Open `k3s/apps/lab-environment/k8s/customers-service.yaml` in the editor.
In the pod template's annotations, find `lab.jerome/rollout-rev: "N"` and
add one to the number (for example `"6"` → `"7"`). Save.

This change does nothing on its own. Any edit to the pod template makes
Kubernetes roll the pods, and this one lets you restart without a new
image.

```bash
# Review the change: one line in the pod template
git diff

# Commit it to main with the demo: prefix
git commit -m "demo: rolling-restart customers-service" -- k3s/apps/lab-environment/k8s/customers-service.yaml

# Push; from here on, git is the only thing that changes the cluster
git push
```

### 2. Watch ArgoCD pick it up
In ArgoCD, click **Refresh**. Without it, ArgoCD finds the commit on its
next poll, up to ~3 minutes later. Within seconds:
- The app turns `OutOfSync`, then starts syncing the new commit.
- The `db-init` Job runs first. It is a **PreSync** hook (scenario 03 looks
  at it closely) and finishes in ~8 s.
- A second ReplicaSet appears under the Deployment. Its pod count climbs
  1 → 5 while the old ReplicaSet's falls 5 → 0, one pod at a time.

The second pane shows the same thing: a new pod `0/1 Running` until its
readiness check passes, then an old pod `Terminating`. That repeats every
~25 s, five times, about 2 minutes in all.

### 3. Watch traffic in Grafana
While the pods roll, on Lab Mesh Overview:
- **customers-service RPS per pod** — the lines hand over. An old pod's line
  ends as a new pod's line begins, and the total does not dip.
- **Mesh requests by service and code** — still only `200`. No 5xx line
  rises.

### 4. Count the failures at the mesh (infrastructure layer)
When ArgoCD shows `Synced` / `Healthy` again, open Grafana **Explore**,
data source **Loki**, time range **Last 15 minutes**, **Query type
Instant**:
```logql
sum by (response_code) (count_over_time({service="istio-proxy"} | json | __error__="" [10m]))
```
These are the access logs of the ingress gateway and the waypoint: every
request that crossed the mesh during the rollout. There is one row,
`response_code=200` (~1000 requests). Then check what a user saw, from the
traffic generator's own log:
```logql
{service="traffic-generator"} != " 200 "
```
No lines: no request that was not 200.

### 5. The deploy is on record
In ArgoCD, open **History and rollback**. The top entry is the
`demo: rolling-restart customers-service` commit, with its SHA and deploy
time. Leave it there: scenario 07 rolls it back.

## Talking points
- `maxSurge: 1 / maxUnavailable: 0` + readiness on the actuator readiness
  group + PDB `minAvailable: 3`: capacity never drops below five.
- The 10 s `preStop` sleep is what makes "zero" true. Without it the first
  rehearsal (2026-09-27) failed 2/304 requests `503 UF`: the app exited on
  SIGTERM while the waypoint still routed to the terminating pod. After the
  fix: 0/293.
- The annotation bump is how you restart without a new image; ArgoCD would
  revert a `kubectl rollout restart` as drift.
- Measured history: the first rolling update under Consul discovery threw
  `000`/`405` for ~25 s because every replica shared one Consul instance ID;
  the 405 was the gateway forwarding GET to a POST-only `/fallback`.
- A release touching four Deployments at once deadlocked the namespace
  quota on 2026-09-25 (surge pods + the PreSync hook); the quota is now
  derived from the release peak.

## Reset
Leave the commit: scenario 07 reverts it. Stop the `watch` with Ctrl-C.
