# K3s 服務網格能力補完路線圖

日期：2026-08-19

## 背景

[F+G 階段](2026-08-18-k3s-phase-fg-mesh-pr-lanes-design.md)在 `pr-lanes` 命名空間裝好了 Istio Ambient（istiod + ztunnel + istio-cni + waypoint）+ Gateway API，交付物刻意收斂到「PR 預覽泳道」單一場景：只做了 header-based 的兩版本路由，沒有觸碰金絲雀權重、超時重試、細粒度授權、可觀測性接入、熔斷、限流這些服務網格的其餘標準能力。

[container-topology v3](../../container-topology/v3.md) 定稿後對照業界服務網格四大類能力（流量管理、安全、可觀測性、彈性）逐項盤點了現狀，結論分三類：

- **已具備**：mTLS 雙向認證、健康檢查、header 分流形態的灰度發布、金絲雀權重路由（90/10）、超時重試、熔斷（outlier detection）、故障注入——ztunnel/waypoint/HTTPRoute 已經在跑，I 階段（2026-08-22）再補齊了權重/超時/重試/熔斷/故障注入（見下方 I 實作結果）
- **沒配置**：細粒度存取控制（AuthorizationPolicy）、指標接入、日誌收集——元件都已經在集群裡運行，純粹是沒寫對應的 YAML
- **未具備**：分散式追蹤、限流——目前沒有對應資源，其中限流還牽涉 Gateway API channel 選型

本文件把「沒配置」與「未具備」這兩類收斂成路線圖，延續 F+G 之後的下一批階段。範圍**只涵蓋 `pr-lanes` 命名空間**——`lab-environment` 未入網，其餘業務服務已在 8/18 遷回 compose，不受本路線圖影響。

## 目標

- 補齊的能力**優先複用已運行的元件**，不因為要補一項能力就整套重裝——F+G 已經把預算逼近上限，這條約束比 F+G 當時更緊
- 純 YAML/CRD 配置能做到的，不新增 Deployment；真的需要新元件時，優先接到 `lab-environment` 既有的 Prometheus/Loki/Jaeger，不在 `pr-lanes` 另起一套
- 安全敏感的變更（授權策略）獨立走一次 spec → plan → implement → verify，不跟低風險的流量治理配置混在同一個交付物裡——比照 E 階段供應鏈安全獨立於 D 階段服務遷移的先例
- 誠實評估：確認不划算或條件不成熟的能力（限流）明確列為「評估後可能不做」，不为了列表完整硬做

## 現狀約束

- **資源比 F+G 當時更緊**：現場 `free -h` 實測（2026-08-19）—— 23Gi 總量，僅剩 813Mi 真正空閒，`available` 6.2Gi（含可回收快取），swap 4Gi 已用掉 3.4Gi（85%）。這比 [2026-08-05 路線圖](2026-08-05-k3s-cloud-native-platform-roadmap.md)當初記錄的「可用約 6.4Gi」更緊張，且 swap 使用率本身就是需要留意的信號——本路線圖任何一階段若觀察到 OOMKilled 或 swap 繼續攀升，應優先暫停評估，不是硬著頭皮往下裝
- **`pr-lanes-quota` 本來就卡得很緊**：`requests.cpu: 400m / requests.memory: 768Mi`，`limits.cpu: 1200m / limits.memory: 1536Mi`（[resourcequota.yaml](../../../vps_oracle/k3s/apps/hello/k8s/resourcequota.yaml)）。istiod-values.yaml 裡已經記錄過一次「waypoint 預設資源請求本身就撐爆這個 quota」的教訓，本路線圖新增的任何資源都要先確認不會撞到這個上限，尤其是熔斷/限流這類需要額外 sidecar 或 filter 開銷的能力
- **Gateway API 裝的是 standard channel**（[standard-install.yaml](../../../vps_oracle/k3s/gateway-api/standard-install.yaml)），不含 experimental 功能通道——原生限流（GEP-2257）等實驗性 API 目前不存在，這直接影響 Phase L 的可行性評估，不是配置問題而是安裝範圍問題
- **`lab-environment` 未入網格**：Prometheus/Loki/Jaeger 都在 `lab-environment`，`pr-lanes` 要接上它們，流量得跨命名空間——這正是這兩天兩次踩過的坑（NPM→NodePort 黑洞事故、Cilium socket-LB 收窄的連鎖反應）的同類風險：网络层配置看似独立，实际互相耦合。Phase K 動工前必須先確認 Cilium NetworkPolicy 允不允許這條跨命名空間路徑，不能假設「同集群就默認互通」

## 階段路線圖

| 階段 | 目標 | 交付物 | 依賴 |
|---|---|---|---|
| ~~I. 流量彈性與路由治理~~（✅ 已完成） | 金絲雀權重路由、超時重試、熔斷（outlier detection）、故障注入——全部靠新增 Istio/Gateway API 資源達成，零新元件（除了一個 content-variant 的 `hello-backend-canary` Deployment） | `pr-lanes` 具備完整的流量治理能力，可用於後續的漸進式發布與 chaos 測試 | F+G |
| J. 細粒度存取控制 | AuthorizationPolicy，限定 `hello-frontend`→waypoint→`hello-backend`（及各 PR 泳道 backend）之間的合法呼叫關係 | 網格內東西向流量有身份層級的准入控制，非法呼叫在 ztunnel/waypoint 層被拒絕 | F+G，獨立於 I |
| K. 可觀測性接入 | 指標（istiod/ztunnel/waypoint 的 Prometheus 端點）、日誌（waypoint access log）、追蹤（Envoy trace）全部指向 `lab-environment` 既有的 Prometheus/Loki/Jaeger，不在 `pr-lanes` 新裝 | PR 泳道流量的指標/日誌/追蹤能在既有的 Grafana/Jaeger UI 查到 | F+G，需先確認跨命名空間網路路徑（見現狀約束） |
| L. 限流（評估性） | 評估 Gateway API experimental channel 升級 vs. Istio EnvoyFilter 兩條路徑的成本，**不預設一定要交付** | 一份取捨紀錄；若評估結果是「不值得」，路線圖到此為止，不強行實作 | I |

## 各階段設計備註

### I 階段：為什麼四項能力合併成一個階段

金絲雀權重、超時重試、熔斷、故障注入這四項雖然語意不同，但實作上高度同質：全部是「istiod/waypoint 已經在讀的 CRD，新增一份 YAML 就生效」，不涉及新元件、風險彼此獨立（改熔斷設定不會影響超時重試）。**唯一的資源預算例外是金絲雀權重本身**——Gateway API 的權重分流跨 Service 而非 subset，要有一個真實的第二份版本就得新增 `hello-backend-canary` Deployment，實作後 `pr-lanes-quota` 從 `400m/512Mi` 升到 `500m/640Mi`，泳道容量從 8 條降到 7 條（這個取捨在實作計畫的 Global Constraints 裡有記錄，屬已接受的代價）。跟 F+G 因為「namespace-per-PR 模型 vs waypoint 集中模型」互相打架而不得不合併的情況不同，這裡純粹是「同類工作沒有必要拆成四個 spec → plan → implement → verify 循環」的效率考量。

金絲雀權重（原設計走 HTTPRoute `backendRefs[].weight`）與現有的 header 路由（[lane/httproute.yaml](../../../vps_oracle/k3s/apps/hello/lane/httproute.yaml)）共用同一個 Gateway/waypoint，兩者不衝突：header match 優先於權重分流（Gateway API 合併規則本來就是 match 數量優先），可以並存——PR 泳道繼續用 header 精準路由，baseline 流量另外切一部分做金絲雀驗證新版本，互不干擾。

> **I 實作修正**：實作時金絲雀權重最終改由 `VirtualService` 承載（`backend-httproute.yaml` 因與 `VirtualService` 同 host 衝突而刪除，見下方 I 實作結果），而非 HTTPRoute。不過「與既有 header 路由互不干擾」的結論依然成立——`lane/httproute.yaml` 的 PR 泳道 header match 未被觸碰，實作驗證時也確認過其優先權不受影響。

故障注入需要 Istio 的 `VirtualService`（不是 Gateway API 核心資源），但 `VirtualService` 這個 CRD 隨 istio-base 安裝時就已經存在，不需要另外裝元件——放進本階段而不是「未具備」的獨立階段，是因為它跟熔斷/超時重試一樣只是「CRD 已經在但沒寫資源」。

#### I 階段實作結果（2026-08-22 完成，已合入 main 並在線驗證）

I 階段已完成並合入 `main`，實作過程產生了兩處偏離原設計、但已回寫進設計文檔的決策，這裡記錄在路線圖層級：

- **金絲雀權重改由 `VirtualService` 承載，`backend-httproute.yaml` 被刪除**。原設計預期 `HTTPRoute.backendRefs[].weight`（Gateway API）管權重分流、`VirtualService` 只管故障注入，兩者共存。實作時（Task 3）發現兩者在同一 host 上**無法共存**：`HTTPRoute` 的規則沒有任何 header 匹配條件，屬於「無條件」規則，Istio 把 Gateway API 與傳統 API 的規則合併進 waypoint 的同一張 Envoy 路由表時，這種無條件規則會整條覆蓋掉同 host 的 `VirtualService` 規則，導致故障注入的 header match 從未被 Envoy 評估到。最終處置是刪除整份 `backend-httproute.yaml`，讓 `VirtualService` 成為 `hello-backend` host 唯一的路由設定來源，一次扛起金絲雀權重（90/10）、timeout（10s）、重試（2 次）、故障注入（`x-fault-test: delay`/`abort`）四項功能。
- **故障注入的 `fault.delay` 與同規則的 `timeout` 疊加不生效**。實測 `x-fault-test: delay`（`fixedDelay: 15s`）搭配同規則 `timeout: 10s`，請求跑完整整 ~15s 才回應 `200`，沒有被 timeout 截斷——推測是 route timeout 計時器要到 router filter 開始處理 upstream request 才起算，晚於 fault filter 的 decode-time delay。這是 Istio 的行為限制，不是配置錯誤；要驗證 timeout 對真實慢請求的效果，無法用 fault injection 測，留待後續階段。
- **熔斷（outlier detection）已下發到 Envoy dataplane**（`consecutive5xxErrors: 3, interval: 30s, baseEjectionTime: 30s, maxEjectionPercent: 100`，`maxEjectionPercent: 100` 因兩個 backend 皆 `replicas: 1` 而改，50% 會無條件捨去成 0 個可踢 endpoint）。但**行為級的 ejection 未能以故障注入觸發**——`x-fault-test: abort` 是 Envoy 的 local reply，根本不會派送到 upstream cluster，outlier detection 的 `consecutive5xxErrors` 永遠看不到。真要驗證 ejection 得讓 upstream 真的收到請求並回 5xx（改 app 或讓 pod 故障），超出本階段 CRD-only 範圍，留待後續階段。

完整細節見 [I 階段設計文檔](2026-08-22-k3s-phase-i-traffic-resilience-design.md) 的「已知限制 / 失敗模式」。

### J 階段：為什麼授權策略要獨立於 I 階段

AuthorizationPolicy 寫錯的失敗模式跟 I 階段的四項完全不同——I 階段配置錯了頂多是某個請求超時設定不合理、金絲雀比例不對，服務仍然可達；授權策略配置錯了（尤其是不小心切成 deny-by-default）會直接把 `pr-lanes` 內部東西向流量全部擋掉，等於重演一次「新設定在集群內部生效、外部消費者悄悄斷線」的事故模式（[2026-08-19 NPM NodePort 事故](../../incidents/2026-08-19-npm-to-k3s-nodeport-outage.md)就是同一種坑：Cilium 一行 socketLB 設定改動、影響範圍比預期大得多）。比照 E 階段供應鏈安全獨立於 D 階段遷移的先例，授權策略需要自己的 spec → plan → implement → verify 循環，而且驗證步驟要包含「先在 Audit/dry-run 模式觀察一輪，確認不會誤殺合法流量，再切 Enforce」——跟 Kyverno 當初從 Audit 翻 Enforce 的路徑一致，不要重蹈直接上生產模式的風險。

### K 階段：為什麼複用 lab-environment 而不是新裝一套

`pr-lanes` 的泳道容量本來就是照著 `pr-lanes-quota` 的資源上限反推出來的（istiod-values.yaml 裡的註解；I 階段新增 `hello-backend-canary` Deployment 後，泳道容量已從 8 條降到 7 條），此時任何新增的常駐元件（哪怕輕量如 promtail 的一個 sidecar）都在直接跟泳道容量搶資源。`lab-environment` 已經有一套完整的 Prometheus/Loki/Jaeger/Grafana，且 SRE 練習平台的資源配額（`limits.cpu: 2.5 / limits.memory: 4Gi`，見 [namespace.yaml](../../../vps_oracle/k3s/apps/lab-environment/k8s/namespace.yaml)）本身就比 `pr-lanes` 的 `1200m / 1536Mi` 寬裕得多——讓 `pr-lanes` 的指標/日誌/追蹤流向這套既有基礎設施，是本路線圖裡對整體記憶體壓力影響最小的做法。

代價是跨命名空間耦合：`pr-lanes` 的可觀測性從此依賴 `lab-environment` 的存活，两个原本各自獨立、爆炸半徑分開設計的命名空間出現了新的隱性依賴。這個取捨值得做，但要在 K 階段的設計文檔裡明確寫下來，不要讓未來的人以為兩個命名空間毫無關聯。

### L 階段：為什麼限流只是「評估」不是「承諾交付」

限流有兩條實作路徑，都有明顯代價：

- **升級 Gateway API 到 experimental channel**：換掉目前的 standard channel 安裝，多出一批目前用不到的實驗性 CRD，且 experimental API 本身還在變動中，未來 K8s/Gateway API 版本升級時相容性風險更高
- **Istio EnvoyFilter**：功能上可行（istiod 已經在），但 `EnvoyFilter` 是直接改寫 Envoy 底層配置的逃生艙口，官方文件本身就警告它跟 Istio 版本高度耦合、升級 Istio 版本時容易失效，維護成本遠高於本路線圖其他階段

而 `pr-lanes` 目前只是驗證 PR 預覽泳道機制的 demo 命名空間，沒有真實使用者流量，也還沒有濫用或過載的實際風險——限流要解決的問題目前不存在。[README](../../../vps_oracle/k3s/README.md) 也提到未來計劃是「等 `pr-lanes` 穩定後把 `workloads` 形態的服務批量接入」，屆時才會有值得限流保護的真實流量。此階段的產出是一份取捨紀錄，供那個時間點決策參考，不在本路線圖承諾實作。

## 待細化的設計取捨

- ~~I 階段的金絲雀權重路由要不要跟熔斷共用同一份 `DestinationRule`，還是分開管理~~（✅ 已定案：不共用）——`DestinationRule.host` 是單值欄位，`hello-backend` 與 `hello-backend-canary` 是兩個獨立 Service host，機制上就是兩份（一份 per host），不是風格選擇。且權重分流最終由 `VirtualService` 承載（見 I 實作結果），`DestinationRule` 沒有 subset 可切，共用沒有意義
- J 階段的 AuthorizationPolicy 粒度：只做「哪些 workload 能呼叫哪些 workload」的服務層級控制，還是要細到「哪些 HTTP method/path」的請求層級控制——後者表達力更強，但策略數量會隨 PR 泳道數量增長，維運成本要一併評估
- K 階段引入跨命名空間依賴後，`lab-environment` 的既有告警/巡檢（[inspector](../../../vps_oracle/inspector)）要不要一併涵蓋 `pr-lanes` 的可觀測性健康度——目前 inspector 分 docker 層/k3s 層兩段巡檢，`pr-lanes` 的 mesh 指標算哪一段需要界定清楚

## 各階段設計文檔

（隨階段推進逐一補上連結）

- I：✅ 已完成 — [設計文檔](2026-08-22-k3s-phase-i-traffic-resilience-design.md)（含實作結果與已知限制）、[實作計畫](2026-08-22-k3s-phase-i-traffic-resilience.md)（已打勾）
- J：🚧 設計完成，待實作 — [設計文檔](2026-08-23-k3s-phase-j-authorization-design.md)
- K：待建立
- L：待建立
