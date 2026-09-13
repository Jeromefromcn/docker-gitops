# K3s Service Mesh Capability Completion Roadmap: Completion Drill and Verification Manual

Date: 2026-08-26 (revised 2026-08-29: aligned with the RPC-ified backend)
Status: all four phases I / J / K / L are live and verified in the cluster (**the roadmap's original table was not updated for the K phase status, see "Errata" below**)
Environment: Oracle VPS single-node k3s (Cilium CNI), ArgoCD GitOps, `pr-lanes` namespace (Istio Ambient)
Related docs: [roadmap original](../superpowers/specs/2026-08-19-k3s-mesh-capabilities-roadmap.md), per-phase design docs in the "Related docs" section at the end
This document: a completion-drill and verification manual aimed at "what exactly these four phases produced, **how to fully drill the operations**, how to verify", covering from-scratch completion and operational drills; it does not repeat the design docs' decision process. **From 2026-08-29, `hello-backend` has been RPC-ified** (see the [RPC spec](2026-08-28-hello-backend-rpc-spec.md)); timeout/retry/circuit-breaking are now verified using its built-in `/slow`, `/fail-503`, `/fail-500` endpoints, no longer requiring temporary image modifications.

---

## 0. Errata: the roadmap original's completion markers are wrong

The roadmap original ([2026-08-19-k3s-mesh-capabilities-roadmap.md](../superpowers/specs/2026-08-19-k3s-mesh-capabilities-roadmap.md))'s phase table currently lists the K phase as "design and implementation plan done, pending execution". This is **stale information** — according to git history and the cluster's current state, the K phase was actually fully completed and verified on 2026-08-24 (commits `62f52ed` "Record Phase K implementation findings in the design doc", `0ff2b2e` "Enable Loki compactor retention", `2e07e7f` "Expose Jaeger UI via NPM reverse proxy" are all K-phase wrap-up work), only the roadmap table's row was not updated to "✅ Completed". The K phase's design doc itself already records the full implementation findings in its "Known limitations" section (NodePort assignment confirmed conflict-free, Jaeger service naming, tracing connected on the first try, etc.), and the [implementation plan](../superpowers/plans/2026-08-24-k3s-phase-k-observability.md)'s checkboxes are likewise unchecked — the same single oversight.

Section 4 of this document has cross-checked live with `kubectl`/`kubectl -n argocd get application`, confirming that the I/J/K/L four phases' resources are all running and healthy in the cluster. It is suggested that, when the chance arises, the roadmap table and the implementation plan checkboxes be updated together to "✅ Completed", but this does not affect the functionality already in use.

## 1. One-line summary

Continuing the Istio Ambient skeleton built in [Phase F+G](2026-08-19-k3s-phase-fg-pr-lanes-summary.md), this phase sequentially filled the missing parts of the four standard service-mesh capability groups: **I** adds canary weight routing, timeout, retry, circuit-breaking, and fault injection to `pr-lanes`; **J** adds identity-level access control for east-west traffic (AuthorizationPolicy); **K** plugs metrics/logs/tracing into the compose-stack's existing Prometheus/Grafana, plus a newly opened `mesh-observability` namespace running Loki/Jaeger; **L** adds fixed-window rate limiting to `hello-backend` via `TrafficExtension` + Lua. The four phases deliver zero new resident externally-facing service capability (except for one necessary `hello-backend-canary` Deployment in Phase I), prioritizing reuse of existing components and the existing Grafana/Prometheus; Phase I's behavior-level verification of timeout/retry/circuit-breaking originally required temporarily modifying the backend image to produce a real upstream failure (before 2026-08-29), but after RPC-ification it now uses the backend's built-in `/slow`, `/fail-503`, `/fail-500` endpoints directly (see 5.3), no temporary image modification needed.

## 2. Why do this

After [container-topology v3](../../container-topology/v3.md) was finalized, the current state was audited against the industry's four major service-mesh capability groups (traffic management, security, observability, resilience), finding that Phase F+G only implemented the header routing needed for the single "PR preview lane" scenario, while canary weighting, timeout/retry, circuit-breaking, fault injection, fine-grained authorization, metrics/logs/tracing integration, and rate limiting were all absent. This roadmap converges the gaps into four phases, handled in risk-layered order (Phase I's four items merged because they are homogeneous; Phase J isolated into its own spec→plan→implement→verify round because a misconfigured authorization policy directly cuts traffic; Phase K first investigated then proceeded because it crosses the docker/k3s network boundary; Phase L first honestly evaluated "pr-lanes currently has no real traffic, so the problem rate limiting solves does not exist yet" before deciding whether to do it). Full background is in the roadmap original and the start of each phase's design doc.

## 3. What each of the four phases did

### Phase I: traffic resilience and routing governance (completed 2026-08-22)

- **Canary weight routing**: `VirtualService` (not the originally designed Gateway API `HTTPRoute` — the two override each other when coexisting on the same host; the `HTTPRoute` has been deleted) routes 90% of traffic to `hello-backend` and 10% to the new `hello-backend-canary` Deployment, non-interfering with the existing PR-lane header routing.
- **Timeout**: `timeout: 10s`. Behavior-level verification needs a **real slow upstream** (see 5.3): fault injection's delay is a local wait before the proxy forwards; when stacked with a same-rule timeout it is not truncated (a 15s delay still runs the full request then returns 200) — this is an Envoy behavior limitation for "fault-injection delay", not a config error, and does not mean timeout itself is unverifiable.
- **Retry**: `attempts: 2, perTryTimeout: 2s, retryOn: 5xx,reset,connect-failure`. Behavior-level verification needs a **real upstream 5xx** (see 5.3): fault injection's abort is a local reply, not dispatched upstream, and cannot trigger retries.
- **Circuit-breaking (outlier detection)**: `consecutive5xxErrors: 3, interval: 30s, baseEjectionTime: 30s, maxEjectionPercent: 100` (because both backends have only 1 replica, 50% would round down to 0). Already pushed to the Envoy dataplane. Behavior-level ejection needs **real consecutive 5xx** to trigger (see 5.3): fault injection's abort is a local reply not dispatched upstream, so outlier detection can't see it — to verify, the upstream must actually return 5xx, not a proxy-fabricated one.
- **Fault injection**: triggered by the `x-fault-test: delay`/`abort` header, always hitting `hello-backend` (not including the canary).

### Phase J: fine-grained access control (completed 2026-08-23)

- Two `AuthorizationPolicy`s: **Policy 1** (`hello-backend-waypoint-frontend-only`) attached to the waypoint Gateway, allowing only calls from the `hello-frontend-sa` identity; **Policy 2** (`hello-backend-require-waypoint`) attached to all `app: hello-backend` Pods, allowing only connections from the `waypoint` identity — the two layers together block both "non-hello-frontend calls" and "bypassing the waypoint to hit the Pod directly".
- Two new ServiceAccounts: `hello-frontend-sa`, `hello-backend-sa` (shared by baseline/canary/all PR lanes).
- Rollout is Audit-first: Policy 1 first applied `istio.io/dry-run` for one observation round before switching to Enforce; Policy 2, because its condition is simple, took effect after direct manual comparison.
- **Honestly recorded verification gap**: the dry-run observation window never actually observed a legitimate-identity request being shadow-allowed (all were deliberately injected illegal requests triggering shadow-deny); the real confirmation of legitimate traffic only happened after switching to Enforce.

### Phase K: observability integration (completed 2026-08-24, design overturned and rewritten mid-way)

The roadmap original's design of "reuse `lab-environment`'s existing Prometheus/Loki/Jaeger" was found untenable upon pre-work investigation: those components are all `replicas: 0` (normally not running), and `lab-environment/README.md` explicitly declares "deliberately not sharing the pipeline with real monitoring". A new architecture was adopted:

- A new independent namespace `mesh-observability` runs Loki + Jaeger + a Promtail scoped to `pr-lanes`, neither in `pr-lanes-quota` nor in `lab-environment`.
- istiod / ztunnel / waypoint each have a new NodePort Service exposing their Prometheus endpoints (no new components added).
- **The direction is the compose-stack's existing Prometheus/Grafana actively reaching out to hit k3s NodePorts** (the reverse direction, pod reaching the docker bridge, is blocked by cluster-level `fwmark`/`table 2004` rules — investigated but deliberately not fixed).
- In the process, two layers of preconditions were additionally found and fixed: (1) the compose `prometheus`/`grafana` containers' docker network default gateway resolved to the wrong subnet, fixed by setting the `default` network to `internal: true`; (2) after the gateway fix there was still `Connection refused`, rooted in `socketLB.hostNamespaceOnly: true` making docker containers completely unable to bypass Cilium's two paths to reach the NodePort, resolved by registering the existing `nodeport-relay@<port>.service` (host-netns socat) per port, adding five instances `nodeport-relay@30110`~`30114`.
- The Jaeger UI additionally got an NPM reverse proxy (`jaeger.jerome.cloudns.asia`) and a homepage card.

### Phase L: rate limiting (completed 2026-08-25, both originally planned paths rejected)

- Both originally planned paths turned out to be dead ends after investigation: upgrading Gateway API to the experimental channel — the official GEP list still has no rate-limiting API; Istio `EnvoyFilter` — not officially endorsed in ambient/waypoint mode.
- Switched to **`TrafficExtension` (Istio 1.30 API) + embedded Lua** fixed-window token bucket, attached to the `hello-backend` Service's waypoint inbound filter chain (`phase: STATS`), rate limiting `hello-backend` to 60 req/min, returning `429` + `x-envoy-ratelimited: true` on excess.
- Live verification: 100 bursts got 59×200/41×429, close to the design target; waiting 65+ seconds for the window reset restored 200.
- **The filter chain order was once recorded incorrectly and has been corrected**: the real order is `rbac → grpc_stats → fault → cors → Lua rate limit → ... → router` — Phase J's RBAC is before Phase L's rate limiting, so unauthorized traffic does not consume rate-limit quota.
- **Coverage boundary**: only protects traffic through the `hello-backend` VIP (including the canary 90/10 internal forwarding part), not direct-to-`hello-backend-canary.pr-lanes.svc.cluster.local` or waypoint-bypassing direct-to-Pod traffic.

## 4. Cluster current-state cross-check (at the time this document was written, executed live on 2026-08-26)

```bash
$ kubectl -n pr-lanes get pods -o wide
NAME                                    READY   STATUS    RESTARTS   AGE
hello-backend-84c99cc544-5nnjx          1/1     Running   0          2d3h
hello-backend-canary-75f9d5cf6b-rzjbv   1/1     Running   0          2d3h
hello-frontend-57c7bc45c4-6s84h         1/1     Running   0          2d3h
waypoint-c5657dc59-dv56c                1/1     Running   0          7d2h

$ kubectl -n pr-lanes get authorizationpolicy
NAME                                   ACTION
hello-backend-require-waypoint         ALLOW
hello-backend-waypoint-frontend-only   ALLOW

$ kubectl -n pr-lanes get telemetry
NAME           AGE
mesh-tracing   47h

$ kubectl -n pr-lanes get trafficextension
NAME                      AGE
hello-backend-ratelimit   68m

$ kubectl get namespace mesh-observability
NAME                 STATUS   AGE
mesh-observability   Active   47h

$ kubectl -n mesh-observability get pods
NAME                        READY   STATUS    RESTARTS
jaeger-84bf76d956-72pqr     1/1     Running   0
loki-6c4dd9fb95-ls5xs       1/1     Running   10 (34h ago)
promtail-6b45497c96-b5fvc   1/1     Running   0
```

The four phases' resources all exist and are `Running`/`ALLOW`. Section 5 below provides item-by-item **drill and verification** steps (covering the "change → sync → verify → revert" completion operations).

---

## 4.5 Verification-point overview (10 items, check them off one by one)

The 10 verification points correspond to the four major capability groups. **The "check" column**: change to `[x]` when a verification passes; all checked means this manual has been fully run through. ⚠️ markers denote a verification point with side effects (creating a temporary pod, injecting traffic, or briefly adjusting traffic); before executing, record the quota baseline value per 5.0 first.

| ✓ | Capability | Verification point | Verification method | Expected result | Corresponding section |
|---|---|---|---|---|---|
| [x] | I | Canary weight routing | hit 20 times, count canary hits | ~10% (about 2 hits) | 5.1 |
| [x] | I | Timeout | `/slow` (15s) built-in endpoint | truncated after ~6s returning 504 (not 200; perTryTimeout 2s×3 attempts) | 5.3 |
| [x] | I | Retry | `/fail-503` built-in endpoint | retry occurs, upstream keeps failing, finally 503 | 5.3 |
| [ ] | I | Circuit-breaking | hit `/fail-503` 3+ times | triggers ejection, then 503, recovers to 200 after 30s | 5.3 |
| [ ] | I | Fault injection | `x-fault-test: delay`/`abort` | delay ~15s, abort immediate error code | 5.2 |
| [ ] | J | Identity-level authorization | legal/illegal two paths | legal 200, illegal non-200 | 5.4 |
| [ ] | K | Metrics | compose Prometheus targets | `istiod/ztunnel/waypoint up` | 5.5 |
| [ ] | K | Logs | Loki query `pr-lanes` | non-empty log entries | 5.6 |
| [ ] | K | Tracing | Jaeger query service | includes waypoint-related service | 5.7 |
| [ ] | L | Rate limiting | inject 70 requests | 429 + `x-envoy-ratelimited` appears, recovers to 200 after window reset | 5.8 |

⚠️ Note: the behavior-level verification of **timeout/retry/circuit-breaking** is done directly against the RPC-ified backend's built-in endpoints (`/slow`, `/fail-503`, `/fail-500`), see 5.3 — **no need** to temporarily modify the backend image. Among them **circuit-breaking** briefly puts the backend into the ejected state; after verifying, wait for `baseEjectionTime: 30s` to pass for natural recovery.

## 5. Drill and verification steps

All the commands below assume execution from any directory of the `docker-gitops` repo, with `kubectl` access to this k3s cluster already available. Steps marked "⚠️ has side effects" create a temporary debug pod or briefly adjust traffic — be aware before executing.

### 5.0 Common precondition check

```bash
# All relevant ArgoCD Applications should be Synced + Healthy
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

# pr-lanes quota current usage (baseline value; should be unchanged before vs after later steps)
kubectl -n pr-lanes describe resourcequota pr-lanes-quota
```

Expected: `hello`, `istio-istiod`, `istio-ztunnel`, `istio-cni`, `istio-base`, `gateway-api`, `mesh-observability` are all `Synced`/`Healthy`.

---

### 5.1 Phase I: canary weight routing

**The weight-routing rule is the third http rule of `backend-virtualservice.yaml`** (the one with no header match): `weight: 90 → hello-backend` (stable), `weight: 10 → hello-backend-canary`. Changing this weight verifies the weight change — this is the GitOps completion loop (Git first → ArgoCD sync).

**A. Verify current weights (no change)**

```bash
FRONTEND_POD=$(kubectl -n pr-lanes get pod -l app=hello-frontend -o jsonpath='{.items[0].metadata.name}')

# Hit 20 times consecutively, count the canary-hit ratio, expected near 10% (about 2 hits)
for i in $(seq 1 20); do
  kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s http://hello-backend.pr-lanes.svc.cluster.local/ | grep -o canary
done | sort | uniq -c
```

Expected: about 2 `canary`, the rest no output (hitting the stable version has no "canary" string).

**B. Drill the completion: change weight to verify weight change (change → sync → verify → revert)**

1. Edit `vps_oracle/k3s/apps/hello/k8s/backend-virtualservice.yaml`, changing the third rule's `weight: 90`/`weight: 10` to `weight: 70`/`weight: 30`.
2. Commit + push (triggers ArgoCD sync):
   ```bash
   git add vps_oracle/k3s/apps/hello/k8s/backend-virtualservice.yaml
   git commit -m "chore: temporarily shift canary weight to 70/30 for drill"
   git push origin main
   ```
3. Wait for ArgoCD sync (`kubectl get application hello -n argocd` becomes `Synced`).
4. Rerun the 20-hit count of A above — expected canary-hit ratio rises noticeably (about 6 hits, not 2).
5. **Revert**: change the weight back to 90/10, then commit + push.

**Side effects**: none (no pod rebuild, only changes the Envoy routing weight).

### 5.2 Phase I: fault injection (delay/abort)

```bash
# Without header: normal response, no delay
kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://hello-backend.pr-lanes.svc.cluster.local/

# With x-fault-test: delay: expected 200 only after a full ~15s (known limitation: timeout 10s does not truncate; this is an Envoy behavior limitation, not a bug)
kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -H 'x-fault-test: delay' http://hello-backend.pr-lanes.svc.cluster.local/

# With x-fault-test: abort: expected immediate return of the error code set by fault injection (not 200)
kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -H 'x-fault-test: abort' http://hello-backend.pr-lanes.svc.cluster.local/
```

### 5.3 Phase I: behavior-level verification of timeout, retry, circuit-breaking (RPC-ified backend's built-in failure endpoints)

**Background**: **do not** use `x-fault-test: delay/abort` to verify these three — those are the proxy's local reply / pre-forward wait; the request is never actually dispatched / slowed at the upstream, so retry and outlier detection can't see it, and timeout is not truncated. To verify the behavior, the **upstream (hello-backend) must actually become slow or actually return 5xx**.

**Approach (from 2026-08-29)**: `hello-backend` has been RPC-ified (see the [RPC spec](2026-08-28-hello-backend-rpc-spec.md)), with **built-in** real upstream endpoints — hit them directly, no temporary image modification:

- `GET /slow`: delays `SLOW_DELAY_SECONDS` (default **15s**) then returns 200 → slower than `perTryTimeout: 2s` × 3 attempts (actually truncated at ~6s, see below), triggering timeout
- `GET /fail-503`: immediately returns 503 → triggers retry (`retryOn: 5xx`) and circuit-breaking (`outlierDetection`)
- `GET /fail-500`: immediately returns 500 → triggers retry (`retryOn: 5xx`), still 500 after retry, finally returns **503**
- `GET /healthz`: returns 200 (for probes)

**Observed behavior (initial test 2026-08-29 / corrected 2026-09-01)**:
- `/slow` (15s) is truncated by Envoy, but **not** by `timeout: 10s` — rather `retries.perTryTimeout: 2s` hits first: each attempt times out at 2s, `attempts: 2` = 1 original + 2 retries = **3 attempts total**, total elapsed **≈ 6s** (2s × 3); after the retry quota is exhausted it returns **504** (not 503, not 10s). `timeout: 10s` is the total budget ceiling, but 6s exhausts the retry quota first, so it never actually triggers.
- `/fail-500` triggers retry (2 times), upstream keeps 500, finally returns **503**.
- So the final visible status code of **timeout** is **504** (every attempt is a timeout-class error); the final visible status code of **retry** (upstream keeps 5xx) is **503**. Distinguish the mechanism by `%{time_total}`: timeout about 6s, retry immediate (<1s).

**Verification steps** (record the section 5.0 quota baseline first):

```bash
FRONTEND_POD=$(kubectl -n pr-lanes get pod -l app=hello-frontend -o jsonpath='{.items[0].metadata.name}')
SVC=http://hello-backend.pr-lanes.svc.cluster.local

# 2 Timeout: expected truncated after ~6s returning 504 (not 200; time_total ≈ 6s = perTryTimeout 2s × 3 attempts)
#   ⚠️ triggers outlier ejection: consecutive 504/5xx will eject the backend (see #4), wait baseEjectionTime 30s before rerunning
kubectl -n pr-lanes exec "$FRONTEND_POD" -- \
  curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' "$SVC/slow"

# 3 Retry: upstream fixed 503, retryOn: 5xx triggers, attempts: 2 retries twice then finally still 503 (immediate, time_total < 1s)
kubectl -n pr-lanes exec "$FRONTEND_POD" -- \
  curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' "$SVC/fail-503"

# 4 Circuit-breaking: 3 consecutive 5xx trigger ejection, afterwards requests return 503/No Healthy Upstream,
#   after baseEjectionTime: 30s passes it recovers to 200
for i in $(seq 1 4); do
  kubectl -n pr-lanes exec "$FRONTEND_POD" -- \
    curl -s -o /dev/null -w '%{http_code}\n' "$SVC/fail-503"
done
```

**Expected**: timeout → 504 after ~6s (`time_total≈6s`, perTryTimeout 2s × 3 attempts; not 200, not 10s); retry → immediate 503 (`time_total<1s`, retry occurs but upstream keeps failing); circuit-breaking → after the 3rd request requests start being rejected (503), recovering to 200 after stopping for 30s+.

Expected: timeout → 504 after ~6s (`time_total≈6s`, perTryTimeout 2s × 3 attempts; not 200, not 10s); retry → immediate 503 (`time_total<1s`, retry occurs but upstream keeps failing); circuit-breaking → after the 3rd request requests start being rejected (503), recovering to 200 after stopping for 30s+. **Nothing needs recovery** — the endpoints are the backend's built-in resident capability; not hitting them means no impact at all; the circuit-breaking ejected state auto-recovers per `baseEjectionTime`. **The only thing to note**: during circuit-breaking verification the backend is briefly ejected and `/` is also affected (all upstreams are on the ejected list); it recovers after 30s+.

> Note: `/fail-500` also suits retry verification (500 → retry → still 500 → finally 503); to verify "retry then success" you need "fail first then recover" upstream logic, which exceeds this document's verification scope (you can temporarily change `SLOW_DELAY_SECONDS`/custom endpoint or scale replicas).

**Request-level evidence of whether retry "really happened" (confirmed by live test 2026-09-01)**: the backend does not write access logs due to the `log_message` override; the waypoint access log records only the **final request** per entry (retry attempts merge into one entry); ztunnel records are **connection-level**, not request-level — none of the three can directly count attempts. The reliable approach is to **use time as the ruler** hitting `/slow`:
- `/slow` (15s) + retry `perTryTimeout: 2s` × 3 attempts → observed **504, `time_total` ≈ 6.0s**, and the waypoint access log shows `504 URX,UT upstream_per_try_timeout` (`URX`=retry limit exceeded, `UT`=upstream per-try timeout) — these two flags are the request-level iron proof that retry occurred and was exhausted.
- If retry were **not** effective, `/slow` would be 10s (timeout) or 15s (full delay), not 6s.
- Control group `/fail-503` (503 immediate) → finally `503 URX via_upstream`, `time_total` < 0.1s (503 consumes no time, forming a sharp contrast with `/slow`'s 6s; relying on `time_total`, retry vs timeout is distinguishable at a glance).

**Why Loki only ever shows "one" log entry (confirmed by live test 2026-09-01)**: don't be misled by "counting log entries" — "one entry" is the normal phenomenon, not retry not occurring. The reason is the observation layering:

```
frontend ──HBONE──> ztunnel(L4) ──> waypoint(L7: retry/timeout/circuit-breaking) ──> ztunnel(L4) ──> backend
```

| Layer | Observation method | Granularity | How many entries one `/slow` (3 attempts) shows |
|---|---|---|---|
| waypoint access log (Loki) | `accessLogFile: /dev/stdout`, collected by promtail | **one per request**, retry attempts merged and marked with flags | **1 entry** (`504 URX,UT upstream_per_try_timeout`) |
| ztunnel log | `connection complete` | **one per HBONE connection** (ambient's L4 layer) | **3 entries** (same connection `48890`, ~2s apart each) |
| backend | `log_message` overridden to empty | none | 0 entries |
| client `time_total` | curl timing | once per request | 6.05s = 2s × 3 |

- **Envoy waypoint's access log is "one request → one entry"**: each retry attempt does not write its own log, only appends `URX` (retry limit exceeded) and `UT` (per-try timeout) flags to the final entry. So "counted one + saw `URX,UT`" = retry really occurred and was exhausted — this is the **request-level iron proof**.
- To see the **detail of each attempt**, query ztunnel's `connection complete` (it records per HBONE connection; retries create new connections / forward on new connections); the backend itself has no log, so the request count can't be derived.
- Therefore the **correct ruler for verifying retry is `time_total` (6s=2s×3) and the `URX,UT` flag**, not "how many entries are in Loki". If retry is not effective, `/slow` would be 10s (timeout) or 15s (full delay), and the flag would be a normal `-`/`UO` not `URX`.

### 5.4 Phase J: identity-level authorization (legal path allowed / illegal path denied)

```bash
# Legal path: hello-frontend calls hello-backend, expected 200
kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null -w '%{http_code}\n' http://hello-backend.pr-lanes.svc.cluster.local/

# ⚠️ has side effects (creates a temporary pod, --rm auto-cleans): illegal identity (default SA) calling the hello-backend Service,
# because the Service has the use-waypoint label it is directed to the waypoint, verifying Policy 1 — expected rejected
kubectl -n pr-lanes run authz-test-1 --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://hello-backend.pr-lanes.svc.cluster.local/

# ⚠️ has side effects: bypass the waypoint, hit the Pod IP directly, verifying Policy 2 independently — expected rejected (connection refused or 403)
BACKEND_IP=$(kubectl -n pr-lanes get pod -l app=hello-backend,lane=baseline -o jsonpath='{.items[0].status.podIP}')
kubectl -n pr-lanes run authz-test-2 --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 "http://${BACKEND_IP}:8080/"
```

Expected: the first `200`; the second and third both non-`200` (connection refused or timeout, `--max-time 5` avoids hanging).

### 5.5 Phase K: metrics (compose Prometheus can pull istiod/ztunnel/waypoint)

```bash
# Query compose Prometheus's targets API directly from the host (internal network only, no need to enter a container)
curl -s http://172.19.0.4:9090/api/v1/targets | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    if t['labels'].get('job') in ('istiod', 'ztunnel', 'waypoint'):
        print(t['labels']['job'], t['health'])
"
```

Expected: `istiod up`, `ztunnel up`, `waypoint up`. You can also open Grafana (`https://grafana.jerome.cloudns.asia`) in a browser and query the metrics of these three jobs via the existing Prometheus data source.

### 5.6 Phase K: logs (Loki can query the waypoint access log)

```bash
for i in $(seq 1 3); do kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null http://hello-backend.pr-lanes.svc.cluster.local/; done
sleep 15
curl -s "http://10.0.0.95:30113/loki/api/v1/query_range?query=%7Bnamespace%3D%22pr-lanes%22%7D&limit=5" | python3 -m json.tool | head -30
```

Expected: non-empty log entries returned (waypoint access log or pod stdout). You can also query in the Grafana Loki data source (Explore page) with `{namespace="pr-lanes"}`.

### 5.7 Phase K: tracing (Jaeger can query the trace of the call just made)

```bash
curl -s "http://10.0.0.95:30114/api/services" | python3 -m json.tool
```

Expected: the service list contains entries related to `hello-backend`/waypoint (**known limitation**: the actual service name is `waypoint.pr-lanes`, not `hello-frontend`/`hello-backend` — under ambient mesh spans are labeled with the waypoint's own identity, and the operationName is `hello-backend:80/*`). You can also open `https://jaeger.jerome.cloudns.asia` directly (requires Basic Auth + access list) and query in a browser.

### 5.8 Phase L: rate limiting (429 behavior + window reset)

```bash
# Inject 70 consecutive requests (threshold 60 req/min), count the status-code distribution — expected mostly 200 first, then 429 appears
for i in $(seq 1 70); do
  kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null -w '%{http_code}\n' http://hello-backend.pr-lanes.svc.cluster.local/
done | sort | uniq -c

# Confirm the 429 response carries the correct header
kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -D - -o /dev/null http://hello-backend.pr-lanes.svc.cluster.local/ | grep -i x-envoy-ratelimited

# After the window resets (60s+) it should recover to 200 — this step waits an extra 65 seconds
sleep 65
kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null -w '%{http_code}\n' http://hello-backend.pr-lanes.svc.cluster.local/
```

Expected: among the 70 hits a certain proportion of `429` appears (depending on timing relative to the last window reset, not necessarily exactly 60/10); 429 responses carry `x-envoy-ratelimited: true`; after the window reset it recovers to `200`.

### 5.9 Wrap up: confirm the quota and other Applications are untouched

```bash
kubectl -n pr-lanes describe resourcequota pr-lanes-quota
kubectl -n mesh-observability describe resourcequota mesh-observability-quota
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
kubectl -n lab-environment get deployments -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas
```

Expected: `pr-lanes-quota` matches the baseline recorded in section 5.0; `mesh-observability-quota` usage within quota; all Applications still `Synced`/`Healthy`; all `lab-environment` Deployments still `REPLICAS: 0` (this roadmap never touched it).

## 6. Known-limitations overview (don't step on the same pitfalls)

- I: `fault.delay` stacked with a same-rule `timeout` is not truncated — this is an Envoy behavior limitation for "fault-injection delay", not that timeout itself is unverifiable (with a real slow upstream the timeout truncates normally, see 5.3); `x-fault-test: abort` cannot trigger circuit-breaking/retry (local reply does not reach the upstream) — to verify at the behavior level, the upstream must actually return 5xx (see 5.3); the canary weight reduces PR-lane concurrent capacity from 8 to 7.
- J: the authorization dry-run observation period never actually observed a legitimate request being shadow-allowed; the real verification of the legal path was only done after switching to Enforce; the protection of the PR-lane backend (`hello-backend-pr-N`) currently has only architectural-analysis support, never tested live against a real PR lane.
- K: Envoy tracing has a sampling-rate setting (currently 100%, deliberately raised, because there is no real traffic so cost is no concern); Jaeger/Loki are both non-persistent storage, cleared on pod rebuild; anyone helping compose to connect a new k3s NodePort must remember the **two layers of preconditions** — the docker network gateway (fixed) + `nodeport-relay@<port>.service` (register per port); missing the second layer produces `connection refused` that looks like the gateway broke again.
- L: the rate-limit coverage boundary goes only to the `hello-backend` VIP, not direct-to-canary-Service traffic or waypoint-bypassing traffic; the waypoint is single-worker (`concurrency: 1`) so the token-bucket state is truly global, not an approximation.

## 7. Related docs

- Roadmap original: [2026-08-19-k3s-mesh-capabilities-roadmap.md](../superpowers/specs/2026-08-19-k3s-mesh-capabilities-roadmap.md)
- Phase I: [design doc](../superpowers/specs/2026-08-22-k3s-phase-i-traffic-resilience-design.md) / [implementation plan](../superpowers/plans/2026-08-22-k3s-phase-i-traffic-resilience.md)
- Phase J: [design doc](../superpowers/specs/2026-08-23-k3s-phase-j-authorization-design.md) / [implementation plan](../superpowers/plans/2026-08-23-k3s-phase-j-authorization.md)
- Phase K: [design doc](../superpowers/specs/2026-08-24-k3s-phase-k-observability-design.md) / [implementation plan](../superpowers/plans/2026-08-24-k3s-phase-k-observability.md)
- Phase L: [design doc](../superpowers/specs/2026-08-25-k3s-phase-l-ratelimit-design.md) / [evaluation notes](../superpowers/specs/2026-08-25-k3s-phase-l-ratelimit-evaluation.md) / [implementation plan](../superpowers/plans/2026-08-25-k3s-phase-l-ratelimit.md)
- Phase K related incident investigations: [compose→k3s NodePort gateway issue](../incidents/2026-08-24-compose-prometheus-grafana-k3s-nodeport-gateway.md), [k3s pod→docker bridge blackhole](../incidents/2026-08-24-k3s-pod-to-docker-bridge-blackhole.md)
- Previous-phase summary: [Phase F+G summary](2026-08-19-k3s-phase-fg-pr-lanes-summary.md)