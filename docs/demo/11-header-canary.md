# 11 — Header / cookie gray release (A/B)

## Purpose
Send only chosen users to v2, testers with a header and a cohort with a
cookie, while everyone else stays on v1. Then show where a routing header
stops working.

## Preconditions
Preflight passed; 10 reset (no canary pod). The traffic generator sends
neither the header nor the cookie, so every request that reaches v2 is one
you marked.

## Before you start: open the views
1. **ArgoCD — the `lab-environment` app**, tree view, name filter
   `customers-service`:
   <https://argocd.jerome.cloudns.asia/applications/argocd/lab-environment>
2. **Grafana — Lab Endpoint Detail for `GET /owners/{ownerId}`**, last 15
   minutes, auto-refresh 10 s:
   <https://grafana.lab.jerome.cloudns.asia/d/lab-endpoint-detail/lab-endpoint-detail?var-service=customers-service&var-method=GET&var-uri=%2Fowners%2F%7BownerId%7D&var-window_s=300&from=now-15m&to=now&refresh=10s>
3. **Grafana — Explore**, data source **Loki**, last 5 minutes, **Query
   type Instant**:
   ```logql
   sum by (app_version) (count_over_time({service="istio-proxy"} | json | authority=~"customers-service.*" [5m]))
   ```
   One unlabeled row: v1 only.

## Steps

### 1. Add a rule for marked requests
```bash
# Bring the checkout up to date with origin/main
git pull --ff-only origin main
```
Make two edits in the editor.

`k3s/apps/lab-environment/k8s/customers-service-canary.yaml`:
`replicas: 0` → `replicas: 1`. The image stays v2-good
(`# fork c44d33230743`).

`k3s/apps/lab-environment/k8s/resilience.yaml`, `customers-service`
VirtualService: add this rule as the **first** entry under `http:`, above
the `GET` rule. The rules are checked in order, so marked requests match
here and everything else falls through to the stable pin:
```yaml
    # Gray release: marked requests (header or cookie) go to the canary;
    # everyone else stays on stable.
    - match:
        - headers:
            x-canary:
              exact: "true"
        - headers:
            cookie:
              regex: "^(.*; )?canary=1(;.*)?$"
      route:
        - destination:
            host: customers-service.lab-environment.svc.cluster.local
            subset: canary
      timeout: 3s
      retries:
        attempts: 0
```

```bash
# Review: replicas 0 -> 1, and one new rule at the top of the VirtualService
git diff

# Commit to main with the demo: prefix
git commit -m "demo: route marked requests to the customers-service canary" -- k3s/apps/lab-environment/k8s

# Push; ArgoCD deploys from git
git push
```
In ArgoCD, click **Refresh**, and wait until the canary pod is Ready
(~70 s).

### 2. Wait until the route is live
Ready is not yet routable: each of the two waypoint replicas learns the new
endpoint on its own, a moment after the pod turns Ready. Until then a
marked request gets `503 UH`, because a header route to a subset with no
endpoints fails rather than falling back to stable.
```bash
# Lab ingress (lab-ingress-istio NodePort on vps_oracle)
U=http://10.0.0.95:30097

# Send marked requests until v2 has answered 10 in a row
end=$((SECONDS + 120)); n=0; until [ $n -ge 10 ]; do [ $SECONDS -lt $end ] || { echo "ROUTE WAIT TIMED OUT - stop here"; break; }; v=$(curl -s -o /dev/null -w '%header{x-app-version}' -H 'x-canary: true' $U/api/customer/owners/1); [ -n "$v" ] && n=$((n+1)) || n=0; sleep 0.5; done; echo "route live"
```

### 3. Marked and unmarked requests
```bash
# 20 requests with the x-canary header; expect all on v2
for i in $(seq 1 20); do curl -s -o /dev/null -w '%header{x-app-version}\n' -H 'x-canary: true' $U/api/customer/owners/1; done | sort | uniq -c

# 20 requests with the canary cookie; expect all on v2
for i in $(seq 1 20); do curl -s -o /dev/null -w '%header{x-app-version}\n' -b 'canary=1' $U/api/customer/owners/1; done | sort | uniq -c

# 20 unmarked requests; expect all on v1 (blank)
for i in $(seq 1 20); do curl -s -o /dev/null -w '%header{x-app-version}\n' $U/api/customer/owners/1; done | sort | uniq -c
```
`20 c44d33230743`, `20 c44d33230743`, `20` blank.

Run the Loki query again. There is a new row,
`app_version="c44d33230743"`. Its count is exactly the marked requests sent
so far, warm-up included (50 in the rehearsal: 10 + 40). Nothing else
reached v2: the generator's hundreds of requests are all in the unlabeled
row. A small `app_version="77962eada66c"` row, if present, is scenario
10's bad build still inside the 5-minute range.

### 4. Where the header stops working
```bash
# 10 marked requests to the gateway's aggregation endpoint
for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code}\n' -H 'x-canary: true' $U/api/gateway/owners/1; done | sort | uniq -c
```
`10 200`, but run the Loki query again: the v2 row has not grown. The
gateway's aggregation code builds *new* requests to customers-service and
does not copy the header, so these calls land on stable. In Grafana,
**Calls per instance (now, Window)** shows the same: the canary pod's bar
holds the marked `/api/customer/**` requests and nothing from the
aggregation path.

### 5. Roll back
```bash
# Roll back: revert the demo commit
git revert --no-edit HEAD

# Push; ArgoCD deploys the rollback
git push
```
In ArgoCD, click **Refresh**: the rule is gone and the canary pod
terminates.

## Talking points
- The VirtualService rule order is the policy: the marked-request rule sits
  first; everything else falls through to the stable pin.
- **Where it breaks:** `/api/customer/**` is proxied by the gateway as-is,
  headers included, so the mark reaches the waypoint in front of
  customers-service. `/api/gateway/owners/{id}` makes *new* requests from
  the gateway's own code and drops it. A routing header only works across
  hops if every app propagates it; that is sub-project 3's lane work
  (Micrometer baggage).
- Cookie-based routing is how an A/B cohort sticks to one variant across
  requests; the header is how a tester opts in.
- **Ready is not routable yet.** In the first rehearsal (2026-09-28) the
  three marked requests sent in that gap got `503 UH`, and the second
  rehearsal showed the two waypoint replicas learn the endpoint
  independently. That is why step 2 waits for 10 in a row.

## Reset
The page's revert undoes it. Before the next page, check that the canary
pod is gone:
```bash
# Expect only the five customers-service pods, all track=stable
kubectl -n lab-environment get pods -l app=customers-service -L track
```
