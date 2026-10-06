# 14 — One bad pod is ejected

## Purpose
Make exactly one of the five customers-service pods fail every request, and
watch the mesh take it out of rotation on its own: retries hide the
failures from users, and outlier detection stops sending it traffic.

## Preconditions
Preflight passed; the routing scenarios are reset. Runs first among the
resilience scenarios: an ejection lasts 30 s and grows on each repeat.

The fault comes from a chaos toggle in Consul KV that the app reads every
5 s. It is not a git change: it is a runtime switch, like a feature flag.

## Before you start: open the views
1. **Grafana — Lab Mesh Overview**, last 15 minutes, auto-refresh 10 s:
   <https://grafana.lab.jerome.cloudns.asia/d/lab-mesh-overview/lab-mesh-overview?from=now-15m&to=now&refresh=10s>
   Three panels matter, all read from the waypoint's own Envoy stats:
   - **Outlier ejections active**: 0 for every cluster.
   - **Upstream retries**: flat.
   - **Mesh requests by service and code (waypoint)**: customers-service
     at `200` only.
2. **Grafana — Lab Endpoint Detail for `GET /owners/{ownerId}`**, last 15
   minutes, auto-refresh 10 s:
   <https://grafana.lab.jerome.cloudns.asia/d/lab-endpoint-detail/lab-endpoint-detail?var-service=customers-service&var-method=GET&var-uri=%2Fowners%2F%7BownerId%7D&var-window_s=60&from=now-15m&to=now&refresh=10s>
   **5xx rate per instance**: five lines at 0. These are the pods' own
   counters.

## Steps

### 1. Break one pod
```bash
# Pick one stable customers-service pod to be the bad one
BAD=$(kubectl -n lab-environment get pods -l app=customers-service,track=stable -o jsonpath='{.items[0].metadata.name}'); echo "bad pod: $BAD"

# Set the Consul chaos toggle: that pod now answers every request with 503
curl -s -X PUT -d "$BAD" http://10.0.0.95:30092/v1/kv/chaos/customers-service/fail-instance; echo
```
Wait ~6 s: the app polls its chaos toggles every 5 s.

### 2. Send traffic
```bash
# Lab ingress (lab-ingress-istio NodePort on vps_oracle)
U=http://10.0.0.95:30097

# 120 requests through the ingress; expect all 200
for i in $(seq 1 120); do curl -s -o /dev/null -w '%{http_code}\n' $U/api/customer/owners/1; sleep 0.25; done | sort | uniq -c
```
`120 200`. One pod in five is failing, and no user notices.

### 3. Why no user noticed
On **Lab Endpoint Detail**, **5xx rate per instance**: the bad pod's line
is high and the other four stay at 0. The pod really did answer with 503.

On **Lab Mesh Overview**, within a refresh or two:
- **Upstream retries** rises on the `http/stable` customers-service
  cluster. Each 503 was retried once, on a different pod.
- **Outlier ejections active** rises to 2 on the same cluster: each of
  the two waypoint replicas ejected the bad pod on its own evidence.
- **Mesh requests by service and code** stays at `200`. The retries hid
  every failure.

The waypoint's access log shows the retries request by request. Explore,
Loki, last 5 minutes, **Query type Instant**:
```logql
sum by (attempts, response_code) (count_over_time({service="istio-proxy"} | json | authority=~"customers-service.*" [3m]))
```
Two rows, both `200`: `attempts="1"` (most requests) and `attempts="2"`
(about 15 in the rehearsal). The first try hit the bad pod and the retry
succeeded.

The same counters straight from the waypoint:
```bash
# The waypoint's outlier-detection counters for customers-service's stable subset
kubectl -n lab-environment exec deploy/waypoint -- pilot-agent request GET stats | grep -E 'http/stable\|customers-service.*outlier_detection.ejections_(active|enforced_total)'
```

### 4. Kubernetes saw nothing
```bash
# The bad pod is still 1/1 Ready: its probes pass
kubectl -n lab-environment get pod "$BAD"
```
Kubernetes still counts the pod as healthy. Only the data plane, watching
real responses, took it out.

### 5. Reset
```bash
# Turn the chaos toggle off
curl -s -X PUT -d false http://10.0.0.95:30092/v1/kv/chaos/customers-service/fail-instance; echo
```
Within ~30 s the ejection expires and the bad pod's 5xx line falls to 0.

## Talking points
- **The pod is Ready the whole time.** Kubernetes sees nothing wrong — its
  probes pass. Only the data plane, watching real responses, can tell.
- Two mechanisms, two jobs: the retry (`retryOn: …,503`, a different host
  each attempt) protects the request in flight; outlier detection
  (5 consecutive 5xx → 30 s out, longer on each repeat) protects the ones
  after it. Each waypoint replica ejects on its own evidence.
- `maxEjectionPercent: 50` — with 5 pods at most 2 go at once; a
  single-replica service is never ejected (floors to 0). A bad canary alone
  in its subset is never ejected either (10).
- 503 is retried, 500 is not (10): a 500 is a bug, and retrying it would
  hide it on another pod — here, hiding a sick instance is the point.
- **Fault injection could not have shown this.** An injected abort is a
  local reply in the waypoint; it never reaches a pod, so it never counts
  toward ejection (phase I, measured). A real bad upstream was needed.
