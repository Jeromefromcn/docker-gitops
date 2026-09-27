# 05 — App-level vs mesh-level resilience

## Purpose
Inject one fault (visits-service's Redis times out) and show two resilience
layers reacting differently: the gateway's Resilience4j fallback returns
200, Envoy's per-try timeout returns 504 — and the 504 is logged one hop
away from the cause.

## Preconditions
Preflight passed.

## Commands
```bash
demo-window start app-vs-mesh-resilience
curl -s -X PUT -d true http://10.0.0.95:30092/v1/kv/chaos/visits-service/redis-timeout; echo
sleep 10
for i in 1 2 3 4 5; do curl -s -o /dev/null -w 'gateway aggregation   %{http_code} %{time_total}s\n' http://10.0.0.95:30097/api/gateway/owners/6; done
for i in 1 2 3 4 5; do curl -s -o /dev/null -w 'customers aggregation %{http_code} %{time_total}s\n' http://10.0.0.95:30097/api/customer/owners/6/visits; done
demo-window stop app-vs-mesh-resilience
demo-reset app-vs-mesh-resilience
demo-evidence app-vs-mesh-resilience
```
(The reset runs before the evidence on purpose: the toggle must not stay on
while the evidence queries run.)

## Expected result
Gateway aggregation: `200` at ~1.03 s (visits omitted by the fallback).
Customers aggregation: `504` at ~1.01 s. Reset prints `baseline OK`.

## Evidence
- **Envoy:** `UT` (upstream timeout) at 1000 ms against `visits-service:8082`
  **and** against `customers-service:8081`.
- **App:** Resilience4j non-successful calls increased on api-gateway.
- **App (Jaeger):** a ≥ 900 ms api-gateway trace showing where the time went.

## Talking points
- Same fault, two answers, decided by *where the timeout sits*: the gateway
  path has an app-level fallback; the customers path only has the mesh's
  1 s `perTryTimeout`.
- **The reporting hop is not the faulty hop.** The 504 on the customers
  route is logged against `customers-service:8081` because customers was
  waiting on visits — an investigator reading only that line stops one hop
  short.
- The 1 s per-try timeout truncates every timeout-shaped symptom, so the
  injected delay's size is invisible in latency; nothing is retried
  (`retryOn` excludes timeouts and 5xx by design).
- The circuit breaker wraps only the visits call: a customers outage surfaces
  as Spring's default 500, not as a fallback. Knowing what is *not*
  protected is part of the design.
- Earlier misreading: a 6-minute aggregate of the generator log blamed the
  wrong scenario; per-scenario windows (what `demo-window` records) settled it.

## Reset
Already run inside the commands; `demo-reset app-vs-mesh-resilience` is
safe to repeat.
