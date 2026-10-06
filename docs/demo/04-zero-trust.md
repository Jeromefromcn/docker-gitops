# 04 — Zero trust: mTLS, identity authz, actuator lockdown

## Purpose
Show that the network grants nothing by default: callers are authorized by
workload identity (SPIFFE), at L7 in the waypoint and at L4 in ztunnel.
Each refused call is then found in the refusing proxy's own record.

## Preconditions
Preflight passed.

## Before you start: open the views
1. **Grafana — Explore**, data source **Loki**, last 15 minutes. Every 403
   the ingress gateway or the waypoint answered, and which proxy answered:
   ```logql
   {service="istio-proxy", response_code="403"} | json | line_format "{{.pod_name}}  {{.method}} {{.authority}}{{.path}}"
   ```
2. **Grafana — Explore** in a second tab, data source **Prometheus**,
   last 15 minutes, **Query type Range**. The waypoint's authorization
   filter counts every request it denied:
   ```promql
   sum by (pod) (increase(envoy_http_rbac{authz_enforce_result="denied"}[1m]))
   ```

## Steps

### 1. Right network, wrong identity (L7)
```bash
# The traffic generator may call the ingress, not customers-service directly
kubectl -n lab-environment exec deploy/traffic-generator -- curl -s -o /dev/null -w 'wrong caller -> %{http_code}\n' http://customers-service:8081/owners
```
`403`. The generator is in the same namespace and can open the
connection, but its identity, `sa/traffic-generator`, is not on
customers-service's list of callers. In Loki: a `waypoint-…  GET
customers-service:8081/owners` line. In Prometheus: one waypoint's
`denied` line rises.

### 2. Actuator is locked at the edge (L7)
```bash
# Spring's actuator endpoints are not reachable from outside
curl -s -o /dev/null -w 'actuator via ingress -> %{http_code}\n' http://10.0.0.95:30097/actuator/env
```
`403`. In Loki: `GET 10.0.0.95:30097/actuator/env`, logged by the
ingress gateway (`lab-ingress-istio-…`) and by the waypoint.

### 3. Plaintext from outside the mesh (L4)
```bash
# Pick a customers-service pod IP for this step and the next
CIP=$(kubectl -n lab-environment get pod -l app=customers-service -o jsonpath='{.items[0].status.podIP}')

# Plaintext curl from a throwaway pod in default, outside the mesh
kubectl run -n default mtls-probe --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- curl -s -m 5 -o /dev/null -w 'plaintext from outside the mesh -> %{http_code}\n' http://$CIP:8081/actuator/health; echo "exit=$?"
```
curl fails (exit `52` or `56`). The probe has no mesh identity, and the
pod accepts only mTLS.

### 4. Inside the mesh, bypassing the waypoint (L4)
```bash
# Straight to a pod IP, skipping the waypoint and its L7 policy
kubectl -n lab-environment exec deploy/traffic-generator -- curl -s -m 5 -o /dev/null http://$CIP:8081/owners; echo "pod IP bypass exit=$?"
```
curl fails. Going around the waypoint does not get around the policy.

### 5. Data stores accept only their clients (L4)
```bash
# The generator may not open a connection to postgres at all
kubectl -n lab-environment exec deploy/traffic-generator -- curl -s -m 5 http://postgres:5432; echo "postgres exit=$?"
```
curl fails.

### 6. Who refused steps 3-5
The curl exit codes cannot tell these apart: `52` or `56` depends on
whether the client-side ztunnel accepted the connect before the server
side refused it. ztunnel's own log says who was refused and where:
```bash
# ztunnel's L4 policy rejections in the last 5 minutes: source -> destination
kubectl -n istio-system logs -l app=ztunnel --tail=-1 --since=5m | grep 'policy rejection' | awk '{s="";d=""; for(i=1;i<=NF;i++){if($i~/^src\.addr=/)s=$i; if($i~/^src\.workload=/)s=$i; if($i~/^dst\.service=/)d=$i} print s" -> "d}'
```
Three lines:
- `src.addr=<probe pod IP>` → customers-service. The probe has no
  identity, so only its address is known.
- `src.workload="traffic-generator-…"` → customers-service. This is the
  pod-IP bypass.
- `src.workload="traffic-generator-…"` → postgres.

## Talking points
- Policy is keyed on ServiceAccount principals, not IPs or labels. Every
  business workload has its own SA because the namespace-wide `sa/default`
  (postgres, redis, consul, grafana...) would make any policy on it too broad.
- Two layers: L7 policies in the waypoint (paths, methods, principals), L4
  in ztunnel (who may open a connection at all). The pod-IP call proves the
  waypoint cannot be bypassed.
- Pitfall: ztunnel exposes **no** authorization metrics — an L4 dry run gave
  no signal, so L4 was rolled out in stages and is observed by effect (the
  ztunnel access log's `policy rejection` lines). The L7 layer was dry-run
  first (`envoy_http_rbac` shadow denials over a 15-minute window).
- Probes were not affected by STRICT mTLS — measured, not assumed.

## Reset
Nothing to reset. The probe pod deletes itself (`--rm`). If an interrupted
run left it behind:
```bash
# Remove a leftover probe pod, if any
kubectl -n default delete pod mtls-probe --ignore-not-found
```
