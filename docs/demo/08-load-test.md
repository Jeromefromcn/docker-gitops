# 08 — Load test: capacity and overload protection

## Purpose
Drive the lab past its measured knee and watch the overload protection
hold: the excess is refused in milliseconds at the waypoint, the admitted
requests stay fast, and neither the node nor vets' DB pool saturates. This
is the same load that broke the lab in 2a.

## Preconditions
Scenarios 01–06 and 16 are done (this overloads the node; nothing runs
after it). Give the JVMs a few minutes after 06's restarts: a cold JVM's
latency would be mistaken for load. **Say before the run:** the production
`Lab API Down` probe (the host monitoring stack's Grafana) reads
`/api/vet/vets`, the very path the limiter protects, so under this load
the probe itself can be refused with a 429. The alert needs 5 minutes of
failed probes; the limiter only refuses some of them, so it has not fired
in any rehearsal. The load comes from vps_oracle: a generator on
vps-oracle2 would share the 2 cores it is measuring.

## Before you start: open the views
1. **Grafana — Lab Mesh Overview**, last 15 minutes, auto-refresh 10 s:
   <https://grafana.lab.jerome.cloudns.asia/d/lab-mesh-overview/lab-mesh-overview?from=now-15m&to=now&refresh=10s>
   - **Mesh requests by service and code (waypoint)**: the load, and the
     `429` lines when the limiter starts refusing.
   - **P99 latency (ms) by service**: what the admitted requests cost.
   - **CPU throttling ratio by container**.
2. **Grafana — Explore**, data source **Prometheus**, last 15 minutes,
   **Query type Range**, split view with three queries:
   ```promql
   # A — node CPU on vps-oracle2, in cores (2 in total)
   sum(rate(container_cpu_usage_seconds_total{id="/", node="vps-oracle2"}[1m]))

   # B — the longest wait for a DB connection, per service, in seconds
   max by (service) (hikaricp_connections_acquire_seconds_max)

   # C — P99 of admitted (200) requests to api-gateway, in ms
   histogram_quantile(0.99, sum by (le) (rate(istio_request_duration_milliseconds_bucket{reporter="waypoint", destination_canonical_service="api-gateway", response_code="200"}[1m])))
   ```

## Steps

### 1. Run the stepped load
```bash
# k6 steps 5 -> 80 req/s over 6 minutes, from a container on the host network
docker run --rm --name lab-k6 --network host \
  -v "$PWD/k3s/apps/lab-environment/demo/load:/scripts:ro" \
  grafana/k6:2.3.0 run /scripts/k6-steps.js
```
`--network host`: a Docker-bridge container cannot reach a k3s NodePort on
this host (see `vps_oracle/host-native/npm-nodeport-relay/`).

The load is an open model: the arrival rate is fixed per step whatever the
latency, so a knee shows as P99 departing while the rate keeps its target.

### 2. Watch it climb
Each minute the request rate steps up (5, 10, 20, 40, 60, 80 req/s). On
the dashboards:
- **Mesh requests by service and code**: all services rise together. From
  around the 20 req/s step, `429` lines appear and grow with every step:
  `unknown 429` (the limiter answers before the request is handed to
  vets, so the waypoint records no destination) and `api-gateway 429`
  (the same refusals, passed back to the caller). That is the limiter
  from 16 shedding the excess. `vets-service` stays at `200` only.
- **P99 latency**: stays in the low hundreds of ms.
- **Explore A**: node CPU stays well under 2 cores.
- **Explore B**: the longest DB-connection wait stays at a few hundredths
  of a second.
- **Explore C**: the admitted requests' P99 stays low.

Two rehearsals, per minute, waypoint RPS and P99 for api-gateway:

| step | 2026-09-29 RPS / P99 (ms) | 2026-10-06 RPS / P99 (ms) |
|---|---|---|
| 1 | 9 / 38 | 8 / 46 |
| 2 | 17 / 42 | 15 / 73 |
| 3 | 31 / 44 | 30 / 47 |
| 4 | 51 / 90 | 50 / 79 |
| 5 | 71 / 214 | 70 / 158 |

Peak node CPU 1.06 and 1.31 cores; longest DB-connection wait 0.06 s and
0.05 s; admitted (`200`) P99 over the whole run 162 ms and 139 ms.

### 3. k6's own summary
When k6 finishes it prints its summary. 2026-09-29: 10 647 requests,
12.9 % "failed", k6 P99 153 ms, max 565 ms. 2026-10-06: 10 649 requests,
12.89 % "failed", k6 P99 123 ms, max 327 ms. Every "failure" was a 429
from the limiter.

Confirm the failures were all fast refusals, at the waypoint. Explore,
Loki, last 15 minutes, **Query type Instant**:
```logql
sum by (response_code, response_flags) (count_over_time({service="istio-proxy"} | json | authority=~"vets-service.*" | response_code!="200" [10m]))
```
`429` with no flag (1 430 and 1 411 in the rehearsals). No `503 UO`: the pool's
queue limit was never needed, because the rate limiter kept the load
below it.

## Before protection (2a, 2026-09-27)
The same load before the limiter existed: 10 613 requests, 0.85 % failed,
k6 P99 970 ms.

| minute ending | waypoint RPS | P99 (ms) |
|---|---|---|
| 14:22 | 16 | 76 |
| 14:23 | 31 | 188 |
| 14:24 | 51 | 145 |
| 14:25 | 70 | 842 |

P99 first departed around **30 req/s** and broke at ~70. 89 of 92
timeouts were `vets-service`: its DB connection pool made requests wait
up to 3 s for a connection, while the node still had CPU to spare (peak
1.29 of 2 cores, no business container throttled).

## Talking points
- Open model (fixed arrival rate): a closed model would slow its own
  request rate as latency grows and hide the knee.
- **The bottleneck was a hypothesis, and it was wrong** (2a). Five
  1000m-limit JVMs on two cores looked CPU-bound on paper; the measurement
  said the single vets-service replica's pool of 5 DB connections gave out
  first, with CPU still spare.
- **The limit came from that measured knee.** ~30 req/s at the edge, a
  quarter to vets: vets queues at ~7.5 req/s; the limiter admits 6 (16).
- **Excess fails in milliseconds instead of queueing 3 s for a
  connection.** Same load as 2a: the P99 of what is admitted stays low,
  and the excess gets an immediate, honest 429.
- **Two different guards.** The `429` comes from the Lua limiter (rate);
  `503 UO` would come from vets' DestinationRule (`http1MaxPendingRequests:
  5` — queue depth). In the rehearsal the limiter held the rate low enough
  that the queue never overflowed.
- **The probe can be limited too.** `Lab API Down` probes `/api/vet/vets`;
  in the last minutes of the 2026-09-29 rehearsal some of its checks got
  429s (on 2026-10-06 every sampled check passed). The limiter does not
  know a monitor from a user — which is the honest trade-off to say out
  loud.
- Envoy is cheap: at ~68 req/s the waypoint peaked at ~80m and the
  ingress at ~36m, unthrottled (measured 2026-09-28, after CPU requests
  were cut to steady-state usage).
- A 15 s scrape never caught `hikaricp_connections_pending` above 0; the
  acquire-time maximum did. Pick metrics that keep the peak.

## Reset
Nothing to undo. If k6 was interrupted and its container is still there:
```bash
# Remove a leftover k6 container, if any
docker rm -f lab-k6
```
