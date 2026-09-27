# 04 — Zero trust: mTLS, identity authz, actuator lockdown

## Purpose
Show that the network grants nothing by default: callers are authorized by
workload identity (SPIFFE), at L7 in the waypoint and at L4 in ztunnel.

## Preconditions
Preflight passed.

## Commands
```bash
demo-window start zero-trust
# a. Right network, wrong identity: the generator may not call customers-service
kubectl -n lab-environment exec deploy/traffic-generator -- curl -s -o /dev/null -w 'wrong caller -> %{http_code}\n' http://customers-service:8081/owners
# b. Actuator is locked at the edge
curl -s -o /dev/null -w 'actuator via ingress -> %{http_code}\n' http://10.0.0.95:30097/actuator/env
# c. Plaintext from outside the mesh to a STRICT pod
CIP=$(kubectl -n lab-environment get pod -l app=customers-service -o jsonpath='{.items[0].status.podIP}')
kubectl run -n default mtls-probe --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- curl -s -m 5 -o /dev/null -w 'plaintext from outside the mesh -> %{http_code}\n' http://$CIP:8081/actuator/health; echo "exit=$?"
# d. Inside the mesh, bypassing the waypoint by pod IP
kubectl -n lab-environment exec deploy/traffic-generator -- curl -s -m 5 -o /dev/null http://$CIP:8081/owners; echo "pod IP bypass exit=$?"
# e. Data stores accept only their clients
kubectl -n lab-environment exec deploy/traffic-generator -- curl -s -m 5 http://postgres:5432; echo "postgres exit=$?"
demo-window stop zero-trust
demo-evidence zero-trust
```

## Expected result
a `403`; b `403`; c, d, e fail with curl exit `52` or `56` (empty reply or
reset — which one depends on whether the client-side ztunnel accepted the
connect before the server side refused it, so the exit code alone proves
nothing). The evidence lists one ztunnel `policy rejection` per attempt:
the outside pod's IP, then the generator twice (customers pod IP, postgres).

## Evidence
- **Envoy:** 403s in the ingress/waypoint access log; `envoy_http_rbac`
  denied counter increased.
- **ztunnel:** access log `connection closed due to policy rejection` for
  the pod-IP and postgres attempts.

## Talking points
- Policy is keyed on ServiceAccount principals, not IPs or labels. Every
  business workload has its own SA because the namespace-wide `sa/default`
  (postgres, redis, consul, grafana...) would make any policy on it too broad.
- Two layers: L7 policies in the waypoint (paths, methods, principals), L4
  in ztunnel (who may open a connection at all). The pod-IP call proves the
  waypoint cannot be bypassed.
- Pitfall: ztunnel exposes **no** authorization metrics — an L4 dry run gave
  no signal, so L4 was rolled out in stages and is observed by effect (the ztunnel
  access log's `policy rejection` lines). The L7 layer was dry-run first
  (`envoy_http_rbac` shadow denials over a 15-minute window).
- Probes were not affected by STRICT mTLS — measured, not assumed.

## Reset
`demo-reset zero-trust` — removes a leftover probe pod, verifies the baseline.
