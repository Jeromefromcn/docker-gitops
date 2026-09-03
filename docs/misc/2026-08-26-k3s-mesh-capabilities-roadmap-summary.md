# K3s 服務網格能力補完路線圖:落成演練與驗證手冊

日期:2026-08-26(2026-08-29 修訂:對齊 rpc 化後的 backend)
狀態:I / J / K / L 四階段全部已上線並在集群內驗證通過(**路線圖原文表格未同步更新 K 階段狀態,見下方「勘誤」**)
環境:Oracle VPS 單節點 k3s(Cilium CNI),ArgoCD GitOps,`pr-lanes` 命名空間(Istio Ambient)
關聯文檔:[路線圖原文](../superpowers/specs/2026-08-19-k3s-mesh-capabilities-roadmap.md)、各階段設計文檔見文末「關聯文檔」一節
本文檔:面向「這四個階段到底做出了什麼、**怎麼完整演練操作**、怎麼驗證」的落成演練與驗證手冊,涵蓋從零落成與操作演練,不重複設計文檔的決策過程。**2026-08-29 起,`hello-backend` 已 rpc 化**(見 [rpc 規格](2026-08-28-hello-backend-rpc-spec.md)),超時/重試/熔斷改用其內建 `/slow`、`/fail-503`、`/fail-500` 端點驗證,不再需要臨時改鏡像。

---

## 0. 勘誤:路線圖原文的完成度標記有誤

路線圖原文([2026-08-19-k3s-mesh-capabilities-roadmap.md](../superpowers/specs/2026-08-19-k3s-mesh-capabilities-roadmap.md))的階段表格裡,K 階段目前寫的是「設計與實作計畫完成,待執行」。這是**過期資訊**——根據 git 歷史與集群現狀查證,K 階段其實已經在 2026-08-24 完整落地並驗證通過(commit `62f52ed`「Record Phase K implementation findings in the design doc」、`0ff2b2e`「Enable Loki compactor retention」、`2e07e7f`「Expose Jaeger UI via NPM reverse proxy」都是 K 階段收尾工作),只是路線圖表格那一行沒有跟著改成「✅ 已完成」。K 階段的設計文檔本身「已知限制」段落已經記錄了完整的實作發現(NodePort 分配確認無衝突、Jaeger service 命名、tracing 一次接通等),[實作計畫](../superpowers/plans/2026-08-24-k3s-phase-k-observability.md)的 checkbox 也同樣沒勾,屬於同一處疏漏。

本文檔第 4 節已用 `kubectl`/`kubectl -n argocd get application` 現場核對,確認 I/J/K/L 四階段的資源都在集群裡跑著且健康。建議之後找機會把路線圖表格與實作計畫的 checkbox 一併補上「✅ 已完成」,但這不影響功能本身已經在用。

## 1. 一句話總結

延續 [F+G 階段](2026-08-19-k3s-phase-fg-pr-lanes-summary.md)搭好的 Istio Ambient 骨架,依序補齊了服務網格四大標準能力裡原本缺的部分:**I** 給 `pr-lanes` 加上金絲雀權重路由、超時、重試、熔斷、故障注入;**J** 加上東西向流量的身份級存取控制(AuthorizationPolicy);**K** 把指標/日誌/追蹤接進 compose 既有的 Prometheus/Grafana,外加一個新開的 `mesh-observability` namespace 跑 Loki/Jaeger;**L** 用 `TrafficExtension` + Lua 幫 `hello-backend` 加上固定窗口限流。四階段交付內容零新增常駐服務對外能力(除了 I 階段一個必要的 `hello-backend-canary` Deployment),優先複用既有元件與既有 Grafana/Prometheus;I 階段超時/重試/熔斷的行為級驗證原本需臨時改動 backend 鏡像製造真實上游故障(2026-08-29 前),現已 rpc 化,改用 backend 內建的 `/slow`、`/fail-503`、`/fail-500` 端點直接打即可(見 5.3),無需臨時改鏡像。

## 2. 為什麼要做這個

[container-topology v3](../../container-topology/v3.md) 定稿後對照業界服務網格四大類能力(流量管理、安全、可觀測性、彈性)盤點現狀,發現 F+G 階段只做了「PR 預覽泳道」這一個場景需要的 header 路由,金絲雀權重、超時重試、熔斷、故障注入、細粒度授權、指標/日誌/追蹤接入、限流全部缺席。這條路線圖把缺口收斂成四個階段,依風險分層處理(I 的四項合併因為同質、J 因為授權策略配錯會直接斷流所以獨立一輪 spec→plan→implement→verify、K 因為要跨 docker/k3s 網路邊界所以先查證再動工、L 先誠實評估「pr-lanes 目前沒有真實流量,限流要解決的問題還不存在」再決定要不要做)。完整背景見路線圖原文與各階段設計文檔開頭。

## 3. 四個階段各做了什麼

### I 階段:流量彈性與路由治理(2026-08-22 完成)

- **金絲雀權重路由**:`VirtualService`(不是最初設計的 Gateway API `HTTPRoute`——兩者在同一 host 共存時互相覆蓋,已刪除 `HTTPRoute`)把 90% 流量導向 `hello-backend`、10% 導向新增的 `hello-backend-canary` Deployment,與既有的 PR 泳道 header 路由互不干擾。
- **超時**:`timeout: 10s`。行為級驗證需**真實上游慢**(見 5.3):fault injection 的 delay 是代理轉發前的本地等待,疊加同規則 timeout 時不被截斷(15s 延遲仍跑完整個請求才回 200)——這是 Envoy 對「故障注入 delay」的行為限制,非配置錯誤,也不代表 timeout 本身不可驗證。
- **重試**:`attempts: 2, perTryTimeout: 2s, retryOn: 5xx,reset,connect-failure`。行為級驗證需**真實上游 5xx**(見 5.3):fault injection 的 abort 是 local reply,不會派送到上游,觸發不了重試。
- **熔斷(outlier detection)**:`consecutive5xxErrors: 3, interval: 30s, baseEjectionTime: 30s, maxEjectionPercent: 100`(因兩個 backend 都只有 1 個副本,50% 會捨去成 0)。已下發到 Envoy dataplane。行為級 ejection 需**真實連續 5xx** 觸發(見 5.3):fault injection 的 abort 是 local reply 不派送到上游,outlier detection 看不到——要驗證得讓上游真的回 5xx,不是代理偽造。
- **故障注入**:`x-fault-test: delay`/`abort` header 觸發,固定打中 `hello-backend`(不含金絲雀)。

### J 階段:細粒度存取控制(2026-08-23 完成)

- 兩份 `AuthorizationPolicy`:**Policy 1**(`hello-backend-waypoint-frontend-only`)掛在 waypoint Gateway 上,只放行來自 `hello-frontend-sa` 身份的呼叫;**Policy 2**(`hello-backend-require-waypoint`)掛在所有 `app: hello-backend` Pod 上,只放行來自 `waypoint` 身份的連線——兩層合起來擋掉「非 hello-frontend 呼叫」與「繞過 waypoint 直連 Pod」兩種路徑。
- 新增兩個 ServiceAccount:`hello-frontend-sa`、`hello-backend-sa`(baseline/canary/所有 PR 泳道共用同一個)。
- 上線走 Audit-first:Policy 1 先套 `istio.io/dry-run` 觀察一輪再轉 Enforce,Policy 2 因判斷條件單純直接人工比對後生效。
- **誠實記錄的驗證缺口**:dry-run 觀察窗口從未實際觀察到一筆合法身份請求被 shadow-allow(全是刻意送入的非法請求觸發 shadow-deny),合法流量的真正確認是切到 Enforce 之後才發生。

### K 階段:可觀測性接入(2026-08-24 完成,設計中途推翻重寫)

路線圖原文設計「複用 `lab-environment` 既有 Prometheus/Loki/Jaeger」在動工前查證發現站不住腳:那套元件全部 `replicas: 0`(平時沒在跑),且 `lab-environment/README.md` 明文宣告「deliberate 不跟真實監控共用 pipeline」。改採新架構:

- 新開一個獨立 namespace `mesh-observability`,跑 Loki + Jaeger + 一個範圍限定在 `pr-lanes` 的 Promtail,不進 `pr-lanes-quota`、不進 `lab-environment`。
- istiod / ztunnel / waypoint 各自的 Prometheus 端點新增一個 NodePort Service 曝露出來(不新增元件)。
- **方向是 compose 既有 Prometheus/Grafana 主動連出去打 k3s NodePort**(pod 反向連 docker bridge 這個方向被叢集層級的 `fwmark`/`table 2004` 規則擋死,查證過但刻意不修)。
- 過程中額外發現並修好兩層前置條件:(1) compose `prometheus`/`grafana` 容器的 docker network 預設閘道解析到錯的網段,改 `default` 網路 `internal: true` 修正;(2) 閘道修好後仍 `Connection refused`,根因是 `socketLB.hostNamespaceOnly: true` 讓 docker 容器連 NodePort 完全繞不過 Cilium 的兩條路徑,靠既有的 `nodeport-relay@<port>.service`(host-netns socat)逐埠註冊解決,新增了 `nodeport-relay@30110`~`30114` 五個 instance。
- Jaeger UI 額外接了 NPM 反代(`jaeger.jerome.cloudns.asia`)與 homepage 卡片。

### L 階段:限流(2026-08-25 完成,原定兩條路徑均被否決)

- 原定兩條路徑查證後都是死路:升級 Gateway API 到 experimental channel——官方 GEP 列表至今沒有限流 API;Istio `EnvoyFilter`——在 ambient/waypoint 模式下不受官方背書。
- 改採 **`TrafficExtension`(Istio 1.30 API)+ 內嵌 Lua** 固定窗口令牌桶,掛在 `hello-backend` Service 的 waypoint 入站 filter chain(`phase: STATS`),`hello-backend` 限流 60 req/min,超限回 `429` + `x-envoy-ratelimited: true`。
- 線上驗證:100 次 burst 得 59×200/41×429,貼近設計目標;等待 65+ 秒窗口重置後恢復 200。
- **filter chain 順序曾記錄有誤,已更正**:真正順序是 `rbac → grpc_stats → fault → cors → Lua 限流 → ... → router`——J 階段 RBAC 在 L 階段限流之前,未授權流量不會消耗限流額度。
- **覆蓋邊界**:只保護經 `hello-backend` VIP 的流量(含 canary 90/10 內部轉發部分),不保護直連 `hello-backend-canary.pr-lanes.svc.cluster.local` 或繞過 waypoint 直連 Pod 的流量。

## 4. 集群現況核對(本文檔撰寫時,2026-08-26 現場執行)

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

四階段的資源都存在且 `Running`/`ALLOW`。以下第 5 節提供逐項的**演練與驗證**步驟(涵蓋「改動→同步→驗證→還原」的落成操作)。

---

## 4.5 驗證點總覽(10 項,逐項勾選)

10 個驗證點對應四大類能力。**「打勾」欄**:驗證通過就改成 `[x]`,全部打勾表示這份手冊完整跑完。⚠️ 標記表示該驗證點有副作用(建臨時 pod、灌流量、或短暫調整流量),執行前先看 5.0 記 quota 基準值。

| ✓ | 能力 | 驗證點 | 驗證方式 | 預期結果 | 對應章節 |
|---|---|---|---|---|---|
| [x] | I | 金絲雀權重路由 | 連打 20 次統計 canary 命中 | ~10%(約 2 次) | 5.1 |
| [x] | I | 超時 | `/slow`(15s)內建端點 | 約 6s 後被截斷回 504(非 200;perTryTimeout 2s×3 次嘗試) | 5.3 |
| [x] | I | 重試 | `/fail-503` 內建端點 | 重試發生,上游持續失敗最終 503 | 5.3 |
| [ ] | I | 熔斷 | 連打 `/fail-503` 3+ 次 | 觸發 ejection,之後 503,30s 後恢復 200 | 5.3 |
| [ ] | I | 故障注入 | `x-fault-test: delay`/`abort` | delay ~15s、abort 立即錯誤碼 | 5.2 |
| [ ] | J | 身份級授權 | 合法/非法兩路徑 | 合法 200、非法非 200 | 5.4 |
| [ ] | K | 指標 | compose Prometheus targets | `istiod/ztunnel/waypoint up` | 5.5 |
| [ ] | K | 日誌 | Loki 查 `pr-lanes` | 非空日誌條目 | 5.6 |
scm-history-item:/home/ubuntu/jerome/docker-gitops?%7B%22repositoryId%22%3A%22scm0%22%2C%22historyItemId%22%3A%22c3d47724f94221efc9577929b139345fd01a98f9%22%2C%22historyItemParentId%22%3A%22682be36b4e71c002279803d4fb8a3f039814fbb0%22%2C%22historyItemDisplayId%22%3A%22c3d4772%22%7D| [ ] | K | 追蹤 | Jaeger 查 service | 含 waypoint 相關 service | 5.7 |
| [ ] | L | 限流 | 灌 70 次請求 | 出現 429 + `x-envoy-ratelimited`,窗口重置後恢復 200 | 5.8 |

⚠️ 注意:**超時/重試/熔斷**三項的行為級驗證用 rpc 化 backend 的內建端點(`/slow`、`/fail-503`、`/fail-500`)直接打,見 5.3,**不需要**臨時改 backend 鏡像。其中**熔斷**會短暫讓 backend 進入 ejected 狀態,驗完等 `baseEjectionTime: 30s` 過去自然恢復。

## 5. 演練與驗證步驟

以下所有指令假設在 `docker-gitops` 倉庫任意目錄執行,已有 `kubectl` 存取此 k3s 叢集的權限。凡標「⚠️ 有副作用」的步驟會建立臨時 debug pod 或短暫調整流量,執行前留意。

### 5.0 通用前置檢查

```bash
# 所有相關 ArgoCD Application 應為 Synced + Healthy
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

# pr-lanes 的 quota 目前用量(基準值,後續步驟前後比對應該不變)
kubectl -n pr-lanes describe resourcequota pr-lanes-quota
```

預期:`hello`、`istio-istiod`、`istio-ztunnel`、`istio-cni`、`istio-base`、`gateway-api`、`mesh-observability` 均 `Synced`/`Healthy`。

---

### 5.1 I 階段:金絲雀權重路由

**權重路由的規則是 `backend-virtualservice.yaml` 的第三條 http 規則**(無 header 匹配那條):`weight: 90 → hello-backend`(stable)、`weight: 10 → hello-backend-canary`。改這個 weight 就能驗證權重變化,這是 GitOps 落成循環(Git first → ArgoCD sync)。

**A. 驗證現有權重(無改動)**

```bash
FRONTEND_POD=$(kubectl -n pr-lanes get pod -l app=hello-frontend -o jsonpath='{.items[0].metadata.name}')

# 連續打 20 次,統計 canary 命中比例,預期接近 10%(2 次上下)
for i in $(seq 1 20); do
  kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s http://hello-backend.pr-lanes.svc.cluster.local/ | grep -o canary
done | sort | uniq -c
```

預期:約 2 次 `canary`,其餘無輸出(打中 stable 版本無 canary 字樣)。

**B. 演練落成:改 weight 驗證權重變化(改動→同步→驗證→還原)**

1. 編輯 `vps_oracle/k3s/apps/hello/k8s/backend-virtualservice.yaml`,把第三條規則的 `weight: 90`/`weight: 10` 改成 `weight: 70`/`weight: 30`。
2. Commit + push(觸發 ArgoCD sync):
   ```bash
   git add vps_oracle/k3s/apps/hello/k8s/backend-virtualservice.yaml
   git commit -m "chore: temporarily shift canary weight to 70/30 for drill"
   git push origin main
   ```
3. 等 ArgoCD sync(`kubectl get application hello -n argocd` 變 `Synced`)。
4. 重跑上方 A 的 20 次統計——預期 canary 命中率明顯上升(約 6 次,而非 2 次)。
5. **還原**:把 weight 改回 90/10,再 commit + push。

**副作用**:無(不重建 pod,僅改 Envoy 路由權重)。

### 5.2 I 階段:故障注入(delay/abort)

```bash
# 不帶 header:正常回應,無延遲
kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://hello-backend.pr-lanes.svc.cluster.local/

# 帶 x-fault-test: delay:預期整整 ~15s 後才回 200(已知限制:timeout 10s 不會截斷,這是 Envoy 行為限制,不是 bug)
kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -H 'x-fault-test: delay' http://hello-backend.pr-lanes.svc.cluster.local/

# 帶 x-fault-test: abort:預期立即返回故障注入設定的錯誤碼(非 200)
kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -H 'x-fault-test: abort' http://hello-backend.pr-lanes.svc.cluster.local/
```

### 5.3 I 階段:超時、重試、熔斷的行為級驗證(rpc 化 backend 內建故障端點)

**背景**:**不要**用 `x-fault-test: delay/abort` 來驗證這三項——那是代理本地的 local reply/轉發前等待,請求不會真正派送/慢到上游,重試與 outlier detection 都看不到,超時也不會被截斷。要驗證行為,必須讓**上游(hello-backend)真的變慢或真的回 5xx**。

**做法(2026-08-29 起)**:`hello-backend` 已 rpc 化(見 [rpc 規格](2026-08-28-hello-backend-rpc-spec.md)),**內建**真實上游端點,直接打即可,不需要臨時改鏡像:

- `GET /slow`:延遲 `SLOW_DELAY_SECONDS`(預設 **15s**)後回 200 → 慢於 `perTryTimeout: 2s` × 3 次嘗試(實際 ~6s 截斷,見下),觸發超時
- `GET /fail-503`:立即回 503 → 觸發重試(`retryOn: 5xx`)與熔斷(`outlierDetection`)
- `GET /fail-500`:立即回 500 → 觸發重試(`retryOn: 5xx`),重試後仍 500,最終回 **503**
- `GET /healthz`:回 200(供 probe)

**實測行為(2026-08-29 初測 / 2026-09-01 修正)**:
- `/slow`(15s)會被 Envoy 截斷,但**不是** `timeout: 10s` 觸發,而是 `retries.perTryTimeout: 2s` 先到點:每次嘗試 2s 超時,`attempts: 2` = 原始 1 次 + 重試 2 次 = 共 **3 次嘗試**,總耗時 **≈ 6s**(2s × 3),重試配額耗盡後回 **504**(不是 503、不是 10s)。`timeout: 10s` 是總預算上限,但 6s 就先耗盡重試配額,所以它實際從未觸發。
- `/fail-500` 觸發 retry(2 次),上游持續 500,最終回 **503**。
- 所以**超時**的最終可見狀態碼是 **504**(每次嘗試都是 timeout 類錯誤);**重試**(上游持續 5xx)的最終可見狀態碼是 **503**。區分機制看 `%{time_total}`:超時約 6s、重試立即(<1s)。

**驗證步驟**(先記下第 5.0 節的 quota 基準值):

```bash
FRONTEND_POD=$(kubectl -n pr-lanes get pod -l app=hello-frontend -o jsonpath='{.items[0].metadata.name}')
SVC=http://hello-backend.pr-lanes.svc.cluster.local

# 2 超時:預期約 6s 後被截斷回 504(非 200;time_total ≈ 6s = perTryTimeout 2s × 3 次嘗試)
#   ⚠️ 觸發 outlier ejection:連續 504/5xx 會把 backend 踢出(見 #4),重跑前先等 baseEjectionTime 30s
kubectl -n pr-lanes exec "$FRONTEND_POD" -- \
  curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' "$SVC/slow"

# 3 重試:上游固定 503,retryOn: 5xx 觸發,attempts: 2 重試兩次後最終仍 503(立即回,time_total < 1s)
kubectl -n pr-lanes exec "$FRONTEND_POD" -- \
  curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' "$SVC/fail-503"

# 4 熔斷:連續 3 次 5xx 觸發 ejection,之後請求回 503/No Healthy Upstream,
#   等 baseEjectionTime: 30s 過去後恢復 200
for i in $(seq 1 4); do
  kubectl -n pr-lanes exec "$FRONTEND_POD" -- \
    curl -s -o /dev/null -w '%{http_code}\n' "$SVC/fail-503"
done
```

**預期**:超時 → 約 6s 後 504(`time_total≈6s`,perTryTimeout 2s × 3 次嘗試;非 200、非 10s);重試 → 立即 503(`time_total<1s`,重試發生但上游持續失敗);熔斷 → 第 3 次後請求開始被拒(503),停 30s 以上後恢復 200。

預期:超時 → 約 6s 後 504(`time_total≈6s`,perTryTimeout 2s × 3 次嘗試;非 200、非 10s);重試 → 立即 503(`time_total<1s`,重試發生但上游持續失敗);熔斷 → 第 3 次後請求開始被拒(503),停 30s 以上後恢復 200。**無需恢復任何東西**——端點是 backend 內建的常駐能力,不打就等於沒影響;熔斷的 ejected 狀態會隨 `baseEjectionTime` 自動恢復。**唯一要注意**:熔斷驗證期間 backend 會短暫被 ejected,`/` 也會受影響(所有上游都在 ejected 清單裡),等 30s+ 即恢復。

> 說明:`/fail-500` 也適合驗證重試(500 → retry → 仍 500 → 最終 503);要驗證「重試後成功」需要上游「先失敗後恢復」的邏輯,超出本文檔驗證範圍(可臨時改 `SLOW_DELAY_SECONDS`/自訂端點或縮放副本)。

**重試是否「真的發生」的請求級證據(2026-09-01 實測確認)**:backend 因 `log_message` override 不記 access log,waypoint access log 每條只記**最終請求**(重試 attempt 會合併成一條),ztunnel 記錄是**連接級**非請求級——三者都無法直接數 attempt 次數。可靠的做法是**用時間當尺子**打 `/slow`:
- `/slow`(15s)+ retry `perTryTimeout: 2s` × 3 次 attempt → 實測 **504, `time_total` ≈ 6.0s**,且 waypoint access log 顯示 `504 URX,UT upstream_per_try_timeout`(`URX`=retry limit exceeded、`UT`=upstream per-try timeout)——這兩個 flag 就是重試發生且耗盡的請求級鐵證。
- 若重試**不**生效,`/slow` 會是 10s(timeout)或 15s(完整 delay),而不是 6s。
- 對照組 `/fail-503`(503 立即回)→ 最終 `503 URX via_upstream`,`time_total` < 0.1s(503 不消耗時間,與 `/slow` 的 6s 形成鮮明對比,靠 `time_total` 一眼區分重試與超時)。

**為什麼 Loki 只查得到「一條」日誌(2026-09-01 實測確認)**:別被「數日誌條數」誤導——「一條」是正常現象,不是重試沒發生。原因是觀測分層:

```
frontend ──HBONE──> ztunnel(L4) ──> waypoint(L7:retry/超時/熔斷) ──> ztunnel(L4) ──> backend
```

| 層 | 觀測方式 | 粒度 | 一次 `/slow`(3 次 attempt)看到幾條 |
|---|---|---|---|
| waypoint access log(Loki) | `accessLogFile: /dev/stdout`,promtail 採集 | **每請求一條**,重試 attempt 合併、以 flag 標記 | **1 條**(`504 URX,UT upstream_per_try_timeout`) |
| ztunnel 日誌 | `connection complete` | **每 HBONE 連接一條**(ambient 的 L4 層) | **3 條**(同一連接 `48890`,間隔 ~2s 各一次) |
| backend | `log_message` 被 override 成空 | 無 | 0 條 |
| 客戶端 `time_total` | curl 計時 | 每請求一次 | 6.05s = 2s × 3 |

- **Envoy waypoint 的 access log 就是「一個請求 → 一條」**:重試的每次 attempt 不單獨寫日誌,只在最終那條上追加 `URX`(retry limit exceeded)與 `UT`(per-try timeout)flag。所以「數到一條 + 看到 `URX,UT`」= 重試確實發生並耗盡,這是**請求級鐵證**。
- 要看**每次 attempt 的明細**,得查 ztunnel 的 `connection complete`(它按 HBONE 連接記,重試會建立新連接/在新連接上轉發);backend 本身無日誌,數不出請求次數。
- 因此驗證重試的**正確尺子是 `time_total`(6s=2s×3)與 `URX,UT` flag**,而不是「Loki 裡有幾條」。若重試不生效,`/slow` 會是 10s(timeout)或 15s(完整 delay),flag 也會是普通 `-`/`UO` 而非 `URX`。

### 5.4 J 階段:身份級授權(合法路徑放行 / 非法路徑拒絕)

```bash
# 合法路徑:hello-frontend 呼叫 hello-backend,預期 200
kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null -w '%{http_code}\n' http://hello-backend.pr-lanes.svc.cluster.local/

# ⚠️ 有副作用(建立臨時 pod,--rm 自動清理):非法身份(default SA)呼叫 hello-backend Service,
# 因 Service 有 use-waypoint label 會被導去 waypoint,驗證 Policy 1——預期被拒絕
kubectl -n pr-lanes run authz-test-1 --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://hello-backend.pr-lanes.svc.cluster.local/

# ⚠️ 有副作用:繞過 waypoint,直連 Pod IP,驗證 Policy 2 獨立生效——預期被拒絕(連線被拒或 403)
BACKEND_IP=$(kubectl -n pr-lanes get pod -l app=hello-backend,lane=baseline -o jsonpath='{.items[0].status.podIP}')
kubectl -n pr-lanes run authz-test-2 --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 "http://${BACKEND_IP}:8080/"
```

預期:第一條 `200`;第二、三條均非 `200`(連線被拒或逾時,`--max-time 5` 避免卡住)。

### 5.5 K 階段:指標(compose Prometheus 能拉到 istiod/ztunnel/waypoint)

```bash
# 從宿主機直接查 compose Prometheus 的 targets API(只走內網,無需進容器)
curl -s http://172.19.0.4:9090/api/v1/targets | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    if t['labels'].get('job') in ('istiod', 'ztunnel', 'waypoint'):
        print(t['labels']['job'], t['health'])
"
```

預期:`istiod up`、`ztunnel up`、`waypoint up`。也可以直接開瀏覽器看 Grafana(`https://grafana.jerome.cloudns.asia`)裡的既有 Prometheus 資料源查這三個 job 的指標。

### 5.6 K 階段:日誌(Loki 能查到 waypoint access log)

```bash
for i in $(seq 1 3); do kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null http://hello-backend.pr-lanes.svc.cluster.local/; done
sleep 15
curl -s "http://10.0.0.95:30113/loki/api/v1/query_range?query=%7Bnamespace%3D%22pr-lanes%22%7D&limit=5" | python3 -m json.tool | head -30
```

預期:回傳非空的日誌條目(waypoint access log 或 pod stdout)。也可在 Grafana 的 Loki 資料源(Explore 頁面)用 `{namespace="pr-lanes"}` 查詢。

### 5.7 K 階段:追蹤(Jaeger 能查到剛才那次呼叫的 trace)

```bash
curl -s "http://10.0.0.95:30114/api/services" | python3 -m json.tool
```

預期:服務列表包含跟 `hello-backend`/waypoint 相關的條目(**已知限制**:實際 service 名稱是 `waypoint.pr-lanes`,不是 `hello-frontend`/`hello-backend`——ambient mesh 下 span 是用 waypoint 自己的身份打標籤,operationName 才是 `hello-backend:80/*`)。也可以直接開 `https://jaeger.jerome.cloudns.asia`(需 Basic Auth + access list)用瀏覽器查。

### 5.8 L 階段:限流(429 行為 + 窗口重置)

```bash
# 連續灌 70 次請求(閾值 60 req/min),統計狀態碼分布——預期前面多數 200,後面出現 429
for i in $(seq 1 70); do
  kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null -w '%{http_code}\n' http://hello-backend.pr-lanes.svc.cluster.local/
done | sort | uniq -c

# 確認 429 回應帶正確 header
kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -D - -o /dev/null http://hello-backend.pr-lanes.svc.cluster.local/ | grep -i x-envoy-ratelimited

# 等窗口重置(60s+)後應恢復 200 —— 這步會多等 65 秒
sleep 65
kubectl -n pr-lanes exec "$FRONTEND_POD" -- curl -s -o /dev/null -w '%{http_code}\n' http://hello-backend.pr-lanes.svc.cluster.local/
```

預期:70 次裡出現一定比例 `429`(視距離上次窗口重置的時間點而定,不必剛好 60/10);429 回應帶 `x-envoy-ratelimited: true`;等待窗口重置後恢復 `200`。

### 5.9 收尾:確認 quota 與其餘 Application 都沒被動到

```bash
kubectl -n pr-lanes describe resourcequota pr-lanes-quota
kubectl -n mesh-observability describe resourcequota mesh-observability-quota
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
kubectl -n lab-environment get deployments -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas
```

預期:`pr-lanes-quota` 與第 5.0 節記下的基準值一致;`mesh-observability-quota` 用量在額度內;全部 Application 仍 `Synced`/`Healthy`;`lab-environment` 所有 Deployment 仍 `REPLICAS: 0`(本路線圖從未動過它)。

## 6. 已知限制總覽(不要重複踩坑)

- I:`fault.delay` 疊加同規則 `timeout` 不會被截斷——這是 Envoy 對「故障注入 delay」的行為限制,不代表 timeout 本身不可驗證(真實上游慢時 timeout 會正常截斷,見 5.3);`x-fault-test: abort` 無法觸發熔斷/重試(local reply 不到 upstream)——要行為級驗證得讓上游真的回 5xx(見 5.3);金絲雀權重把 PR 泳道並發容量從 8 降到 7。
- J:授權 dry-run 觀察期實際上從未觀察到合法請求被 shadow-allow,真正驗證合法路徑是切 Enforce 之後才做的;PR 泳道 backend(`hello-backend-pr-N`)的保護目前只有架構分析佐證,沒有真正 PR 泳道實地測過。
- K:Envoy trace 有取樣率設定(目前 100%,故意調高,因為沒有真實流量不擔心成本);Jaeger/Loki 都是非持久化儲存,pod 重建會清空;任何要幫 compose 新接一個 k3s NodePort 的人都要記得**兩層前置條件**——docker network 閘道(已修)+ `nodeport-relay@<port>.service`(要逐埠註冊),漏了第二層會出現看起來像閘道又壞了的 `connection refused`。
- L:限流覆蓋邊界只到 `hello-backend` VIP,不含直連 canary Service 或繞過 waypoint 的流量;waypoint 是單 worker(`concurrency: 1`)所以令牌桶狀態是真全域,不是近似值。

## 7. 關聯文檔

- 路線圖原文:[2026-08-19-k3s-mesh-capabilities-roadmap.md](../superpowers/specs/2026-08-19-k3s-mesh-capabilities-roadmap.md)
- I 階段:[設計文檔](../superpowers/specs/2026-08-22-k3s-phase-i-traffic-resilience-design.md) / [實作計畫](../superpowers/plans/2026-08-22-k3s-phase-i-traffic-resilience.md)
- J 階段:[設計文檔](../superpowers/specs/2026-08-23-k3s-phase-j-authorization-design.md) / [實作計畫](../superpowers/plans/2026-08-23-k3s-phase-j-authorization.md)
- K 階段:[設計文檔](../superpowers/specs/2026-08-24-k3s-phase-k-observability-design.md) / [實作計畫](../superpowers/plans/2026-08-24-k3s-phase-k-observability.md)
- L 階段:[設計文檔](../superpowers/specs/2026-08-25-k3s-phase-l-ratelimit-design.md) / [評估筆記](../superpowers/specs/2026-08-25-k3s-phase-l-ratelimit-evaluation.md) / [實作計畫](../superpowers/plans/2026-08-25-k3s-phase-l-ratelimit.md)
- K 階段相關事故排查:[compose→k3s NodePort 閘道問題](../incidents/2026-08-24-compose-prometheus-grafana-k3s-nodeport-gateway.md)、[k3s pod→docker bridge 黑洞](../incidents/2026-08-24-k3s-pod-to-docker-bridge-blackhole.md)
- 前置階段總結:[F+G 階段總結](2026-08-19-k3s-phase-fg-pr-lanes-summary.md)
