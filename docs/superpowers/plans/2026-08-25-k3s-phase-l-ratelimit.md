# K3s Phase L — Rate Limit (TrafficExtension + Lua) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fixed-window token-bucket rate limit to `hello-backend`'s traffic in `pr-lanes` via an Istio 1.30 `TrafficExtension` CRD with an inline Lua filter on the `waypoint`, returning HTTP 429 + `x-envoy-ratelimited: true` when the threshold is exceeded — pure CRD, zero new components, zero quota impact.

**Architecture:** One new `TrafficExtension` resource (`extensions.istio.io/v1alpha1`) in `vps_oracle/k3s/apps/hello/k8s/`, attached via `targetRefs: [{kind: Service, name: hello-backend}]` + `match: [{mode: SERVER}]` + `phase: STATS`. Because `hello-backend` Service carries `istio.io/use-waypoint: waypoint`, istiod attaches the generated Envoy Lua filter to the waypoint's HTTP filter chain. The Lua code keeps a fixed-window counter (60s window, 60 req/worker) in per-worker global state, using `request_handle:timestamp()` (ms since epoch) and `request_handle:respond()` for the 429. ArgoCD (`hello` Application, path `vps_oracle/k3s/apps/hello/k8s`) syncs it automatically.

**Tech Stack:** Kubernetes plain manifest, `extensions.istio.io/v1alpha1` `TrafficExtension` (Istio 1.30.3, confirmed live), Lua (Envoy Lua filter semantics), ArgoCD (`hello` Application, automated prune+selfHeal), `kubectl exec` into `hello-frontend` (has `curl`) for verification.

**Spec:** [docs/superpowers/specs/2026-08-25-k3s-phase-l-ratelimit-design.md](../specs/2026-08-25-k3s-phase-l-ratelimit-design.md)

**Depends on:** Phase K (complete, merged to main). Independent of other phases.

## Global Constraints

- **Git-first, ArgoCD syncs.** Every k3s mutation in this plan is a file commit to `main`, synced by the existing `hello` ArgoCD Application (`path: vps_oracle/k3s/apps/hello/k8s`, `automated: {prune: true, selfHeal: true}`). **Never `kubectl apply`/`patch`/`edit` a live k3s resource** — `selfHeal` will revert it. Read-only `kubectl get/describe/exec/logs` diagnostics are always fine.
- **Only one file is created in this whole plan:** `vps_oracle/k3s/apps/hello/k8s/hello-backend-ratelimit-trafficextension.yaml`. Nothing else in the repo changes (the design/plan docs are already committed; the roadmap update is a separate final task).
- **`pr-lanes-quota` is unaffected.** The `TrafficExtension` is a pure control-plane resource — zero CPU/memory request/limit. Confirm `kubectl -n pr-lanes describe resourcequota pr-lanes-quota` is unchanged after the sync (should stay `requests.cpu: 125m/400m`, `requests.memory: 320Mi/768Mi`, `limits.cpu: 500m/1200m`, `limits.memory: 640Mi/1536Mi`).
- **`hello-backend` and `hello-backend-canary` Services both carry `istio.io/use-waypoint: waypoint`** — confirmed live. The PR-lane Service (`hello-backend-pr-N`) does NOT, but its HTTPRoute `parentRefs` points at `hello-backend` Service, so PR-lane traffic still flows through the waypoint and is rate-limited. Direct (waypoint-bypassing) calls to `hello-backend-pr-N.svc` are NOT rate-limited — this is a documented, accepted boundary (see spec "已知限制").
- **Lua filter is per-worker state.** The waypoint pod runs Envoy with `concurrency` derived from its 200m CPU limit — almost certainly 1 worker on this 4-core host, making the counter effectively global. If it turns out to be 2 workers, the effective limit is ~2× configured. This is accepted for the demo namespace (spec "已知限制").
- **Lua semantics (Envoy Lua filter):** `request_handle:timestamp()` returns milliseconds since epoch (confirmed from Envoy docs). File-level `local` globals in `inlineCode` are shared across requests within one worker thread. `request_handle:respond(headers, body)` sends a direct response without upstream call (request flow only). `stats()` is available for counters but this plan uses plain Lua globals for simplicity.
- **Threshold:** 60 req/min/worker, 60-second fixed window. Generous enough that normal traffic never trips it, tight enough to observe the 429 in a quick test.
- **This checkout has had concurrent-session activity before.** Run `git status` and `git log --oneline -3` before every commit; only `git add` the file this plan touches, never `git add -A`.
- **Read-only diagnostics at any time.** The one documented exception for live k3s trial-and-error (disable `selfHeal`, re-enable) is NOT needed here — everything is git-first.

---

### Task 1: Add the `TrafficExtension` rate-limit CRD

**Files:**
- Create: `vps_oracle/k3s/apps/hello/k8s/hello-backend-ratelimit-trafficextension.yaml`

**Interfaces:**
- Consumes: the existing `hello` ArgoCD Application (path `vps_oracle/k3s/apps/hello/k8s`, already synced) — it auto-picks up any new YAML under that directory.
- Produces: the `hello-backend-ratelimit` `TrafficExtension` resource in `pr-lanes`. No later task consumes its output directly (verification reads cluster state).

- [ ] **Step 1: Confirm current state before touching anything**

```bash
kubectl -n argocd get application hello
kubectl -n pr-lanes get svc hello-backend hello-backend-canary -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.labels.istio\.io/use-waypoint}{"\n"}{end}'
kubectl -n pr-lanes describe resourcequota pr-lanes-quota
git status
git log --oneline -3
```

Expected: `hello` Application `Synced`+`Healthy`; both Services show `use-waypoint: waypoint`; quota shows `requests 125m/320Mi`, `limits 500m/640Mi`; clean git status.

- [ ] **Step 2: Write the TrafficExtension YAML**

Create `vps_oracle/k3s/apps/hello/k8s/hello-backend-ratelimit-trafficextension.yaml`:

```yaml
# vps_oracle/k3s/apps/hello/k8s/hello-backend-ratelimit-trafficextension.yaml
# Phase L: fixed-window token bucket rate limit on hello-backend's waypoint.
#
# Attaches to the `waypoint` (via `targetRefs: Service hello-backend`, which
# carries istio.io/use-waypoint=waypoint) and injects a Lua filter at phase
# STATS. Limit is per-worker (Envoy Lua global state is per worker thread);
# with the waypoint's 200m CPU limit this is almost certainly 1 worker, so the
# counter is effectively global. PR-lane traffic (HTTPRoute parentRefs ->
# hello-backend Service) flows through this waypoint and IS rate-limited;
# direct waypoint-bypassing calls to hello-backend-pr-N.svc are NOT (accepted
# boundary, see spec "已知限制").
apiVersion: extensions.istio.io/v1alpha1
kind: TrafficExtension
metadata:
  name: hello-backend-ratelimit
  namespace: pr-lanes
spec:
  targetRefs:
    - kind: Service
      name: hello-backend
  match:
    - mode: SERVER
  phase: STATS
  lua:
    inlineCode: |
      -- Fixed-window token bucket: 60 req per 60s window, per worker.
      -- request_handle:timestamp() returns ms since epoch (Envoy Lua API).
      local WINDOW_MS = 60000
      local LIMIT = 60

      -- Per-worker state (file-level globals shared across requests on this
      -- worker thread; each worker keeps its own copy).
      local window_start_ms = 0
      local count = 0

      function envoy_on_request(request_handle)
        local now_ms = request_handle:timestamp()
        if now_ms - window_start_ms >= WINDOW_MS then
          -- New window (also covers first request: window_start_ms=0, now_ms
          -- is ~1.7e12 ms since epoch, so this always fires on first call)
          window_start_ms = now_ms
          count = 0
        end
        count = count + 1
        if count > LIMIT then
          request_handle:respond(
            {[":status"] = "429", ["x-envoy-ratelimited"] = "true"},
            "rate limit exceeded"
          )
          -- respond() ends the request flow; return explicitly to make that clear
          return
        end
      end
```

- [ ] **Step 3: Validate the YAML locally (kubectl dry-run is NOT allowed on live cluster — use client-side validation)**

```bash
kubectl apply --dry-run=client -f vps_oracle/k3s/apps/hello/k8s/hello-backend-ratelimit-trafficextension.yaml -o yaml > /dev/null && echo "YAML parses OK"
```

Expected: `YAML parses OK`. This is client-side only (no cluster mutation).

- [ ] **Step 4: Commit and push to main**

```bash
git add vps_oracle/k3s/apps/hello/k8s/hello-backend-ratelimit-trafficextension.yaml
git commit -m "Add hello-backend rate limit via TrafficExtension + Lua on waypoint"
git push origin main
```

Expected: commit succeeds, push succeeds. (Check `git status`/`git log` first per Global Constraints.)

- [ ] **Step 5: Wait for ArgoCD to sync**

```bash
kubectl -n argocd get application hello
kubectl -n pr-lanes get trafficextension hello-backend-ratelimit
```

Expected: `hello` Application eventually `Synced`+`Healthy`; the `TrafficExtension` resource exists (`kubectl get trafficextension hello-backend-ratelimit -n pr-lanes`). If ArgoCD reports an error, read the Application's conditions:

```bash
kubectl -n argocd get application hello -o jsonpath='{.status.conditions}'
```

- [ ] **Step 6: Confirm the Lua filter actually landed in the waypoint's Envoy config**

The waypoint pod is distroless but ships `pilot-agent` (confirmed live: `/usr/local/bin/pilot-agent` runs). Dump the waypoint's Envoy config and confirm the `envoy.filters.http.lua` filter with our code is present:

```bash
WP=$(kubectl get pods -n pr-lanes -o name | grep waypoint | head -1 | cut -d/ -f2)
kubectl exec -n pr-lanes "$WP" -c istio-proxy -- /usr/local/bin/pilot-agent request GET config_dump 2>/dev/null | grep -c 'envoy.filters.http.lua'
kubectl exec -n pr-lanes "$WP" -c istio-proxy -- /usr/local/bin/pilot-agent request GET config_dump 2>/dev/null | grep -o 'rate limit exceeded' | head -1
```

Expected: the first grep returns `>= 1` (lua filter present); the second returns `rate limit exceeded` (our code is in the dump). If the grep count is 0, the TrafficExtension did not attach — check the Application conditions (Step 5) and the istiod logs (`kubectl logs -n istio-system deploy/istiod --tail=50 | grep -i trafficextension`).

- [ ] **Step 7: Commit checkpoint (no code change, just confirm clean)**

```bash
git status
git log --oneline -3
```

Expected: working tree clean (only the committed YAML), 3 most recent commits visible including this plan's commit.

---

### Task 2: Verify the rate-limit behavior

**Files:** (none — read-only verification)

**Interfaces:**
- Consumes: the `TrafficExtension` from Task 1 (must be synced and attached — Task 1 Step 6 must have passed).
- Produces: verification evidence that the rate limit works, and that it coexists with the existing J (RBAC) and K (tracing) layers.

- [ ] **Step 1: Confirm baseline traffic works**

```bash
FE=$(kubectl get pods -n pr-lanes -l app=hello-frontend -o name | head -1 | cut -d/ -f2)
kubectl exec -n pr-lanes "$FE" -- curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/api/
```

Expected: `200`. This confirms the frontend→waypoint→backend path works before rate-limit testing (confirmed working during planning, re-verify).

- [ ] **Step 2: Trip the rate limit with a burst of requests**

Send 100 requests quickly (well over the 60/window limit). Use the frontend's `/api/` path (proxies to `hello-backend.svc` through the waypoint):

```bash
FE=$(kubectl get pods -n pr-lanes -l app=hello-frontend -o name | head -1 | cut -d/ -f2)
for i in $(seq 1 100); do
  kubectl exec -n pr-lanes "$FE" -- curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/api/ 2>/dev/null
done | sort | uniq -c
```

Expected: a mix of `200` (first ~60) and `429` (the rest). Count of `429` should be roughly 40, count of `200` roughly 60. If ALL are `200` (no 429), the limit did not engage — see Task 3 Step 2 diagnostics.

- [ ] **Step 3: Confirm the 429 response carries the marker header**

```bash
FE=$(kubectl get pods -n pr-lanes -l app=hello-frontend -o name | head -1 | cut -d/ -f2)
kubectl exec -n pr-lanes "$FE" -- curl -s -i http://127.0.0.1:8080/api/ 2>/dev/null | head -10
```

Run this while the window is still over-limit (within 60s of Step 2's burst). Expected: `HTTP/1.1 429` and `x-envoy-ratelimited: true` in the response headers.

- [ ] **Step 4: Confirm the window resets**

Wait 60+ seconds, then send a single request:

```bash
sleep 65
FE=$(kubectl get pods -n pr-lanes -l app=hello-frontend -o name | head -1 | cut -d/ -f2)
kubectl exec -n pr-lanes "$FE" -- curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/api/
```

Expected: `200` — the window reset and the counter restarted.

- [ ] **Step 5: Confirm J-layer RBAC still works (unauthorized caller still rejected)**

The J-layer `AuthorizationPolicy` (Policy 1, attached to waypoint) allows only `hello-frontend-sa` identity to reach `hello-backend`. Launch a throwaway debug pod with the `default` SA and confirm it's rejected:

```bash
kubectl -n pr-lanes run rl-debug-check --rm -i --restart=Never \
  --image=curlimages/curl --command -- sh -c \
  'curl -s -o /dev/null -w "%{http_code}" http://hello-backend.pr-lanes.svc.cluster.local/' 2>&1
```

Expected: NOT `200` (likely `403` from RBAC, or connection refused). If it returns `200`, the J-layer is broken — stop and investigate before proceeding. (Note: this debug pod uses the `default` SA, which is NOT `hello-frontend-sa`, so Policy 1 should reject it.)

- [ ] **Step 6: Confirm K-layer tracing still works**

```bash
kubectl -n pr-lanes get telemetry mesh-tracing
kubectl -n pr-lanes describe resourcequota pr-lanes-quota
```

Expected: `mesh-tracing` Telemetry still exists; quota unchanged (`requests 125m/320Mi`, `limits 500m/640Mi`). (Tracing itself — spans reaching Jaeger — is best confirmed in Jaeger UI, but the Telemetry CR existing and the quota being untouched is the necessary condition; if Jaeger UI is reachable via `mesh-observability` NodePort, optionally verify a span appears.)

- [ ] **Step 7: Confirm the actual filter-chain order and worker count (spec verification items 10-11)**

```bash
WP=$(kubectl get pods -n pr-lanes -o name | grep waypoint | head -1 | cut -d/ -f2)
# Lua filter position vs RBAC filter — dump the filter chain names in order
kubectl exec -n pr-lanes "$WP" -c istio-proxy -- /usr/local/bin/pilot-agent request GET config_dump 2>/dev/null \
  | grep -oE 'envoy\.filters\.http\.(lua|rbac)' | head -20
```

Expected: the grep shows both `envoy.filters.http.lua` and `envoy.filters.http.rbac`, and the **order** reveals whether Lua (STATS) comes before or after RBAC (AUTHZ). Record the observed order. This is informational — either order is acceptable for the demo — but the plan must record which it is, to backfill the spec's "已知限制" note.

For worker count (spec item 11), check the waypoint's Envoy server info or concurrency:

```bash
kubectl exec -n pr-lanes "$WP" -c istio-proxy -- /usr/local/bin/pilot-agent request GET server_info 2>/dev/null | grep -iE 'concurrency|workers'
```

Expected: records the worker count. If unavailable via server_info, check the waypoint Deployment's `PILOT_...`/`--concurrency` or accept the documented assumption (1 worker at 200m limit) and note it.

- [ ] **Step 8: Commit checkpoint (no code change, verification only)**

```bash
git status
```

Expected: clean working tree (no code change in this task). Record the verification results (the numbers from Step 2, the order from Step 7) — they belong in the roadmap update task.

---

### Task 3: Update the roadmap and close out Phase L

**Files:**
- Modify: `docs/superpowers/specs/2026-08-19-k3s-mesh-capabilities-roadmap.md`

**Interfaces:**
- Consumes: verification evidence from Task 2 (the actual filter order and worker count from Step 7; the 429 confirmation from Steps 2-4).
- Produces: the roadmap's L row marked complete, with the GEP-2257 fact-error correction and a pointer to the L-phase design doc.

- [ ] **Step 1: Update the roadmap L row**

In `docs/superpowers/specs/2026-08-19-k3s-mesh-capabilities-roadmap.md`, change the L row (currently "評估性" / "不預設一定要交付") to completed, and fix the GEP-2257 error in the "現狀約束" section.

The L row currently reads:
```
| L. 限流（評估性） | 評估 Gateway API experimental channel 升級 vs. Istio EnvoyFilter 兩條路徑的成本，**不預設一定要交付** | 一份取捨紀錄；若評估結果是「不值得」，路線圖到此為止，不強行實作 | I |
```

Replace with:
```
| ~~L. 限流~~（✅ 已完成） | 評估後未走原定兩條路徑（experimental channel 無限流 API、EnvoyFilter 在 ambient 不背書），改採 Istio 1.30 `TrafficExtension` + Lua 固定窗口令牌桶，附加在 waypoint 上，`hello-backend` 限流 60 req/min，超限回 429 | `pr-lanes` 的 `hello-backend` 流量有限流保護，驗證 429 + `x-envoy-ratelimited`；完整查證與取捨見 [L 階段設計文檔](2026-08-25-k3s-phase-l-ratelimit-design.md) | I |
```

- [ ] **Step 2: Fix the GEP-2257 error in the roadmap's "現狀約束"**

The line currently reads:
```
- **Gateway API 裝的是 standard channel**（[standard-install.yaml](../../../vps_oracle/k3s/gateway-api/standard-install.yaml)），不含 experimental 功能通道——原生限流（GEP-2257）等實驗性 API 目前不存在，這直接影響 Phase L 的可行性評估，不是配置問題而是安裝範圍問題
```

Replace with:
```
- **Gateway API 裝的是 standard channel**（[standard-install.yaml](../../../vps_oracle/k3s/gateway-api/standard-install.yaml)），不含 experimental 功能通道——**原標記「原生限流（GEP-2257）」有誤**：GEP-2257 實為 Duration 字符串格式標準，與限流無關；Gateway API 官方 GEP 列表至今沒有 rate limiting API，experimental channel 亦無。這使「升級 experimental 拿原生限流」這條路徑不成立，Phase L 最終改採 `TrafficExtension` + Lua（見 L 階段設計文檔）
```

- [ ] **Step 3: Add the L-phase design doc link to the roadmap's "各階段設計文檔" section**

```markdown
- L：✅ 已完成 — [設計文檔](2026-08-25-k3s-phase-l-ratelimit-design.md)（含評估筆記 [2026-08-25-k3s-phase-l-ratelimit-evaluation.md](2026-08-25-k3s-phase-l-ratelimit-evaluation.md)）、[實作計畫](../plans/2026-08-25-k3s-phase-l-ratelimit.md)（已打勾）
```

Append this line after the K row.

- [ ] **Step 4: Update the "各階段設計備註" — add a note that the L evaluation reversed the original two paths**

After the existing "L 階段：為什麼限流只是「評估」不是「承諾交付」" section, append a short "L 階段實作結果（2026-08-25 完成）" subsection documenting the pivot: the two originally-planned paths were both dead ends (with one-line evidence each), and the actual implementation used `TrafficExtension` + Lua. Keep it concise; the design doc has the full detail.

- [ ] **Step 5: Commit the roadmap update**

```bash
git add docs/superpowers/specs/2026-08-19-k3s-mesh-capabilities-roadmap.md
git commit -m "Mark phase L complete: TrafficExtension + Lua rate limit on hello-backend waypoint"
git push origin main
```

Expected: commit + push succeed.

- [ ] **Step 6: Final verification — everything synced and healthy**

```bash
kubectl -n argocd get application hello
kubectl -n pr-lanes get trafficextension
kubectl -n pr-lanes get telemetry mesh-tracing
kubectl -n pr-lanes describe resourcequota pr-lanes-quota
git status
git log --oneline -5
```

Expected: `hello` Application `Synced`+`Healthy`; `hello-backend-ratelimit` TrafficExtension exists; `mesh-tracing` Telemetry exists; quota unchanged; clean working tree; recent commits include the YAML + roadmap update.
