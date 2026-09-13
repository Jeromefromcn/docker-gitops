# hello-backend RPC-ification Spec

Date: 2026-08-28
Status: draft (shared by the implementation subagent and the verification manual)
Environment: Oracle VPS single-node k3s, Istio Ambient, `pr-lanes` namespace
Related: [Phase I design](2026-08-22-k3s-phase-i-traffic-resilience-design.md), [verification manual](2026-08-26-k3s-mesh-capabilities-roadmap-summary.md)

## 1. Purpose

Upgrade `hello-backend` from a purely static nginx (serving only an `index.html`) into a lightweight HTTP service **with real RPC endpoints and the ability to produce verifiable failures**. This lets timeout/retry/circuit-breaking/fault-injection be drilled against the "real upstream" rather than relying on temporarily modifying the image.

## 2. Current state

- Backend source: `vps_oracle/k3s/apps/hello/backend/` (Dockerfile + index.html). CI in `.github/workflows/hello-backend.yml` (push to `main` that touches `backend/**` builds/signs/pushes to ghcr, arm64).
- k8s uses a pinned digest (`image: ghcr.io/jeromefromcn/hello-backend@sha256:8b3dc...` in `backend-deployment.yaml`).
- Frontend: `/api` `proxy_pass` to `hello-backend.pr-lanes.svc.cluster.local/`.
- Canary: same pinned image, with version distinguished via a ConfigMap (`hello-backend-canary-conf`) mounting a different `index.html`.

## 3. Target design

### 3.1 Service

- A lightweight HTTP service (Python + built-in http.server / Flask, or Go net/http is suggested; choose something that can run under constraints equivalent to `nginx-unprivileged`). Keep port `8080`.
- Endpoints:
  - `GET /`: returns HTML, content = the current `index.html` (preserving the canary-label identification mechanism).
  - `GET /slow`: controllable delay then 200. Default e.g. 15s (for timeout verification, > timeout 10s).
  - `GET /fail-503` / `GET /fail-500`: immediately return the corresponding status code (for retry/circuit-breaker verification).
  - (optional) `/healthz`: for probes, returns 200.

### 3.2 Preserved existing behavior

- **Canary mechanism unchanged**: canary still uses the same image + ConfigMap mounting different content to distinguish versions. → Therefore `index.html` must still be "read from file/ConfigMap", not hardcoded into the app. The app is suggested to read from `/usr/share/nginx/html/index.html` (or env `INDEX_HTML_PATH`).
- **liveness/readiness probes unchanged**: probes use `httpGet path: /`. If `/` has side effects (it should not), probes can switch to `/healthz` and update the k8s YAML accordingly.
- **Resource limits/securityContext/ServiceAccount unchanged**.
- **CI/Trivy/Cosign flow unchanged** (context still `vps_oracle/k3s/apps/hello/backend`).

### 3.3 Relationship between failure endpoints and VirtualService

- `/slow`, `/fail-503`, etc. are **real upstream endpoints**, acted upon by the VirtualService's `timeout: 10s`, `retries`, and `outlierDetection`. These are a **different layer** from `x-fault-test: delay/abort` (proxy-local fault injection) — the manual must clearly explain the difference between the two.
- Keep the VirtualService's existing rules (90/10 weight + timeout + retries + fault rules).

## 4. Acceptance criteria

1. `docker build` succeeds; the image runs on arm64; `/` returns index.html content, `/slow` delays then returns 200, `/fail-503`/`/fail-500` return the corresponding codes.
2. The canary version (same image + different ConfigMap) can still be distinguished via the `/` content.
3. CI can build/sign/push; Trivy passes; Cosign signs.
4. k8s `backend-deployment.yaml` is updated to the new digest (by the implementation subagent or a later manual update).
5. No regression to other existing pr-lanes features (J/K/L's AuthorizationPolicy, Telemetry, TrafficExtension are unaffected).

## 5. Non-goals (deliberately out of scope)

- No gRPC.
- No new "backend calls upstream" dependency (that exceeds this spec; it can be added later).
- No change to the frontend's proxy_pass approach (still HTTP).