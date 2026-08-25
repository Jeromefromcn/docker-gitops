# Phase L 限流評估筆記（TrafficExtension + Lua 方案的查證過程）

日期：2026-08-25

本文件是 [L 階段設計](2026-08-25-k3s-phase-l-ratelimit-design.md) 的查證依據。記錄「為什麼兩條原定路徑不可行」「為什麼新增 TrafficExtension + Lua 這條路」的完整證據，供未來讀者（尤其要質疑這個決定的人）追溯。

## 背景

[k3s 服務網格能力補完路線圖](2026-08-19-k3s-mesh-capabilities-roadmap.md) 的 L 階段原定義是「評估性」：評估 Gateway API experimental channel 升級 vs. Istio EnvoyFilter 兩條路徑的成本，**不預設一定要交付**。路線圖還引用了「原生限流（GEP-2257）」作為 experimental channel 的誘因。

本次查證是 opus subagent（121 次工具調用，跨官方文檔 + Istio 源碼 + 集群只讀驗證）完成的，主會話在此基礎上整理。

## 查證結論一：GEP-2257 不是限流，experimental channel 沒有原生限流

- [GEP-2257](https://gateway-api.sigs.k8s.io/geps/gep-2257/) 實際是 **Gateway API Duration 字符串格式標準**（`^([0-9]{1,5}(h|m|s|ms)){1,4}$`），用於 `timeouts.request` 等字段，與限流無關。路線圖把它當作「原生限流（GEP-2257）」是事實錯誤
- Gateway API 官方 [GEP 列表](https://gateway-api.sigs.k8s.io/geps/list/) **沒有任何 rate limiting 的 GEP**（列出的都是 Response Header Filter、HTTPRoute Retries、Timeouts、Session Persistence 等）
- 集群已裝的 **v1.6.1 就是當前最新版** Gateway API（2026-07-16 發布）。其 experimental channel 的 `XBackendTrafficPolicy` 只有 RetryConstraint/SessionPersistence，**無 rate limit 字段**
- **結論：升級 experimental channel 這條路根本不存在，永久關閉**。不是「等它成熟」，是「沒有升級目標」

## 查證結論二：EnvoyFilter 塞 local_ratelimit 在 ambient 下官方不背書

- [Istio 官方限流任務頁](https://istio.io/latest/docs/tasks/policy-enforcement/rate-limit/) 的 local rate limit 示例是「把 `envoy.filters.http.local_ratelimit` 塞進 **sidecar** 的 inbound filter chain」——**整個文檔基於 sidecar 模式**，ambient 只字未提
- EnvoyFilter 參考頁的 patch context 只有 `SIDECAR_INBOUND`/`SIDECAR_OUTBOUND`/`GATEWAY`——全是 sidecar 概念；waypoint 要附加 EnvoyFilter 只能用 `targetRefs`（kind Service/Gateway）
- ambient 官方文檔列出的 waypoint 擴展機制只有 [Wasm](https://istio.io/latest/docs/ambient/usage/extend-waypoint-wasm/) 與 [Lua](https://istio.io/latest/docs/ambient/usage/extend-waypoint-lua/)，**EnvoyFilter 不在其中**
- Istio maintainer **howardjohn** 在 [istio/istio#54391](https://github.com/istio/istio/issues/54391) 明說：「EnvoyFilter very very limited support in ambient」
- 實測坑：[istio/istio#57350](https://github.com/istio/istio/issues/57350)「Ambient 模式下使用 EnvoyFilter 進行限流不生效」（已自動關閉）；[istio/istio#57609](https://github.com/istio/istio/pull/57609)「Fix envoyfilter not working when virtualservice configured」**被棄（abandoned）**
- I 階段還實測過「Gateway API 與 VirtualService 混用同 host 互相覆蓋」的坑，是同一族風險
- **結論：EnvoyFilter 路徑維護風險高、官方不背書。但並未徹底死透**——1.30.3 源碼證明 `context: SIDECAR_INBOUND` + `targetRefs` 可 attach 到 waypoint 並塞 filter（#57350 失敗實為配置用了 `context: GATEWAY`）。作為 v2 選項記錄，見設計文檔「已知限制」

## 查證結論三：外部 rate limit 服務違反資源約束

- 外部方案（Envoy gRPC ratelimit + Redis）要新增兩個 Deployment + 資源配額，違反路線圖「優先複用、不加新元件」硬約束
- `pr-lanes` 沒有真實用戶流量，為不存在的問題加基礎設施，性價比最差
- **結論：排除**

## 新路：TrafficExtension + Lua

查證確認其可行性：

1. **CRD 已就緒**：集群 `kubectl get crd trafficextensions.extensions.istio.io` 存在（`extensions.istio.io/v1alpha1`），隨 istio-base 1.30.3 安裝。schema 含 `lua.inlineCode`（≤64KB）、`match[].mode`（CLIENT/SERVER/CLIENT_AND_SERVER）、`phase`（AUTHN/AUTHZ/STATS）、`targetRefs`、`priority`
2. **官方文檔背書 waypoint Lua 擴展**：[Extend waypoints with Lua scripts](https://istio.io/latest/docs/ambient/usage/extend-waypoint-lua/) 是 ambient 官方列出的 waypoint 擴展機制之一（示例即 `kind: Service` + `mode: SERVER` + `phase: STATS` 結構）
3. **istiod 源碼確認注入機制**（1.30.3）：`pilot/pkg/networking/core/listener_waypoint.go`（waypoint HTTP chain，TrafficExtension pre/post 注入）→ `extension/extensionfilter.go` → `extension/lua.go`（Lua → Envoy lua filter 編譯）；`pilot/pkg/model/policyattachment.go`（`ShouldAttachPolicy` 確認 waypoint 匹配 `targetRefs` Service/Gateway）
4. **Lua 可以返回 429**：Envoy Lua HTTP filter 支援 `handle:respond()` 直接回應，不轉發上游——`respond()` 在 request 階段可用
5. **零新增元件**：純 CRD，Lua 內聯在 waypoint Envoy 進程內

**最大限制**：Lua filter 計數是 **per-worker** 狀態（Envoy 官方文檔：「All Lua environments are per worker thread」）。waypoint 200m CPU limit 大概率 1 worker（= 全局限流），極限 2 worker（≈ 近似限流，上限 ≈ 配置 × 2）。demo 場景可接受。

## 集群現狀（查證時 kubectl 只讀核實）

- k3s v1.36.2+k3s1，Istio 1.30.3 ambient（pilot:1.30.3-distroless / ztunnel:1.30.3）
- Gateway API CRD：BackendTLSPolicy/GatewayClass/Gateway/HTTPRoute/TCPRoute/TLSRoute/UDPRoute/GRPCRoute/ReferenceGrant/ListenerSet——**無 BackendTrafficPolicy、無限流資源**
- Istio CRD：envoyfilters/wasmplugins/trafficextensions/proxyconfigs/telemetries/authorizationpolicies/virtualservices/destinationrules 等
- `pr-lanes`：hello-backend、hello-backend-canary、hello-frontend、waypoint 四個 Deployment；0 條活躍 PR 泳道
- waypoint 上已有 J（AuthorizationPolicy）+ K（mesh-tracing Telemetry）兩疊層
- 集群中目前無任何 EnvoyFilter/ExtensionConfig/WasmPlugin/TrafficExtension/ProxyConfig
- `pr-lanes-quota` requests 125m/320Mi（hard 400m/768Mi）、limits 500m/640Mi（hard 1200m/1536Mi）

## 外部證據來源

**官方文檔**
- Istio ambient waypoint 擴展（Lua）：https://istio.io/latest/docs/ambient/usage/extend-waypoint-lua/
- Istio ambient waypoint 擴展（Wasm）：https://istio.io/latest/docs/ambient/usage/extend-waypoint-wasm/
- TrafficExtension API 參考：https://istio.io/latest/docs/reference/config/proxy_extensions/traffic_extension/
- Istio Lua 任務頁：https://istio.io/latest/docs/tasks/extensibility/lua-scripts/
- Istio 限流任務頁（僅 sidecar）：https://istio.io/latest/docs/tasks/policy-enforcement/rate-limit/
- Envoy Lua HTTP filter（respond/stats/per-worker）：https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/lua_filter
- Envoy local rate limit filter：https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/local_rate_limit_filter
- Gateway API GEP 列表（無限流 GEP）：https://gateway-api.sigs.k8s.io/geps/list/
- GEP-2257（Duration 格式，非限流）：https://gateway-api.sigs.k8s.io/geps/gep-2257/

**Istio 源碼（1.30.3）**
- `pilot/pkg/networking/core/listener_waypoint.go`（waypoint HTTP chain，TrafficExtension 注入）
- `pilot/pkg/networking/core/extension/extensionfilter.go`、`extension/lua.go`（Lua → Envoy lua filter）
- `pilot/pkg/model/policyattachment.go`（`ShouldAttachPolicy`：waypoint 匹配 targetRefs）
- `pilot/pkg/model/push_context.go`（EnvoyFilter workloadSelector 匹配）

**Istio GitHub Issues/PRs**
- #54391（ambient 限流，howardjohn：「EnvoyFilter very very limited support in ambient」）：https://github.com/istio/istio/issues/54391
- #57350（中文 issue「ambient 限流不生效」——實為 context 用錯）：https://github.com/istio/istio/issues/57350
- #57609（修 envoyfilter+virtualservice 衝突的 PR，被棄）：https://github.com/istio/istio/pull/57609
- #60530（TrafficExtension 跨 namespace 坑——僅跨 ns 觸發，pr-lanes 單 ns 不觸發）：https://github.com/istio/istio/issues/60530
