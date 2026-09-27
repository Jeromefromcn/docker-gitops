# 01 — Load balancing across 5 instances

## Purpose
Show per-request (L7) load balancing by the waypoint across all five
customers-service pods — not per-connection L4 balancing that pins a
keep-alive client to one pod.

## Preconditions
Preflight passed.

## Commands
```bash
demo-window start load-balancing
for i in $(seq 1 100); do curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30097/api/customer/owners; sleep 0.3; done | sort | uniq -c
demo-window stop load-balancing
demo-evidence load-balancing
```

## Expected result
`100 200`. Evidence lists five upstream pod IPs with similar counts, and
five pods with non-zero request increases.

## Evidence
- **Envoy (waypoint access log):** requests to `customers-service` grouped
  by `upstream_host` — one line per pod.
- **App (Spring metrics):** per-pod request increase in the window.
- Grafana → Lab Mesh Overview → "customers-service RPS per pod".

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
`demo-reset load-balancing` — nothing was changed; verifies the baseline.
