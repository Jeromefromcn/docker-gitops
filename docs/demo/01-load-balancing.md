# 01 — Load balancing across 5 instances

## Purpose
Show per-request (L7) load balancing by the waypoint across all five
customers-service pods — not per-connection L4 balancing that pins a
keep-alive client to one pod. The proof is read live from the waypoint's own
access log and the pods' own metrics, not from a script.

## Preconditions
Preflight passed. Nothing is paused or changed: the background traffic
generator keeps running. The demo calls `GET /api/customer/petTypes`, an
endpoint the generator never calls, so every `/petTypes` request on screen
is one you sent.

## Before you start: open the views
Open these now, before talking, so the audience sees them go from empty to
filled.

1. **Grafana — Lab Endpoint Detail for `/petTypes`**, auto-refreshing every
   10 s:
   <https://grafana.lab.jerome.cloudns.asia/d/lab-endpoint-detail/lab-endpoint-detail?var-service=customers-service&var-method=GET&var-uri=%2FpetTypes&var-window_s=300&from=now-10m&to=now&refresh=10s>
   Scroll to the **Per instance** row. It is empty: no one has called
   `/petTypes` in the last 5 minutes.
2. **Grafana — Explore**, data source **Loki**, time range **Last 5 minutes**.
   Paste this query (Code mode) — the waypoint's access log for the demo
   endpoint, one line per request with the pod that served it:
   ```logql
   {service="istio-proxy"} | json | path="/petTypes" | line_format "{{.upstream_host}}  {{.response_code}}  trace_id={{.trace_id}}"
   ```
   Run it: no lines yet.

## Steps

### 1. The five pods and their IPs
```bash
# The five customers-service replicas and the pod IP of each
kubectl -n lab-environment get pods -l app=customers-service -o wide
```
Keep this output on screen: the IPs are what the waypoint log will show.

### 2. Send 100 requests through the ingress
```bash
# 100 requests to the endpoint only this demo calls; count the status codes
for i in $(seq 1 100); do curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30097/api/customer/petTypes; sleep 0.3; done | sort | uniq -c
```
Expect `100 200` after ~35 s. While it runs, switch to the Grafana tab.

### 3. Watch it in Grafana (app metrics)
On the Endpoint Detail tab, within a refresh or two:
- **QPS per instance** — five lines rise together, one per pod.
- **Calls per instance (now, Window)** — five bars of roughly 20 each.
- The **Calls** stat at the top reaches 100 about 15 s after the loop ends
  (Prometheus scrapes every 15 s).

These numbers are each pod's own Spring request counter.

### 4. Confirm it at the waypoint (infrastructure layer)
Back in Explore, run the Loki query again. There is one line per request,
and the IPs from step 1 are mixed from line to line. No pod gets a long run
of lines to itself, so the balancing is per request, not per connection.

Switch to a count per pod. Set **Query type** to **Instant** and run:
```logql
sum by (upstream_host) (count_over_time({service="istio-proxy"} | json | path="/petTypes" [5m]))
```
Five rows, one per pod IP from step 1, adding up to 100. This is Envoy's
record of where it sent each request. The app plays no part in it.

### 5. Follow one request (optional)
Switch back to the log query and expand any line. Click the link on the
`TraceID` field to open the trace in Jaeger. It shows every hop: ingress →
waypoint → api-gateway → waypoint → customers-service, down to its database
query.

## Talking points
- kube-proxy balances connections; a gateway holding keep-alive connections
  would stick to a few pods. The waypoint balances requests. Step 4's
  mixed IPs show this directly. api-gateway reuses its connections,
  and every request still lands on a different pod.
- Two independent records agree: Envoy's access log (where the request was
  sent) and each pod's own counter (what it served).
- The earlier Consul-based discovery registered every replica under the same
  instance ID, so a rolling update's deregistration deleted the new pods'
  entries (vets/visits went to 0 instances). Discovery is now Kubernetes
  Services only; Consul is config and chaos toggles.
- Five pods of the same JVM service on a 2-core node is deliberate: real
  load balancing needs real replicas.

## Reset
Nothing to reset. Nothing was paused or changed.
