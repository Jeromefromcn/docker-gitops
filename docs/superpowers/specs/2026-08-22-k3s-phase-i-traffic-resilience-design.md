# K3s Phase I — Traffic Resilience and Routing Governance Design

Date: 2026-08-22

Corresponds to Phase I of the [K3s Service Mesh Capabilities Roadmap](2026-08-19-k3s-mesh-capabilities-roadmap.md): canary weight routing, timeout/retry, outlier detection, and fault injection. Deliverable: `pr-lanes` gains complete traffic governance capability, usable for subsequent progressive delivery and chaos testing.

Precondition: [Phase F+G](2026-08-18-k3s-phase-fg-mesh-pr-lanes-design.md) is complete and verified; the `pr-lanes` namespace has Istio Ambient installed (istiod + ztunnel + istio-cni + waypoint) and Gateway API, and the `hello-backend`/`hello-frontend` baseline plus PR-lane header routing are all running.

## Scope

**What this phase does:**
- Add `hello-backend-canary` (`lane: canary`) as a real second version; change `backendRefs` in `k8s/backend-httproute.yaml` to weight-split `hello-backend`(90%) / `hello-backend-canary`(10%), and add `timeouts` (`request: 10s`, `backendRequest: 8s`)
- One `DestinationRule` each for `hello-backend` and `hello-backend-canary`, containing only `outlierDetection` (`consecutive5xxErrors: 3, interval: 30s, baseEjectionTime: 30s, maxEjectionPercent: 100` — the original plan was 50, changed to 100 during Task 4 implementation, because both backends are `replicas: 1`, and 50% unconditionally rounds down to 0 ejectable endpoints, which would make the whole feature silently fail)
- One `VirtualService` that only matches the `x-fault-test: "true"` header to inject delay/abort, with zero impact on normal traffic
- Confirm during implementation whether the Gateway API standard channel `HTTPRoute` natively supports a retry field; if not, use `VirtualService.http[].retries`

**What this phase does NOT do (left to later phases or explicitly excluded):**
- PR lanes (the kustomize templates under `lane/` and `pr-lanes-appset.yaml`) get no resources from this phase — only the static baseline resources under `k8s/` are touched, never the dynamically generated per-PR namespace resources, to keep scope tight and risk minimal
- AuthorizationPolicy (fine-grained access control) — the roadmap already schedules it as a separate Phase J; its failure mode is entirely different from this phase's (misconfiguration directly cuts traffic), so they are not mixed together
- Metrics/logs/tracing into `lab-environment` — that is Phase K's scope
- Rate limiting — Phase L's evaluation scope, and Gateway API is currently installed on the standard channel, which lacks the experimental API that rate limiting requires
- `hello-frontend` gets no canary/outlier-detection/fault-injection — it only forwards `/api` to `hello-backend` as a static page; this phase's traffic governance only matters for `hello-backend`

## Current-state constraints

Continuing the three items listed in the roadmap itself:
- Memory headroom is tighter than at F+G time (measured 2026-08-19: 6.2Gi available, swap 85% used). The new `hello-backend-canary` real Deployment is this phase's only change that consumes resident resources; everything else (`DestinationRule`, `VirtualService` weight/timeout/retry fields) is pure control-plane config with zero extra pods
- `pr-lanes-quota` is tight (`limits.cpu: 1200m / limits.memory: 1536Mi`), so new resources must first be confirmed not to hit the ceiling (see "Resource budget" below)
- Gateway API is the standard channel, without experimental API — this does not affect this phase (canary weight and timeout are fields the standard channel already has), but it directly limits whether the retry field is available, which must be verified during implementation

## Architecture

```mermaid
flowchart LR
    subgraph client["Client requests"]
        normal["Normal requests"]
        faulty["Requests carrying x-fault-test"]
    end

    normal --> vs["Istio VirtualService\nbackend-virtualservice.yaml\nweight split + timeout + retry + fault injection"]
    faulty --> vs

    vs -->|90% (normal requests)| stable["hello-backend\nlane: baseline"]
    vs -->|10% (normal requests)| canary["hello-backend-canary\nlane: canary"]
    vs -->|x-fault-test → delay/abort, pinned to stable| stable

    stable -. outlierDetection .-> dr1["DestinationRule\nbackend-destinationrule.yaml"]
    canary -. outlierDetection .-> dr2["DestinationRule\nbackend-canary-destinationrule.yaml"]

    waypoint["waypoint (existing)"] -. enforce L7 policy .-> vs
```

`VirtualService` is the single source of routing configuration for the `hello-backend` host: normal requests (no header) take the default rule's weight split (90/10) and timeout/retry; requests carrying the `x-fault-test` header additionally match the delay/abort rule, which injects the fault and then pins traffic to `hello-backend` (stable), without the randomness of the weight split, so chaos test results are predictable and reproducible. This was not the original design — the original plan had `HTTPRoute` managing the canary split for normal traffic and `VirtualService` handling only fault injection (see the "Components and configuration" table below) — but during implementation (Task 3) the two turned out to be unable to coexist on the same host: `HTTPRoute`'s rule has no header match condition, and when Istio merges it with the `VirtualService` rule into the waypoint's single Envoy route table, this "unconditional" rule overwrites the whole `VirtualService` rule for the same host, so the fault-injection header match is never evaluated. The root cause is the rule being "unconditional", not its weight/timeout content — so the final decision is to delete `backend-httproute.yaml` entirely and let `VirtualService` carry all four functions (canary weight, timeout, retry, fault injection) at once, rather than narrowing HTTPRoute's match scope to divide labor with VirtualService. See "Known limitations" for details.

## Components and configuration

| Item | Decision | Rationale |
|---|---|---|
| Canary weight mechanism | `VirtualService.http[].route[].weight` (the default route rule in `backend-virtualservice.yaml`), two independent Services (`hello-backend` / `hello-backend-canary`), not Istio's traditional subset mechanism | The original plan used Gateway API `HTTPRoute.backendRefs[].weight`; after Task 3 deleted HTTPRoute due to its conflict with VirtualService on the same host, the weight split was folded into VirtualService (see the "Architecture" section and "Known limitations"). The semantics are unchanged: it still splits across multiple destinations, not across subsets under one Service. Using two Services continues the spirit of Gateway API's recommended canary pattern, keeping the two versions' Deployment/labels/resource quotas fully independent and non-interfering |
| Whether DestinationRule is shared with the canary | Not shared — `hello-backend` and `hello-backend-canary` each get their own, containing only outlier detection, no subset | The open question the roadmap left ([design trade-off to refine](2026-08-19-k3s-mesh-capabilities-roadmap.md)). Because the weight split uses the two-Service pattern (see "Canary weight mechanism" above, now carried by `VirtualService`), `DestinationRule` has no subset to switch, so sharing one is meaningless — two independent hosts naturally need two |
| Canary ratio | 90/10 | A demo value; adjusting it later is just changing one number, it doesn't affect the mechanism itself |
| Actual difference of the canary version | Reuses the same pinned image (`nginxinc/nginx-unprivileged`), mounting a different `index.html` via ConfigMap (following the checksum-annotation convention of `frontend-configmap.yaml`), with display text containing "canary" | No new CI pipeline/image needed; during verification, a glance or `curl` can distinguish which version was hit; consistent with the roadmap's "zero new components" spirit — this adds another Deployment of an existing app, not a new piece of infrastructure |
| Timeout value | `timeout: 10s` (`VirtualService.http[].timeout` in `backend-virtualservice.yaml`, applied to the default rule and the delay-match rule) | `hello-backend` is a static page and should respond in the millisecond range, so 10s is a deliberately loose demo value. The original plan used Gateway API `HTTPRoute`'s two-level fields (`timeouts.request: 10s`, `timeouts.backendRequest: 8s`); after Task 3 switched to VirtualService there is only a single `timeout` field, with no request/backendRequest distinction. The original design intent was "use the fault-injection delay to verify the mechanism works (expected to be cut off by timeout)", but testing showed `fault.delay` combined with a `timeout` on the same rule does not take effect (see "Known limitations") — that verification approach itself doesn't hold, which does not mean timeout is ineffective against real slow requests, just that it cannot be tested that way via fault injection; it is not meant to protect a genuinely latency-sensitive service |
| Retry implementation | Final: `VirtualService.http[].retries` (`attempts: 2, perTryTimeout: 2s, retryOn: 5xx,reset,connect-failure`), in the same `backend-virtualservice.yaml` as canary weight, timeout, and fault injection | The original plan left it to implementation time to check whether the Gateway API standard channel `HTTPRoute` natively supports a retry field; but Task 3 already deleted HTTPRoute due to the HTTPRoute/VirtualService conflict, and once VirtualService became the sole routing source, retries naturally fold into the same VirtualService — no longer a separate decision |
| Outlier detection parameters | `consecutive5xxErrors: 3, interval: 30s, baseEjectionTime: 30s, maxEjectionPercent: 100` (original plan 50, changed to 100 during Task 4 implementation) | The typical demo value in Istio's official docs/examples is 50%, which in plain terms means: 3 consecutive 5xx ejects the endpoint from the pool for 30 seconds; but both backends are `replicas: 1`, so 50% unconditionally rounds down to 0 ejectable endpoints, making the whole feature silently fail — hence the change to 100. In a single-replica scenario, the ejectable ceiling is that one endpoint anyway |
| Fault injection trigger | Only matches the `x-fault-test: "true"` header; other rules unchanged | Already confirmed with you — not applied to normal traffic permanently; zero impact at rest; only add the header manually to run a chaos test |
| Fault injection target version | Pinned to `hello-backend` (stable), not subject to canary weight | Simpler design: a fault test wants "this specific version's behavior under failure". If random weight splitting is layered on top, two runs of the same test could hit different versions, making the result unpredictable and hard to compare |
| VirtualService and HTTPRoute coexistence | They do not coexist — `HTTPRoute` (`backend-httproute.yaml`) was already deleted in Task 3, and `VirtualService` is the sole source of routing configuration for the `hello-backend` host, handling weight split, timeout, retry for normal traffic as well as header-triggered fault injection | The roadmap originally expected the two to divide labor and coexist ("fault injection needs VirtualService, the CRD is already there"), but testing showed that when Istio merges Gateway API and traditional API rules into the same Envoy route table, `HTTPRoute`'s unconditional rule (no header match condition) overwrites the whole `VirtualService` rule for the same host — the fault-injection header match is never evaluated by Envoy. The root cause is the rule being "unconditional" rather than its weight/timeout content, so the decision is to delete the whole HTTPRoute, not narrow it; see "Known limitations" |

## Repo layout

```
vps_oracle/k3s/apps/hello/k8s/
  backend-canary-configmap.yaml       # new: override content for the canary version's index.html
  backend-canary-deployment.yaml      # new: hello-backend-canary, lane: canary
  backend-canary-service.yaml         # new: hello-backend-canary Service
  backend-destinationrule.yaml        # new: outlier detection for hello-backend
  backend-canary-destinationrule.yaml # new: outlier detection for hello-backend-canary
  backend-virtualservice.yaml         # new: weight split + timeout + retry + header-triggered fault injection,
                                       # the sole source of routing configuration. backend-httproute.yaml briefly
                                       # existed (Task 2) and was deleted in Task 3 — see "Architecture" and "Known limitations"
```

Everything lands in the existing `k8s/` directory, following the `backend-*` naming convention. ArgoCD's existing `hello` Application picks up the new files automatically; no new Application or Kustomization entry is needed (`k8s/` has no `kustomization.yaml` today — ArgoCD points directly at the directory, so new files take effect automatically).

## Resource budget

The only new resident workload is `hello-backend-canary` (reusing `lane/deployment.yaml`'s resource config: `requests: 25m/64Mi`, `limits: 100m/128Mi`).

| | requests.cpu | requests.memory | limits.cpu | limits.memory |
|---|---|---|---|---|
| Existing static residents (waypoint + frontend + backend baseline) | 100m | 256Mi | 400m | 512Mi |
| + hello-backend-canary | 25m | 64Mi | 100m | 128Mi |
| Subtotal | 125m | 320Mi | 500m | 640Mi |
| `pr-lanes-quota` ceiling | 400m | 768Mi | 1200m | 1536Mi |
| Remaining for PR lanes | 275m | 448Mi | 700m | 896Mi |

Each PR lane's `hello-backend-pr-N` (`lane/deployment.yaml`) uses `requests: 25m/64Mi`, `limits: 100m/128Mi`. Counting by limits (quota caps limits): `700m / 100m = 7`, `896Mi / 128Mi = 7` — **the number of PR lanes that can be open at once drops from about 8 to about 7**. This is the direct cost of deploying a real canary Deployment, an expected and calculated trade-off, not a surprise discovered mid-implementation.

The `DestinationRule` and `VirtualService` weight/timeout/retry fields are pure control-plane config and do not consume quota.

## Verification checklist (phase I pass criteria)

**Canary weight:**
1. `kubectl -n pr-lanes get application hello` → `Synced` + `Healthy`
2. Send many requests (no special header) and confirm the stable vs canary ratio is near 90/10 (distinguish by the "canary" text in the response body)
3. `hello-backend-canary` pod `Running`, without affecting existing PR lane routing (requests with the `x-pr-lane` header still hit the corresponding lane's backend 100%, unaffected by the weight split)

**Timeout:**
4. Use fault-injection delay (`fixedDelay: 15s` > the same rule's `timeout: 10s`) to verify whether timeout can cut off `fault.delay` on the same rule — result: it cannot. Testing shows the request runs the full ~15s before responding `200` (Task 5 smoke test: `200 15.007575s`), not the timeout's expected error code. This is a behavior limitation of `fault.delay` and `timeout` stacked on the same Envoy rule (hypothesis: the route timeout timer only starts when the router filter begins processing the upstream request, later than the fault filter's decode-time delay), not a configuration error in this phase. See "Known limitations" for details

**Retry:**
5. The retry mechanism is finalized as `VirtualService.http[].retries` (see "Components and configuration"). Verify retries actually happen by deliberately making some pod unhealthy and observing the waypoint/envoy access log showing multiple attempts

**Outlier detection:**
6. Structural verification (reliable, done this phase): use `istioctl proxy-config cluster`/`istioctl proxy-config route`, or an Envoy config dump, to confirm the two `DestinationRule` `outlierDetection` settings (`consecutive5xxErrors`/`interval`/`baseEjectionTime`/`maxEjectionPercent`) are actually delivered to the waypoint's Envoy dataplane. Behavioral verification: do **not** use `x-fault-test: abort` to test — it is confirmed that fault-injection abort is a local reply and never reaches the upstream cluster, so outlier detection's `consecutive5xxErrors` would never see anything (see "Known limitations" for the evidence). To truly verify behavior-level ejection, the upstream must actually receive the request and return 5xx (e.g. make the pod itself fail, not simulate via fault injection), which is beyond this phase's stated scope of chaos testing via fault injection — deferred to a later phase
7. After `baseEjectionTime`, that endpoint should automatically return to the pool — again a behavior-level verification that depends on "the upstream actually receiving the request and returning 5xx" from item 6 to actually trigger ejection and observe recovery; not performed this phase, deferred together with item 6

**Fault injection:**
8. Normal requests without the `x-fault-test` header are completely unaffected; latency/success rate match the pre-change baseline
9. Requests carrying the `x-fault-test: "true"` header are indeed injected with delay/abort and pinned to `hello-backend` (stable), never accidentally landing on canary

**Coexistence verification (the highest technical risk in this phase, resolved in Task 3):**
10. With `HTTPRoute` (canary) and `VirtualService` (fault injection) present simultaneously, use `istioctl proxy-config route` to inspect the Envoy route table actually delivered to the waypoint, and confirm whether both rules take effect or overwrite each other — result: they do conflict. `HTTPRoute`'s rule has no header match condition, i.e. it is "unconditional"; when Istio merges the two into the same route table, this unconditional rule overwrites the whole `VirtualService` rule for the same host, so the fault-injection header match is never evaluated by Envoy. Decision: delete `backend-httproute.yaml`, let `VirtualService` become the sole source of routing configuration for `hello-backend`, carrying weight, timeout, retry, and fault injection all at once, rather than narrowing HTTPRoute's match scope to divide labor with VirtualService. See the "Architecture" section and "Known limitations"

**Resources:**
11. `kubectl describe resourcequota pr-lanes-quota -n pr-lanes` confirms used has not exceeded the hard ceiling after adding resources
12. Re-check all existing Applications still `Synced` + `Healthy`, proving no existing service was damaged (including running PR lanes, if any are open right now)

## Known limitations / failure modes

- **Mixing HTTPRoute and VirtualService on the same host does conflict, resolved in Task 3**: the concern in checklist item 10 materialized — cross-checking the rule contents of both against the Envoy route table actually delivered to the waypoint via `istioctl proxy-config route` confirmed that `HTTPRoute`'s unconditional rule (no header match condition) overwrites the whole `VirtualService` rule for the same host, and `VirtualService`'s header match is never evaluated. The root cause is the rule being "unconditional", not the weight/timeout content — narrowing HTTPRoute's match scope would theoretically also work, but since `VirtualService` can already express the same weight-split semantics, there is no reason to keep two configurations fighting each other, so the decision is to delete `backend-httproute.yaml` and let `VirtualService` be the sole source of routing configuration for `hello-backend`. See the "Architecture" section and the "Components and configuration" table
- **`x-fault-test: delay` with `timeout: 10s` does not cut off the 15s injected delay**: testing shows the request runs the full ~15s before responding, with code `200`, not the timeout's expected error code. Hypothesis (phenomenon confirmed, root cause not fully proven): Envoy's route timeout timer appears to start only when the router filter begins processing the upstream request, while the fault filter's decode-time delay finishes before the router filter, so the time consumed by the delay injection is not counted in the `route.timeout` window. It was confirmed via Envoy config dump that the configuration itself compiled correctly (fields written correctly); this is an Envoy behavior limitation when `fault.delay` and `timeout` are stacked, not a configuration error in this phase. It does not affect existing mechanisms — Task 4's outlier detection verification used `abort`, not `delay`, so it did not depend on this combination working
- **`x-fault-test: abort` does not trigger outlier detection ejection, and this is an architectural, not incidental, limitation**: Envoy's fault-injection abort returns a local reply directly, so the request never reaches the upstream cluster — outlier detection's `consecutive5xxErrors` counter reads the upstream cluster's own request/failure stats and never sees requests short-circuited by the fault filter. A natural experiment proved this directly: after sending 6 requests with `x-fault-test: abort`, the upstream cluster's `rq_total` counter stayed at `0`; immediately sending one normal request without the header made `rq_total` jump to `1`. This means fault-injected requests are never counted in any upstream stats — determined by Envoy's design of short-circuiting in the fault filter before the router filter, not a configuration error in this phase, nor an incidental "didn't happen to catch it this time" result; any other service configured the same way would behave identically. To truly verify outlier detection works, the upstream must actually receive the request and return 5xx (e.g. make the pod itself fail, not simulate via fault injection), which is beyond this phase's stated scope of chaos testing via fault injection — deferred to a later phase as needed
- **The canary weight lowering PR-lane concurrency capacity** (8→7 lanes): if the number of concurrently open PRs routinely approaches this ceiling, reconsider whether to make the canary non-resident (e.g. only spin it up when verifying the canary mechanism), but there is currently no sign of hitting it, so leave as-is for now
- **Fault injection is pinned to stable, so the canary version's behavior under failure is never tested**: if testing the canary version's fault recovery is needed later, this phase's VirtualService design must be extended to an optional target; deliberately simplified for now
- **The canary version currently has no dedicated health check / liveness probe config**: the minimal config suffices, since the canary is just the same nginx static page with different content, with no special health logic to handle — same as baseline's `backend-deployment.yaml`

## Handoff to Phase J

Phase J (AuthorizationPolicy) will add east-west access control on top of the same `hello-backend`/`hello-backend-canary`. It must confirm that this phase's new `hello-backend-canary` Service is also covered by the authorization scope (authorizing only `hello-backend` and missing the canary would unexpectedly block canary traffic). Phase J's design should re-read this document's "Components and configuration" table and add the canary to the coverage list.

The actual behavior verified this phase — "mixing Gateway API and traditional Istio API on the same host" (checklist item 10) — that they do conflict, and an unconditional Gateway API rule overwrites a traditional API rule on the same host — is also an important reference for later Phases K/L if they use `EnvoyFilter` or other traditional Istio mechanisms; Phase L's evaluation of the `EnvoyFilter` rate-limiting path must factor this risk in.