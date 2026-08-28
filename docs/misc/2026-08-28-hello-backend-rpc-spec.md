# hello-backend RPC 化規格

日期:2026-08-28
狀態:草案(供實作 subagent 與驗證手冊共用)
環境:Oracle VPS 單節點 k3s,Istio Ambient,`pr-lanes` 命名空間
關聯:[I 階段設計](2026-08-22-k3s-phase-i-traffic-resilience-design.md)、[驗證手冊](2026-08-26-k3s-mesh-capabilities-roadmap-summary.md)

## 1. 目的

把 `hello-backend` 從純靜態 nginx(只回一個 `index.html`)升級成一個**有真實 rpc 端點、且能製造可驗證故障**的輕量 HTTP 服務。這讓超時/重試/熔斷/故障注入能在「真實上游」上演練,而不是依賴臨時改鏡像。

## 2. 現況

- backend 源碼:`vps_oracle/k3s/apps/hello/backend/`(Dockerfile + index.html),CI 在 `.github/workflows/hello-backend.yml`(push 到 `main` 且動到 `backend/**` 會 build/sign/push 到 ghcr,arm64)。
- k8s 用 pinned digest(`backend-deployment.yaml` 的 `image: ghcr.io/jeromefromcn/hello-backend@sha256:8b3dc...`)。
- frontend:`/api` `proxy_pass` 到 `hello-backend.pr-lanes.svc.cluster.local/`。
- canary:同一個 pinned image,靠 ConfigMap(`hello-backend-canary-conf`)掛載不同 `index.html` 區分版本。

## 3. 目標設計

### 3.1 服務

- 輕量 HTTP 服務(建議 Python + 內建 http.server / Flask,或 Go net/http;選擇能跑在 `nginx-unprivileged` 同等約束的)。保留 port `8080`。
- 端點:
  - `GET /`:回 HTML,內容 = 目前 `index.html`(保留 canary 字樣辨識機制)。
  - `GET /slow`:可操控延遲後回 200。預設例如 15s(供超時驗證,> timeout 10s)。
  - `GET /fail-503` / `GET /fail-500`:立即回對應狀態碼(供重試/熔斷驗證)。
  - (可選)`/healthz`:給 probe 用,回 200。

### 3.2 保留的既有行為

- **canary 機制不變**:canary 仍用同一鏡像 + ConfigMap 掛不同內容區分版本。→ 因此 `index.html` 必須仍是「從檔案/ConfigMap 讀取」,不是硬編碼進 app 裡。建議 app 從 `/usr/share/nginx/html/index.html`(或 env `INDEX_HTML_PATH`)讀取。
- **liveness/readiness probe 不變**:probe 用 `httpGet path: /`。若 `/` 有副作用(不該有),probe 可改用 `/healthz` 並同步改 k8s YAML。
- **資源限制/securityContext/ServiceAccount 不變**。
- **CI/Trivy/Cosign 流程不變**(context 仍 `vps_oracle/k3s/apps/hello/backend`)。

### 3.3 故障端點與 VirtualService 的關係

- `/slow`、`/fail-503` 等是**真實上游端點**,由 VirtualService 的 `timeout: 10s`、`retries`、`outlierDetection` 作用於其上。這與 `x-fault-test: delay/abort`(代理本地的故障注入)是**不同層次**——手冊要講清楚兩者區別。
- 保留 VirtualService 現有規則(90/10 權重 + timeout + retries + fault 規則)。

## 4. 驗收條件

1. `docker build` 成功,image 在 arm64 能跑,`/` 回 index.html 內容、`/slow` 延遲後回 200、`/fail-503`/`/fail-500` 回對應碼。
2. canary 版本(同一鏡像 + 不同 ConfigMap)仍能靠 `/` 內容區分。
3. CI 能 build/sign/push,Trivy 過、Cosign 簽。
4. k8s 的 `backend-deployment.yaml` 更新到新 digest(由實作 subagent 或後續手動更新)。
5. 不破壞現有 pr-lanes 其他功能(J/K/L 的 AuthorizationPolicy、Telemetry、TrafficExtension 不受影響)。

## 5. 非目標(刻意不做)

- 不引入 gRPC。
- 不新增「backend 對外呼叫 upstream」的依賴(那超出此規格,後續可再加)。
- 不改 frontend 的 proxy_pass 方式(仍走 HTTP)。
