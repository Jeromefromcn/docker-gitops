# 14 — One bad pod is ejected

## Purpose
Make exactly one of the five customers-service pods fail every request, and
show the mesh take it out of rotation on its own: retries hide the failures
from users, outlier detection stops sending it traffic.

## Preconditions
Preflight passed; the routing scenarios are reset. Runs first among the
resilience scenarios: an ejection lasts 30 s and grows on each repeat.

## Commands
```bash
BAD=$(kubectl -n lab-environment get pods -l app=customers-service,track=stable -o jsonpath='{.items[0].metadata.name}'); echo "bad pod: $BAD"
echo "$BAD" > ~/.local/state/lab-demo/bad-pod.name
demo-window start bad-pod
curl -s -X PUT -d "$BAD" http://10.0.0.95:30092/v1/kv/chaos/customers-service/fail-instance; echo
sleep 6   # the app polls its chaos toggles every 5 s
U=http://10.0.0.95:30097
for i in $(seq 1 120); do curl -s -o /dev/null -w '%{http_code}\n' $U/api/customer/owners/1; sleep 0.25; done | sort | uniq -c
kubectl -n lab-environment exec deploy/waypoint -- pilot-agent request GET stats | grep -E 'customers-service.*outlier_detection.ejections_(active|enforced_total)'
kubectl -n lab-environment exec "$BAD" -- curl -s -o /dev/null -w 'bad pod readiness %{http_code}\n' localhost:8081/actuator/health/readiness
demo-window stop bad-pod
demo-reset bad-pod
demo-evidence bad-pod
```
(The reset runs before the evidence on purpose, as in 05: the toggle must
not stay on while the evidence queries run.)

## Expected result
`120 200`. The waypoint shows `ejections_active 1` on the stable cluster;
the bad pod is still Ready (`200`). Reset prints `baseline OK`.

## Evidence
- **Envoy (stats):** peak `outlier_detection_ejections_active` ≥ 1 on the
  customers-service stable cluster.
- **Envoy (access log):** requests with `attempts > 1` exist, and no
  customers-service request failed.
- **App:** the bad pod's own count of 503 answers.

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

## Reset
Already run inside the commands; `demo-reset bad-pod` is safe to repeat.
