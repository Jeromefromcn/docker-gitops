# 10 — Canary by weight: catch a bad build, roll back

## Purpose
Send exactly 10 % of traffic to one v2 pod, a share no replica count
gives, with a build that has a real bug. Watch the platform, not the app,
pin every error on the canary while 90 % of users never see it. Then roll
back with one `git revert`.

## Preconditions
Preflight passed; 09 reset (no canary pod). The v2-bad build
(`77962eada66c`) fails on owners with two pets (3, 6 and 10): its
"simplified" `primaryPetName` throws. Its unit tests passed, because none
had two pets.

## Before you start: open the views
1. **ArgoCD — the `lab-environment` app**, tree view, name filter
   `customers-service`:
   <https://argocd.jerome.cloudns.asia/applications/argocd/lab-environment>
2. **Grafana — Lab Endpoint Detail for `GET /owners/{ownerId}`**, last 15
   minutes, auto-refresh 10 s:
   <https://grafana.lab.jerome.cloudns.asia/d/lab-endpoint-detail/lab-endpoint-detail?var-service=customers-service&var-method=GET&var-uri=%2Fowners%2F%7BownerId%7D&var-window_s=60&from=now-15m&to=now&refresh=10s>
   **5xx rate** is 0, and so is every line in **5xx rate per instance**.
3. **Grafana — Explore**, data source **Loki**, last 5 minutes, **Query
   type Instant**. The waypoint's access log for customers-service,
   counted by the build that answered and the status code:
   ```logql
   sum by (app_version, response_code) (count_over_time({service="istio-proxy"} | json | authority=~"customers-service.*" [2m]))
   ```
   One row: no `app_version` (v1), `response_code="200"`.

## Steps

### 1. Deploy the bad build at 10 %
```bash
# Bring the checkout up to date with origin/main
git pull --ff-only origin main
```
Make three edits in the editor.

`k3s/apps/lab-environment/k8s/customers-service-canary.yaml`:
- `replicas: 0` → `replicas: 1`
- Replace the container's `image:` line (v2-good, `# fork c44d33230743`)
  with the v2-bad build:
  ```yaml
          image: ghcr.io/jeromefromcn/petclinic-customers-service@sha256:51479efaae977a7069e05836180344281910c9531808646fc05fcb638a32c315 # fork 77962eada66c
  ```

`k3s/apps/lab-environment/k8s/resilience.yaml`, `customers-service`
VirtualService: both routes have a single `stable` destination. Under each
one's `subset: stable` add a weight, and a second destination for the
canary:
```yaml
      route:
        - destination:
            host: customers-service.lab-environment.svc.cluster.local
            subset: stable
          weight: 90
        - destination:
            host: customers-service.lab-environment.svc.cluster.local
            subset: canary
          weight: 10
```

```bash
# Review: replicas, image, and a 90/10 split on both routes
git diff

# Commit to main with the demo: prefix
git commit -m "demo: canary customers-service v2-bad at 10%" -- k3s/apps/lab-environment/k8s

# Push; ArgoCD deploys from git
git push
```
In ArgoCD, click **Refresh**. A pod appears under
`customers-service-canary`. It is Ready after ~70 s.

Watch the Loki query during those 70 s. A few rows with
`response_code="503"` and no `app_version` may appear. The weight takes
effect at once, but the canary subset has no ready pod yet, so the
waypoint answers 10 % of requests itself with `503 UH` (no healthy
upstream). In the rehearsal it was 3 requests. A production rollout
avoids this by scaling the canary up in one commit and adding the weight
in the next.

### 2. Send traffic at a two-pet owner
```bash
# 200 requests for owner 3 (two pets: v2-bad fails on it); count the status codes
for i in $(seq 1 200); do curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30097/api/customer/owners/3; sleep 0.3; done | sort | uniq -c
```
About 180 `200` and 20 `500`. Switch to Grafana while it runs.

### 3. Watch the errors land on one pod
On the Endpoint Detail tab:
- **5xx rate per instance**: the canary pod's line jumps. The five stable
  pods' lines stay at 0.
- **QPS by status code**: a `500` line appears next to `200`.

The background generator also calls owners 3, 6 and 10. When those calls
hit the canary they fail too, so the canary's line rises even before the
loop starts.

### 4. The waypoint's record (infrastructure layer)
Run the Loki query again. New rows appear:
- `app_version="77962eada66c"` with `response_code="500"` and with
  `"200"`. The canary fails owners 3, 6 and 10 and serves the others.
- No row with no `app_version` and `response_code="500"`. Stable did not
  fail once. (A `503` row with no `app_version` is the startup gap from
  step 1. The waypoint sent it, not a pod.)

Then look at the failure itself, from the canary pod's own log:
```logql
{pod_name=~"customers-service-canary-.*"} |= "more than one pet"
```
`HttpMessageNotWritableException: Could not write JSON: owner 3 has more
than one pet`. The exception is thrown while the owner is serialised,
which is where the "simplified" `primaryPetName` runs. Expand a line
and click its `TraceID` link: the Jaeger trace shows the 500 starting in
the canary pod.

### 5. Roll back
```bash
# Roll back: revert the demo commit
git revert --no-edit HEAD

# Push; ArgoCD deploys the rollback
git push
```
In ArgoCD, click **Refresh**: the canary pod terminates. In **History
and rollback**, the revert commit is the top entry. Within a minute,
Grafana's **5xx rate** falls back to 0.

## Talking points
- The weight is independent of replicas: one pod takes 10 %, and 1 % would
  need no more pods.
- **500 is deliberately not in `retryOn`.** Retrying it would send the
  retry through the same 90/10 split, nine times in ten to stable, and
  the canary's bug would disappear from the user-facing numbers. Not
  retrying 500 is what makes a canary observable.
- Outlier detection will not save you here: with one canary pod,
  `maxEjectionPercent: 50` of one host floors to 0 ejectable hosts. Envoy
  ejects at least one host regardless only when `always_eject_one_host` is
  enabled, and it is off here. The decision to roll back is a human's (or, later,
  Argo Rollouts' analysis — sub-project 4).
- The generator's `/api/customer/owners` list also serialises owners 3, 6
  and 10, so ~10 % of its list calls fail too — the blast radius is the
  weight, not the endpoint.
- The bug passed CI: v2-good's tests covered owners with zero and one pet,
  and the "simplification" kept them green. Production-shaped traffic is
  what a canary adds that unit tests cannot.

## Reset
The page's revert is the rollback. Before the next page, check that the
canary pod is gone:
```bash
# Expect only the five customers-service pods, all track=stable
kubectl -n lab-environment get pods -l app=customers-service -L track
```
