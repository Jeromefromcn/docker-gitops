# Lab Demo — Resilience Scenarios and Open Findings (Sub-project 2c)

Date: 2026-09-28

Sub-project 2c of the [lab SDLC demo roadmap](2026-09-25-lab-sdlc-demo-roadmap.md): one-bad-pod outlier ejection, header-triggered fault injection, rate limiting, dependency-level network faults through Toxiproxy, and overload protection under load on `lab-environment`, as runbook scenarios 14–17 plus a rewritten 08, built on [2a's framework](2026-09-27-lab-demo-runbook-framework-design.md) (fixed page structure, `demo-window` / `demo-evidence` / `demo-reset`, `demo:` commits pushed to `main`, ≥ 2 pieces of evidence with ≥ 1 from the infrastructure layer) and [2b's patterns](2026-09-28-lab-routing-scenarios-design.md) (patches in `demo/patches/`, sync wait with a deadline, verbatim `git revert` on the page). It also closes every open thread the roadmap assigns to 2c: ledger items C and D, 2a's `UF,URX` finding, 2b's two open resilience findings, and 2a's deferred minors group B.

## Decisions (agreed 2026-09-28)

| Topic | Decision | Why |
|---|---|---|
| Scope | One spec for the scenarios **and** every open finding | Owner's choice. Investigation items get a fixed exit (fixed, or accepted with a written reason) so they cannot stall the scenarios indefinitely |
| One bad pod | A per-pod chaos toggle in the fork: `chaos/<service>/fail-instance` = a pod name; that pod answers 503 to everything | Fault-injection `abort` is a local reply that never reaches the upstream cluster, so it can never trip outlier detection (measured in phase I). The toggle reuses the existing Consul chaos mechanism (05) and models "same version, one instance gone bad". The canary slot + v2-bad alternative would repeat 10's story (bad *version*) and fail only three owners |
| Rate limiting mechanism | `TrafficExtension` + Lua token bucket on the lab waypoint (phase L's proven path) | Pure CRD, no new components. The bucket is local to each waypoint replica (and each Envoy worker); that local-vs-global difference is a talking point, not hidden. A global rate-limit service would need EnvoyFilter on an ambient waypoint ("very very limited support") and a new Deployment |
| Rate limit placement | **Resident on vets-service** — the measured bottleneck — plus a tighter `connectionPool` on its DestinationRule | Production would carry it, so it is resident (ground rule). Placing it on the bottleneck turns 08's k6 run into the overload-protection scenario; an edge-wide limit would also shed requests that never touch vets |
| Toxiproxy | Wired into the data path **only during the demo**, by a `demo:` commit, reverted afterwards | Real production has no Toxiproxy (ground rule: only what production would not have is temporary). Toxiproxy stays deployed but out of the path at rest. Cost: two visits-service rollouts per demo |
| Overload scenario | No separate 18: **08 is rewritten** as "capacity and overload protection" | With the limiter resident, the unprotected knee can no longer be measured live. 2a's unprotected measurements stay on the page as the "before protection" record |

## Design

### 1. Scenarios

Numbered 14–17; 08 rewritten. Demo order (roadmap: routing → resilience → authz → rate limiting last; 08 stays last because it overloads the node):

… 12 → **14 → 15 → 17** → 04 → 05 → 06 → **16** → **08**

14 goes first among the new ones because an ejection lasts 30 s and must not overlap another scenario's window. 16 precedes 08 because 08 relies on the limiter 16 introduces to the audience.

| # | Scenario | Mechanism | Main action (verbatim on the page) | Evidence (★ = infrastructure layer) |
|---|---|---|---|---|
| 14 | One bad pod is ejected | Fork toggle `chaos/customers-service/fail-instance` = one stable pod's name → that pod answers **503** | `curl -X PUT` the Consul key (runtime state, not config — same as 05, no git); a fixed number of curls; clear the key | ★ waypoint access log grouped by `upstream_host`: the bad pod takes 503s, then no traffic for the ejection time; ★ `envoy_cluster_outlier_detection_ejections_active` = 1 on the customers cluster during the window; generator all 200 (503 is in `retryOn` and the retry goes to another host) |
| 15 | Header-triggered fault injection | `demo:` patch adds a first rule to the customers-service VS: header `x-fault: delay` → fixed 2 s delay, `x-fault: abort` → 503; both pinned to `subset: stable` | commit → push → wait for sync → curls with each header and without → `git revert` → push | ★ access log `response_flags` `DI` / `FI` for exactly the header-carrying requests; ★ the customers cluster's upstream request count does not move for the abort requests (local reply); generator 0 errors (blast radius = requests carrying the header) |
| 17 | Network faults on a dependency (Toxiproxy) | `demo:` patch points visits-service's postgres and redis hosts at toxiproxy (env override → one rollout) and temporarily grants toxiproxy's ServiceAccount the L4 access to postgres/redis and visits the access to toxiproxy; toxics added through toxiproxy's API: latency on redis, then `timeout` (black hole) on postgres | commit → push → rollout → add toxic → curls → remove toxic → next toxic → `git revert` → push → rollout | ★ Envoy `504 UT` on visits-service at 1000 ms — the mesh's per-try timeout is the backstop while the app's own timeouts are far longer (Lettuce 60 s, Hikari 30 s by default); ★ ztunnel logs show the path visits → toxiproxy → postgres; app: Hikari / Lettuce metrics |
| 16 | Rate limiting | Resident TrafficExtension + Lua on the vets-service chain of the waypoint | a burst of curls to `/api/vet/vets` through the ingress | ★ 429 with `x-envoy-ratelimited` at the client; ★ the waypoint's 429 count per replica (shows the per-replica bucket); generator and the `Lab API Down` probe never limited |
| 08 | Load test: capacity and overload protection (rewritten) | Same k6 script; vets carries the resident limiter and a tight pending queue (`http1MaxPendingRequests` of a few, fast `UO` instead of a 3 s pool wait) | k6 run as today | ★ excess requests fail fast (429 / `UO`) while admitted requests keep a flat P99 above 2a's knee; ★ cAdvisor node CPU and throttling (reworked, see §3); app: vets Hikari acquire max < 0.5 s (2a: 2.99 s) |

Scenario-specific choices:

- **14 uses 503, not 500.** 503 is in `retryOn`, so users see nothing while the platform both retries and ejects — and it is the failure that makes ledger item C (§2) live. The page's talking points contrast it with 10, where 500 is deliberately not retried.
- **15 targets customers-service** because a request header survives only on `/api/customer/**` (2b's finding: the aggregation path drops it). The talking points include phase I's two traps: `fault.delay` is not cut by the route timeout on the same rule (to be re-measured against the 1 s `perTryTimeout`), and `abort` never trips outlier detection — which is why 14 needs a real bad pod.
- **17 targets visits-service** because it is a single replica and rolls fastest. It complements 05: 05's chaos is a cooperative app toggle, 17's faults are network behaviour the app did not opt into. The temporary authz grant is itself a talking point: while the proxy sits in the path, postgres sees toxiproxy's identity, not the caller's — least privilege is weaker for exactly as long as the demo lasts.
- **16's limit value** is derived from vets' measured capacity (5 Hikari connections × the measured query time), not chosen loosely, and it must clear the generator's (~0.33 rps on vets) and the probe's traffic with a wide margin. The per-replica, per-worker arithmetic is written in the manifest's comment.

### 2. Open findings and fixes

Each investigation item is reproduced and measured first (systematic debugging), and ends in one of two states: fixed, or accepted with the reason written into the README. Nothing is left open.

| Item | Approach | Exit |
|---|---|---|
| **Ledger C** — retries compound across hops | Add `fail-instance` to visits-service as well. With visits answering 503, count how many attempts one external GET produces at visits (access log `attempts` and upstream counts). visits has one replica, so outlier detection cannot eject it (50 % floors to 0) — a clean measurement of retries alone | Measured count recorded in `resilience.yaml`'s comment (replacing the theoretical "9"). If it exceeds 3, cap concurrent retries per cluster with `connectionPool.http.maxRetries` on the DestinationRules (Envoy's native retry circuit breaker) and re-measure. Not adding retries at the edge, not dropping 503 from the inner hops |
| **2a** — `UF,URX` to new Ready pods during concurrent rollouts; **2b** — a freshly Ready subset fails `503 UH` for a second or two | Investigated as one question: a pod is Ready but the waypoint (or ztunnel) cannot reach it yet. Suspects: propagation delay between the EndpointSlice, istiod's EDS push and ztunnel's workload discovery; IP reuse (not verified). Reproduce with concurrent rollouts under dense requests; correlate pod Ready time, waypoint EDS update and ztunnel logs | Fixed at the root cause, or the window is quantified in the README and pages that route to a fresh subset keep page 11's warm-up |
| **2b** — rolling the waypoint drops api-gateway's pooled connections | Reproduce: `rollout restart` of the waypoint under continuous requests. Mesh retries cannot help — the break is between the app and the waypoint, before any Envoy retry. Candidates, platform first: waypoint drain (`terminationDrainDuration` or a preStop via `waypoint-params`); fallback: app-level retry on connection reset for idempotent GETs in api-gateway | Generator zero errors while the waypoint rolls, or accepted with the reason recorded |
| **Ledger D** — vets-service / api-gateway lack `MALLOC_ARENA_MAX` and the 768Mi limit | Measure vets' peak RSS during 08's k6 rehearsal | Rule: if peak headroom < 100Mi, add `MALLOC_ARENA_MAX: "2"` and the 768Mi limit to both (requests unchanged, no quota impact); otherwise record the measurement and close |
| **2a deferred minors, group B** | (4) a "KSM target down" alert — every capacity rule has `noDataState: OK`, so a KSM outage silences all five — and the Quota summary's wording ("requests" while the expression covers every quota resource); (5) 08's cAdvisor piece always passes — reworked with 08; (6) 08's minute table joins on `HH:MM` and breaks across UTC midnight — join on timestamps | TDD against `tests/test-demo-helpers.sh`; the alert fired once for real and resolved |

Out of this spec: 2a minors groups A and C, the dify key in git history (owner's decision), HPA, sub-projects 3 and 4.

### 3. Helpers, baseline and tests

No new helper commands. Four new `scenarios/*.sh` (14–17) and a rewritten `load-test.sh`, following 2a's `rec_if <layer> …` pattern and `settle()` window extension. 15 and 17 are patches in `demo/patches/`, so the CI patch-drift check (`git apply --check`) covers them.

`baseline_check` gains four checks, read from live objects:

- Every `chaos/*/fail-instance` key is absent or empty. It is a string, not a boolean, so today's "all four `chaos/` keys false" check would not see it.
- The customers-service VirtualService carries no `fault` rule.
- visits-service carries no toxiproxy host override, and the postgres / redis L4 policies do not list toxiproxy's ServiceAccount — a forgotten 17 revert fails `demo-reset`.
- The vets-service TrafficExtension **exists** — a resident mechanism missing is a baseline failure too.

**Fork** (`spring-petclinic-microservices`, on `main`): `fail-instance` in customers-service and visits-service, answering 503 when the key's value equals the pod's own hostname. Unit tests: matching name → 503; other name → normal; empty or absent → normal. New SHA tags roll stable customers (×5) and visits once; that rollout must show zero generator errors. The `lab-v2` branch is not rebased — 14 targets a stable pod.

**Mechanism checks before writing pages** (measured, not assumed):

1. The Lua filter on the vets-service chain counts traffic arriving ingress → api-gateway → vets.
2. The 429 and `x-envoy-ratelimited` pass back through api-gateway to the client.
3. The lab waypoint's Envoy `concurrency` (how many buckets per replica).
4. Whether the 2 s fault delay is cut by the 1 s `perTryTimeout` / 3 s route timeout.
5. Whether an `abort` 503 is retried under `retryOn: …,503`.
6. That 14's retries avoid the bad pod (previous-hosts predicate).
7. The L4 path visits → toxiproxy → postgres / redis connects under the temporary grant.

**Helper tests** (stubbed): each new baseline check fails on its leftover and passes when clean; 16's per-replica judgement; 08's timestamp join across midnight; 08's cAdvisor piece fails when nothing saturated.

## Capacity

- 17 rolls visits twice within the existing one-surge-pod-per-Deployment budget; quota unchanged. Toxiproxy's 25m CPU limit could throttle visits' DB traffic while in the path, so 17's patch raises it temporarily.
- The limiter and the connection-pool settings are configuration, with no resource cost.
- Ledger D's possible limit change raises limits only; requests and the quota derivation are unchanged.

## Acceptance criteria

1. A full rehearsal in the order 14 → 15 → 17 → 16 → 08; every `demo-evidence` passes. Output saved to `docs/demo/evidence/`.
2. Afterwards `demo-reset` reports `baseline OK`, including the four new checks; `main` carries each scenario's `demo:` commits paired with their reverts.
3. 08: excess load fails fast (429 / `UO`), admitted requests keep a flat P99 above 2a's ~30 req/s knee, and vets' Hikari acquire max stays below 0.5 s.
4. Ledger C has a measured attempt count; if it exceeded 3, the `maxRetries` cap is applied and re-measured.
5. Each open finding in §2 ends fixed or accepted in writing; while the waypoint rolls, the generator has zero errors unless that finding is accepted with its reason.
6. No `Pending` or `FailedCreate` during the rehearsal (Lab Pod Pending / Quota Near Limit alerts and kube events).
7. Updated: lab README (resilience section, rate limiting, the findings' outcomes), `docs/demo/README.md` order table, page 08, roadmap status, `resilience.yaml` comments.

## Out of scope

- A global (cross-replica) rate-limit service.
- Automated promotion and analysis (sub-project 4); HPA (roadmap's elastic-scaling row).
- 2a deferred minors groups A and C.
- Deleting the dify key from git history.
