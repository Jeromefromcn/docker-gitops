# Phase L Rate-Limiting Evaluation Notes (the verification process behind the TrafficExtension + Lua design)

Date: 2026-08-25

This document is the verification basis for the [Phase L design](2026-08-25-k3s-phase-l-ratelimit-design.md). It records the complete evidence for "why the two original paths are infeasible" and "why the TrafficExtension + Lua path was added", for future readers (especially anyone questioning this decision) to trace back.

## Background

The [K3s Service Mesh Capabilities Roadmap](2026-08-19-k3s-mesh-capabilities-roadmap.md)'s Phase L was originally defined as "evaluation": evaluating the cost of two paths, Gateway API experimental-channel upgrade vs. Istio EnvoyFilter, **without presupposing a deliverable**. The roadmap also cited "native rate limiting (GEP-2257)" as the incentive for the experimental channel.

This verification was done by an opus subagent (121 tool calls, across official docs + Istio source + cluster read-only verification), and the main session organized the results on top of that.

## Verification conclusion 1: GEP-2257 is not rate limiting; the experimental channel has no native rate limiting

- [GEP-2257](https://gateway-api.sigs.k8s.io/geps/gep-2257/) is actually the **Gateway API Duration string format standard** (`^([0-9]{1,5}(h|m|s|ms)){1,4}$`), used for fields like `timeouts.request`, unrelated to rate limiting. The roadmap treating it as "native rate limiting (GEP-2257)" is a factual error
- The Gateway API official [GEP list](https://gateway-api.sigs.k8s.io/geps/list/) **has no rate-limiting GEP** (the listed ones are Response Header Filter, HTTPRoute Retries, Timeouts, Session Persistence, etc.)
- The cluster's installed **v1.6.1 is the current latest** Gateway API (released 2026-07-16). Its experimental channel's `XBackendTrafficPolicy` only has RetryConstraint/SessionPersistence, **no rate limit field**
- **Conclusion: the experimental-channel-upgrade path does not exist at all; permanently closed**. Not "wait for it to mature" but "there is no upgrade target"

## Verification conclusion 2: EnvoyFilter injecting local_ratelimit is not officially endorsed under ambient

- The [Istio official rate-limiting task page](https://istio.io/latest/docs/tasks/policy-enforcement/rate-limit/)'s local rate limit example is "injecting `envoy.filters.http.local_ratelimit` into the **sidecar**'s inbound filter chain" — **the entire document is based on sidecar mode**, with no mention of ambient
- The EnvoyFilter reference page's patch contexts are only `SIDECAR_INBOUND`/`SIDECAR_OUTBOUND`/`GATEWAY` — all sidecar concepts; attaching EnvoyFilter to a waypoint can only use `targetRefs` (kind Service/Gateway)
- The ambient official docs' listed waypoint extension mechanisms are only [Wasm](https://istio.io/latest/docs/ambient/usage/extend-waypoint-wasm/) and [Lua](https://istio.io/latest/docs/ambient/usage/extend-waypoint-lua/), **EnvoyFilter not among them**
- Istio maintainer **howardjohn** said outright in [istio/istio#54391](https://github.com/istio/istio/issues/54391): "EnvoyFilter very very limited support in ambient"
- Real-world gotchas: [istio/istio#57350](https://github.com/istio/istio/issues/57350) "Rate limiting with EnvoyFilter in Ambient mode not working" (auto-closed); [istio/istio#57609](https://github.com/istio/istio/pull/57609) "Fix envoyfilter not working when virtualservice configured" **was abandoned**
- Phase I also verified the "Gateway API and VirtualService mixed on the same host overwrite each other" gotcha, which is the same family of risk
- **Conclusion: the EnvoyFilter path has high maintenance risk and is not officially endorsed. But it is not completely dead** — 1.30.3 source proves `context: SIDECAR_INBOUND` + `targetRefs` can attach to the waypoint and inject filters (#57350's failure was actually using `context: GATEWAY`). Recorded as a v2 option; see the design document's "Known limitations"

## Verification conclusion 3: an external rate-limit service violates resource constraints

- The external approach (Envoy gRPC ratelimit + Redis) needs two new Deployments + resource quota, violating the roadmap's "prefer reuse, no new components" hard constraint
- `pr-lanes` has no real user traffic; adding infrastructure for a nonexistent problem is the worst cost-benefit
- **Conclusion: excluded**

## The new path: TrafficExtension + Lua

Verification confirmed its feasibility:

1. **CRD is ready**: the cluster's `kubectl get crd trafficextensions.extensions.istio.io` exists (`extensions.istio.io/v1alpha1`), installed with istio-base 1.30.3. The schema includes `lua.inlineCode` (≤64KB), `match[].mode` (CLIENT/SERVER/CLIENT_AND_SERVER), `phase` (AUTHN/AUTHZ/STATS), `targetRefs`, `priority`
2. **Official docs endorse waypoint Lua extension**: [Extend waypoints with Lua scripts](https://istio.io/latest/docs/ambient/usage/extend-waypoint-lua/) is one of the waypoint extension mechanisms listed by the ambient official docs (the example is exactly `kind: Service` + `mode: SERVER` + `phase: STATS` structure)
3. **istiod source confirms the injection mechanism** (1.30.3): `pilot/pkg/networking/core/listener_waypoint.go` (waypoint HTTP chain, TrafficExtension pre/post injection) → `extension/extensionfilter.go` → `extension/lua.go` (Lua → Envoy lua filter compilation); `pilot/pkg/model/policyattachment.go` (`ShouldAttachPolicy` confirming waypoint matches `targetRefs` Service/Gateway)
4. **Lua can return 429**: the Envoy Lua HTTP filter supports `handle:respond()` and replies directly, not forwarding upstream — `respond()` is available in the request stage
5. **Zero new components**: pure CRD, Lua inlined in the waypoint Envoy process

**Biggest limitation**: Lua filter counting is **per-worker** state (Envoy official docs: "All Lua environments are per worker thread"). The waypoint's 200m CPU limit most likely yields 1 worker (= global rate limiting), at the extreme 2 workers (≈ approximate rate limiting, ceiling ≈ config × 2). Acceptable for the demo scenario.

## Cluster current state (verified read-only via kubectl at verification time)

- k3s v1.36.2+k3s1, Istio 1.30.3 ambient (pilot:1.30.3-distroless / ztunnel:1.30.3)
- Gateway API CRDs: BackendTLSPolicy/GatewayClass/Gateway/HTTPRoute/TCPRoute/TLSRoute/UDPRoute/GRPCRoute/ReferenceGrant/ListenerSet — **no BackendTrafficPolicy, no rate-limit resources**
- Istio CRDs: envoyfilters/wasmplugins/trafficextensions/proxyconfigs/telemetries/authorizationpolicies/virtualservices/destinationrules etc.
- `pr-lanes`: four Deployments hello-backend, hello-backend-canary, hello-frontend, waypoint; 0 active PR lanes
- The waypoint already has J (AuthorizationPolicy) + K (mesh-tracing Telemetry) two layers
- No EnvoyFilter/ExtensionConfig/WasmPlugin/TrafficExtension/ProxyConfig exists in the cluster yet
- `pr-lanes-quota` requests 125m/320Mi (hard 400m/768Mi), limits 500m/640Mi (hard 1200m/1536Mi)

## External evidence sources

**Official docs**
- Istio ambient waypoint extension (Lua): https://istio.io/latest/docs/ambient/usage/extend-waypoint-lua/
- Istio ambient waypoint extension (Wasm): https://istio.io/latest/docs/ambient/usage/extend-waypoint-wasm/
- TrafficExtension API reference: https://istio.io/latest/docs/reference/config/proxy_extensions/traffic_extension/
- Istio Lua task page: https://istio.io/latest/docs/tasks/extensibility/lua-scripts/
- Istio rate-limiting task page (sidecar only): https://istio.io/latest/docs/tasks/policy-enforcement/rate-limit/
- Envoy Lua HTTP filter (respond/stats/per-worker): https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/lua_filter
- Envoy local rate limit filter: https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/local_rate_limit_filter
- Gateway API GEP list (no rate-limiting GEP): https://gateway-api.sigs.k8s.io/geps/list/
- GEP-2257 (Duration format, not rate limiting): https://gateway-api.sigs.k8s.io/geps/gep-2257/

**Istio source (1.30.3)**
- `pilot/pkg/networking/core/listener_waypoint.go` (waypoint HTTP chain, TrafficExtension injection)
- `pilot/pkg/networking/core/extension/extensionfilter.go`, `extension/lua.go` (Lua → Envoy lua filter)
- `pilot/pkg/model/policyattachment.go` (`ShouldAttachPolicy`: waypoint matching targetRefs)
- `pilot/pkg/model/push_context.go` (EnvoyFilter workloadSelector matching)

**Istio GitHub Issues/PRs**
- #54391 (ambient rate limiting; howardjohn: "EnvoyFilter very very limited support in ambient"): https://github.com/istio/istio/issues/54391
- #57350 (a Chinese issue "ambient rate limiting not working" — actually a wrong context): https://github.com/istio/istio/issues/57350
- #57609 (the PR fixing envoyfilter+virtualservice conflict, abandoned): https://github.com/istio/istio/pull/57609
- #60530 (TrafficExtension cross-namespace gotcha — only triggered cross-namespace; pr-lanes single-namespace does not trigger it): https://github.com/istio/istio/issues/60530