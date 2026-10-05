# 08 — Load test: capacity and overload protection

## Purpose
Drive the lab past its measured knee and show the overload protection
holding: the excess is refused in milliseconds at the waypoint, the
admitted requests stay fast, and neither the node nor vets' DB pool
saturates — the same load that broke the lab in 2a.

## Preconditions
Scenarios 01–06 and 16 are done (this overloads the node; nothing runs
after it). **Say before the run:** the production `Lab API Down` probe
reads `/api/vet/vets`, the very path the limiter protects, so under this
load the probe itself gets 429s and may page (Telegram) — a real limiter
protecting a real bottleneck, under real alerting. The load comes from
vps_oracle: a generator on vps-oracle2 would share the 2 cores it is
measuring.

## Commands
```bash
# Open the evidence window: every evidence query is bounded by it
demo-window start load-test

# Run the k6 step load test from a container on the host network
docker run --rm --name lab-k6 --network host \
  -v "$PWD/k3s/apps/lab-environment/demo/load:/scripts:ro" \
  grafana/k6:2.3.0 run /scripts/k6-steps.js

# Close the evidence window
demo-window stop load-test

# Run the evidence queries for the window; ends with a Grafana link
demo-evidence load-test
```
(`--network host`: a Docker-bridge container cannot reach a k3s NodePort
on this host — see `vps_oracle/host-native/npm-nodeport-relay/`.)

## Expected result
k6 steps 5 → 80 req/s over 6 minutes. Rehearsal 2026-09-29 (10 647
requests, 12.9 % "failed" — all of them 429s from the limiter; k6 P99
153 ms, max 565 ms):

| minute ending | waypoint RPS | P99 (ms) |
|---|---|---|
| 02:59 | 9 | 38 |
| 03:00 | 17 | 42 |
| 03:01 | 31 | 44 |
| 03:02 | 51 | 90 |
| 03:03 | 71 | 214 |

1 430 vets-service requests were shed with `429` (none needed the pool's
`UO`); admitted requests' P99 over the whole run was 162 ms; the node
peaked at 1.06 of 2 cores; the longest wait for a DB connection anywhere
was 0.06 s.

### Before protection (2a, 2026-09-27)

10 613 requests, 0.85 % failed, k6 P99 970 ms:

| minute ending | waypoint RPS | P99 (ms) |
|---|---|---|
| 14:22 | 16 | 76 |
| 14:23 | 31 | 188 |
| 14:24 | 51 | 145 |
| 14:25 | 70 | 842 |

P99 first departed around **30 req/s** and broke at ~70. 89 of 92
timeouts were `vets-service`; its DB connection pool made requests wait
up to 3 s for a connection while the node still had CPU to spare (peak
1.29 of 2 cores, no business container throttled).

## Evidence
- **Envoy:** waypoint RPS and P99 per minute for api-gateway (joined on
  timestamps, so a run across UTC midnight keeps every row in order).
- **Envoy:** vets-service requests shed fast — `429` from the limiter or
  `UO` from the pool — must be > 0.
- **Envoy:** admitted (`200`) requests' P99 over the whole run ≤ 400 ms.
- **cAdvisor:** peak node CPU on vps-oracle2 < 1.6 cores (not saturated);
  the most-throttled container for reference.
- **App:** the longest wait for a DB connection (Hikari acquire max)
  < 0.5 s — 2a measured 2.99 s.
- Notes: vets-service's peak working set (ledger D) and the
  `Lab CPU Throttling` state; k6's own summary above.
- Grafana → Lab Mesh Overview: P99 panel and the capacity row.

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
- **The probe got limited too.** `Lab API Down` probes `/api/vet/vets`; in
  the last minutes of the rehearsal its checks got 429s. The limiter does
  not know a monitor from a user — which is the honest trade-off to say out
  loud.
- Envoy is cheap: at ~68 req/s the waypoint peaked at ~80m and the
  ingress at ~36m, unthrottled (measured 2026-09-28, after CPU requests
  were cut to steady-state usage).
- A 15 s scrape never caught `hikaricp_connections_pending` above 0; the
  acquire-time maximum did. Pick metrics that keep the peak.

## Reset
`demo-reset load-test` — removes a leftover k6 container, verifies the
baseline (JVMs may need a minute to settle).
