# 08 — Load test: capacity baseline and bottleneck

## Purpose
Find the request rate at which P99 departs, and prove from the platform's
own metrics what saturated — a capacity number with a cause, not a guess.

## Preconditions
Scenarios 01–06 are done (this overloads the node; nothing runs after it).
**This will likely fire the production `Lab API Down` alert (Telegram)** —
a real load test runs under real alerting. The load comes from vps_oracle:
a generator on vps-oracle2 would share the 2 cores it is measuring.

## Commands
```bash
demo-window start load-test
docker run --rm --name lab-k6 --network host \
  -v "$PWD/k3s/apps/lab-environment/demo/load:/scripts:ro" \
  grafana/k6:2.3.0 run /scripts/k6-steps.js
demo-window stop load-test
demo-evidence load-test
```
(`--network host`: a Docker-bridge container cannot reach a k3s NodePort
on this host — see `vps_oracle/host-native/npm-nodeport-relay/`.)

## Expected result
k6 steps 5 → 80 req/s over 6 minutes. Rehearsal 2026-09-27 (10 613
requests, 0.85 % failed, k6 P99 970 ms):

| minute ending | waypoint RPS | P99 (ms) |
|---|---|---|
| 14:22 | 16 | 76 |
| 14:23 | 31 | 188 |
| 14:24 | 51 | 145 |
| 14:25 | 70 | 842 |

P99 first departs around **30 req/s** and breaks at ~70. 89 of 92
timeouts were `vets-service`; its DB connection pool made requests wait
up to 3 s for a connection while the node still had CPU to spare (peak
1.29 of 2 cores, no business container throttled).

## Evidence
- **Envoy:** waypoint RPS and P99 per minute for api-gateway; upstream
  timeouts (`UT`) grouped by upstream — the hop that gave out first.
- **cAdvisor:** peak node CPU on vps-oracle2 and the most-throttled container.
- **App:** the saturated resource, chosen from the measurements — node CPU
  (≥ 1.6 cores or a container ≥ 50 % throttled) and/or a service's Hikari
  pool (`hikaricp_connections_acquire_seconds_max` ≥ 0.5 s).
- Notes: the `Lab CPU Throttling` state; k6's own summary above.
- Grafana → Lab Mesh Overview: P99 panel and the capacity row.

## Talking points
- Open model (fixed arrival rate): a closed model would slow its own
  request rate as latency grows and hide the knee.
- **The bottleneck was a hypothesis, and it was wrong.** Five 1000m-limit
  JVMs on two cores looked CPU-bound on paper; the measurement says the
  single vets-service replica's pool of 5 DB connections gave out first,
  with CPU still spare. Scaling the node would not have moved the knee.
- The 1 s per-try timeout turns pool waits into 504s instead of slow 200s;
  the gateway's circuit breaker covers only the visits call, so `/api/vet/vets`
  has no fallback.
- Knee → headroom: steady traffic is ~1 req/s; ~30 req/s is where capacity
  planning starts.
- What the lab cannot show yet: overload protection (rate limiting, outlier
  ejection shielding `/api/vet/vets`) is sub-project 2c; horizontal
  autoscaling is blocked because the node's CPU requests are already near
  its 2 cores — though this run says more vets replicas or a larger pool,
  not more CPU, is the first lever.
- A 15 s scrape never caught `hikaricp_connections_pending` above 0; the
  acquire-time maximum did. Pick metrics that keep the peak.

## Reset
`demo-reset load-test` — removes a leftover k6 container, verifies the
baseline (JVMs may need a minute to settle).
