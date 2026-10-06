# 16 — Rate limiting at the waypoint

## Purpose
Send a burst at `/api/vet/vets` and show the resident limiter in front of
vets-service, the lab's bottleneck, turn the excess into immediate 429s.
vets itself only sees what was admitted, and steady traffic is never
touched.

## Preconditions
Preflight passed. Runs after 06; 08 relies on the limiter this page
introduces. Nothing is changed: the limiter is resident.

## Before you start: open the views
1. **Grafana — Lab Business**, Window 300, last 15 minutes, auto-refresh
   10 s:
   <https://grafana.lab.jerome.cloudns.asia/d/lab-business/lab-business?var-window_s=300&from=now-15m&to=now&refresh=10s>
   In **Inbound endpoints**, find the api-gateway row for the
   `vets-service` route. Its **429 count** is 0.
2. **Grafana — Explore**, data source **Loki**, last 5 minutes, **Query
   type Instant**. vets-service requests per waypoint replica and status:
   ```logql
   sum by (pod_name, response_code) (count_over_time({service="istio-proxy"} | json | authority=~"vets-service.*" [1m]))
   ```
   Only `200`, from both waypoint replicas.

## Steps

### 1. The limiter is already there
```bash
# The Lua limiter attached to vets-service's traffic at the waypoint
kubectl -n lab-environment get trafficextension vets-service-ratelimit -o jsonpath='{.spec.lua.inlineCode}' | head -3
```

### 2. Send a burst
```bash
# Lab ingress (lab-ingress-istio NodePort on vps_oracle)
U=http://10.0.0.95:30097

# 60 requests as fast as curl can send them; print the status and whether Envoy rate-limited it
for i in $(seq 1 60); do curl -s -o /dev/null -w '%{http_code} %header{x-envoy-ratelimited}\n' $U/api/vet/vets; done | sort | uniq -c
```
About `9 200` and `51 429 true`. Each waypoint replica admits 3 per
second, and the burst spans a second or two. `x-envoy-ratelimited: true`
is set by the limiter, not by vets.

### 3. Who said no
Run the Loki query again. Both waypoint replicas now have a `429` row
(25 and 26 in the rehearsal). Each keeps its own bucket, so the split is
uneven.

On **Lab Business**, the api-gateway `vets-service` row's **429 count**
reaches the number of 429s curl printed (51 in the rehearsal). Click the
row: the endpoint detail's **QPS by status code** shows the 429 spike
next to the steady 200s.

### 4. vets only saw what was admitted
Explore, **Prometheus**, **Query type Instant**. vets-service's own count
of `/vets` requests in the last minute:
```promql
sum(increase(http_server_requests_seconds_count{service="vets-service", uri="/vets"}[1m]))
```
Well below the 60 sent plus the generator's calls (~37 in the
rehearsal). The limited requests were refused at the waypoint and never
reached a pod.

## Talking points
- **The limit is derived, not guessed.** 2a's load test put the knee at
  ~30 req/s at the edge, a quarter of it to vets: vets starts to queue for
  its 5 DB connections at ~7.5 req/s. The limiter admits 6 req/s in total —
  below the knee, and far above steady traffic (0.48 req/s measured).
- **A 429 is cheap and immediate.** Without the limiter, the excess waited
  up to 3 s for a Hikari connection (2a) and every user got slower; now the
  excess is refused in microseconds and the admitted requests stay fast.
  Behind the limiter, vets' DestinationRule caps the queue too
  (`http1MaxPendingRequests: 5`): past that Envoy fails fast with `503 UO`.
- **The bucket is local.** It lives per Envoy worker, per waypoint replica
  (1 worker × 2 replicas × 3 = 6 req/s). A global limit needs an external
  rate-limit service, which needs EnvoyFilter — "very very limited
  support" on an ambient waypoint — so it was not built.
- **The bucket does not know who is calling.** Every request reaches vets
  through api-gateway with the same identity, so a burst spends the budget
  for everyone: a generator `/api/vet/vets` call landing in the burst's
  second is limited like the rest (rehearsal 2026-09-29: one). Steady
  traffic alone is never limited (10 minutes at 0 × 429 after the limiter
  landed). Fair sharing between callers needs a key — per-client limits,
  which a local Lua bucket without caller identity cannot give.
- **Authorization runs first.** In the waypoint's filter chain `rbac`
  precedes the Lua filter, so a denied caller never spends quota.
- **Only traffic through the waypoint is limited.** A direct pod call would
  bypass it; the L4 policy that admits only the waypoint to vets' pods is
  what closes that door.

## Reset
Nothing to undo: the limiter is resident.
