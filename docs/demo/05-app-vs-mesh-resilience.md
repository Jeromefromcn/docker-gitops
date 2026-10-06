# 05 — App-level vs mesh-level resilience

## Purpose
Inject one fault (visits-service's Redis times out) and show two resilience
layers reacting differently: the gateway's Resilience4j fallback returns
200, Envoy's per-try timeout returns 504, and the 504 is logged one hop
away from the cause.

## Preconditions
Preflight passed. The fault is a chaos toggle in Consul KV that the app
reads every 5 s: a runtime switch, not a git change.

## Before you start: open the views
1. **Grafana — Explore**, data source **Loki**, last 5 minutes, **Query
   type Instant**. Requests the waypoint gave up on after its 1 s per-try
   timeout (`UT`), by the service it was waiting for:
   ```logql
   sum by (authority, response_code) (count_over_time({service="istio-proxy"} | json | response_flags="UT" [3m]))
   ```
   No rows.
2. **Grafana — Explore**, second tab, data source **Prometheus**, last 15
   minutes, **Query type Range**. api-gateway's circuit breaker around the
   visits call, by outcome:
   ```promql
   sum by (kind) (increase(resilience4j_circuitbreaker_calls_seconds_count{service="api-gateway", name="getOwnerDetails"}[1m]))
   ```
   Only `successful` is above zero.
3. **Jaeger**: <https://jaeger.lab.jerome.cloudns.asia>. Service
   `api-gateway`, **Min Duration** `900ms`, lookback last 15 minutes. No
   traces yet.

## Steps

### 1. Break visits-service's Redis
```bash
# Turn on the Consul chaos toggle: visits-service's Redis calls now time out
curl -s -X PUT -d true http://10.0.0.95:30092/v1/kv/chaos/visits-service/redis-timeout; echo
```
Wait ~10 s for the app to pick it up.

### 2. The same fault, two paths
```bash
# The gateway's aggregation endpoint; expect 200 from the Resilience4j fallback
for i in 1 2 3 4 5; do curl -s -o /dev/null -w 'gateway aggregation   %{http_code} %{time_total}s\n' http://10.0.0.95:30097/api/gateway/owners/6; done

# customers-service's aggregation endpoint; expect 504 from Envoy's per-try timeout
for i in 1 2 3 4 5; do curl -s -o /dev/null -w 'customers aggregation %{http_code} %{time_total}s\n' http://10.0.0.95:30097/api/customer/owners/6/visits; done

# What the fallback returned: the owner and pets, with the visits left empty
curl -s http://10.0.0.95:30097/api/gateway/owners/6; echo
```
Gateway: `200` at ~1.02 s, every pet with `"visits":[]`. Customers:
`504` at ~1.01 s.

### 3. Where each answer came from
- **Loki** (run the query again): two rows, both `504`.
  `visits-service:8082` is the hop that was actually slow.
  `customers-service:8081` is the same timeout seen one hop up:
  customers was waiting on visits. An investigator who reads only the
  customers line stops one hop short.
- **Prometheus** (refresh): `failed` rises on `getOwnerDetails`. The
  gateway's circuit breaker counted the timed-out visits calls and served
  the fallback instead.
- **Jaeger** (Find Traces): ~1 s api-gateway traces. Open one that went
  through customers-service. The visits-service span is marked with the
  error `Simulated Redis timeout (chaos toggle 'redis-timeout' enabled)`
  and lasts ~3 s. The waypoint span in front of it ends at ~1 s with
  `504`. The mesh answered the caller after one second, while visits kept
  working for two more.

### 4. Reset
```bash
# Turn the chaos toggle off
curl -s -X PUT -d false http://10.0.0.95:30092/v1/kv/chaos/visits-service/redis-timeout; echo

# After ~10 s, the customers path answers 200 quickly again
for i in 1 2 3; do curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://10.0.0.95:30097/api/customer/owners/6/visits; done
```

## Talking points
- Same fault, two answers, decided by *where the timeout sits*: the gateway
  path has an app-level fallback; the customers path only has the mesh's
  1 s `perTryTimeout`.
- **The reporting hop is not the faulty hop.** The 504 on the customers
  route is logged against `customers-service:8081` because customers was
  waiting on visits — an investigator reading only that line stops one hop
  short.
- The 1 s per-try timeout truncates every timeout-shaped symptom, so the
  injected delay's size is invisible in latency; nothing is retried
  (`retryOn` excludes timeouts and 5xx by design).
- The circuit breaker wraps only the visits call: a customers outage surfaces
  as Spring's default 500, not as a fallback. Knowing what is *not*
  protected is part of the design.
- The generator's traffic hits the same fault while the toggle is on, so
  the Loki counts are larger than the 10 requests sent by hand.
