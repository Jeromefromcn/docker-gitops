# 01 — Load balancing across 5 instances

## Purpose
Show per-request (L7) load balancing by the waypoint across all five
customers-service pods — not per-connection L4 balancing that pins a
keep-alive client to one pod.

## Preconditions
Preflight passed. This page counts its own 100 requests, so `demo-window start`
**pauses the background traffic generator and waits ~80 s** (`DEMO_PAUSE_DRAIN`)
before the window opens: a 1m dashboard window then holds only this demo's
traffic. Run it before you start talking. The generator resumes on
`demo-reset`, or by itself after 15 min (`DEMO_PAUSE_TTL`) if you forget.

## Commands
```bash
# Open the window; pauses the background traffic generator and waits ~80 s first
demo-window start load-balancing

# Send 100 requests through the ingress and count the status codes
for i in $(seq 1 100); do curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30097/api/customer/owners; sleep 0.3; done | sort | uniq -c

# Close the evidence window
demo-window stop load-balancing

# Run the evidence queries for the window; ends with a Grafana link
demo-evidence load-balancing
```

## Expected result
`100 200`. Evidence lists five upstream pod IPs whose counts add up to 100, and
five pods with non-zero request increases.

## Evidence
- **Envoy (waypoint access log):** requests to `customers-service` grouped
  by `upstream_host` — one line per pod.
- **App (Spring metrics):** per-pod request increase in the window.
- Grafana → Lab Mesh Overview → "customers-service RPS per pod".
- Grafana → Lab Business, Window = 60 (seconds), right after the loop: the inbound table
  shows `customers-service /owners` at exactly 100 calls (Calls is a counter
  difference, not an extrapolation) and QPS 1.67 (Calls ÷ 60), and clicking it opens
  the endpoint detail with the per-instance QPS split. To get back to exactly
  that minute later, open the link `demo-evidence` prints at its end: it sets an
  absolute time range ending 20 s after the demo (the tables look back one Window
  from the end of the range) and the Window variable. `lab-ingress-istio ->
  api-gateway` reads 101 and `vets-service /vets` reads 1: the extra call is the
  `Lab API Down` probe, once a minute, which the pause does not stop.

## Talking points
- kube-proxy balances connections; a gateway holding keep-alive connections
  would stick to a few pods. The waypoint balances requests.
- The earlier Consul-based discovery registered every replica under the same
  instance ID, so a rolling update's deregistration deleted the new pods'
  entries (vets/visits went to 0 instances). Discovery is now Kubernetes
  Services only; Consul is config and chaos toggles.
- Five pods of the same JVM service on a 2-core node is deliberate: real
  load balancing needs real replicas.

## Reset
`demo-reset load-balancing` — resumes the generator, then verifies the baseline
(which needs 30 s of generator traffic, so give it a moment).
