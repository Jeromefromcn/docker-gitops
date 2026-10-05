# 16 — Rate limiting at the waypoint

## Purpose
Send a burst at `/api/vet/vets` and show the resident limiter in front of
vets-service — the lab's bottleneck — turn the excess into immediate 429s,
while vets itself only sees what was admitted and steady traffic is never
touched.

## Preconditions
Preflight passed (it checks the limiter is present). Runs after 06; 08
relies on the limiter this page introduces.

## Commands
```bash
# Open the evidence window: every evidence query is bounded by it
demo-window start rate-limit

# Lab ingress (lab-ingress-istio NodePort on vps_oracle)
U=http://10.0.0.95:30097

# Burst of 60 requests at /api/vet/vets; count the status codes and which were rate-limited
for i in $(seq 1 60); do curl -s -o /dev/null -D- $U/api/vet/vets | tr -d '\r' | awk 'NR==1{c=$2} tolower($1)=="x-envoy-ratelimited:"{r=$2} END{print c, (r ? "ratelimited" : "-")}'; done | sort | uniq -c

# Let the window's last access-log lines land inside it
sleep 10

# Close the evidence window
demo-window stop rate-limit

# Run the evidence queries for the window; ends with a Grafana link
demo-evidence rate-limit

# Show the start of the Lua limiter that did it
kubectl -n lab-environment get trafficextension vets-service-ratelimit -o jsonpath='{.spec.lua.inlineCode}' | head -3
```

## Expected result
About `6 200 -` and `54 429 ratelimited` — each waypoint replica admits 3
per second the burst spans and limits the rest (rehearsals 2026-09-29:
6 / 54 in one second, 11 / 49 when it spilled into a second one). The evidence lists the 429s per waypoint
replica (uneven — 17 and 37 in the rehearsal — because each replica keeps
its own bucket).

## Evidence
- **Envoy (waypoint access log):** 429s from the Lua limiter, per waypoint
  replica.
- **App (Spring metrics):** vets-service's own request count stays below the
  60 sent — the limited requests never arrived; the traffic generator saw
  no non-200 on its other paths. A note counts the generator's own
  `/api/vet/vets` calls that fell inside the burst and were limited too.

## Talking points
- **The limit is derived, not guessed.** 2a's load test put the knee at
  ~30 req/s at the edge, a quarter of it to vets: vets starts to queue for
  its 5 DB connections at ~7.5 req/s. The limiter admits 6 req/s in total —
  below the knee, and far above steady traffic (0.48 req/s measured).
- **A 429 is cheap and immediate.** Without the limiter, the excess waited
  up to 3 s for a Hikari connection (2a) and every user got slower; now the
  excess is refused in microseconds and the admitted requests stay fast.
  Behind the limiter, vets' DestinationRule caps the queue too
  (`http1MaxPendingRequests: 5`): past that Envoy fails fast with `503 UO`.
- **The bucket is local.** It lives per Envoy worker, per waypoint replica
  (1 worker × 2 replicas × 3 = 6 req/s). A global limit needs an external
  rate-limit service, which needs EnvoyFilter — "very very limited
  support" on an ambient waypoint — so it was not built.
- **The bucket does not know who is calling.** Every request reaches vets
  through api-gateway with the same identity, so a burst spends the budget
  for everyone: a generator `/api/vet/vets` call landing in the burst's
  second is limited like the rest (rehearsal 2026-09-29: one). Steady
  traffic alone is never limited (10 minutes at 0 × 429 after the limiter
  landed). Fair sharing between callers needs a key — per-client limits,
  which a local Lua bucket without caller identity cannot give.
- **Authorization runs first.** In the waypoint's filter chain `rbac`
  precedes the Lua filter, so a denied caller never spends quota.
- **Only traffic through the waypoint is limited.** A direct pod call would
  bypass it; the L4 policy that admits only the waypoint to vets' pods is
  what closes that door.

## Reset
Nothing to undo — the limiter is resident. `demo-reset rate-limit` verifies
the baseline, including that the limiter is still there.
