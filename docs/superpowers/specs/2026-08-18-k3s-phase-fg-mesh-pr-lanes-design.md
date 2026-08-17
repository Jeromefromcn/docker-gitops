# K3s Phase F+G — 服務網格驅動的 PR 泳道設計

日期：2026-08-18

對應 [K3s 雲原生實驗平台路線圖](2026-08-05-k3s-cloud-native-platform-roadmap.md) 的 F+G 階段（原 F「多環境 PR 泳道」與 G「服務網格 + 漸進式發布」合併，合併理由見路線圖「F+G 合併的原因」段落）。

前置：[Phase B GitOps 設計](2026-08-07-k3s-phase-b-gitops-design.md)（ArgoCD + ApplicationSet controller 已裝，CI build→Trivy→Cosign 骨架已跑通）、[Phase E 供應鏈安全設計](2026-08-15-k3s-phase-e-supply-chain-security-design.md)（Kyverno 三條政策皆已翻 Enforce）。

## 範圍

**這階段要做的：**

- 裝 Istio Ambient（istiod + ztunnel + istio-cni）與 Gateway API CRD，全部走 GitOps
- 把練手用的 `placeholder-hello` 從單層改成**兩層**（`hello-frontend` → `hello-backend`），搬進新的 `pr-lanes` 命名空間，只有這個命名空間加入網格
- 為 `hello-backend` 這個 Service 掛一份 waypoint proxy（L7）
- ArgoCD ApplicationSet PR Generator：帶 `pr-lane` label 的 open PR 各生成一條泳道（只複製 `hello-backend` 一顆服務，**不複製整套環境**）
- 泳道路由：請求帶 `x-pr-lane: <PR 編號>` header，經 baseline frontend 轉發到 backend 時由 waypoint 依 header 導向該 PR 的 backend 版本；不帶 header 的請求落回共享的 baseline backend
- CI 擴充：`pull_request` 事件建置 `hello-backend` 並簽章，tag 用 PR head SHA
- Kyverno 政策調整，讓 PR 分支簽出的 image 能在 `pr-lanes` 通過驗簽（見下方「Kyverno 政策調整」）

**這階段不做的：**

- **金絲雀 / 漸進式發布**（Argo Rollouts、按權重切流）——原 G 階段的這部分不在本次交付物內。本階段建立的 waypoint 是同一套機制，日後要做金絲雀時直接沿用，不用重裝網格
- **把既有服務納入網格**——`workloads`、`llm`、`lab-environment` 等命名空間這一批不加入 ambient。這不是「網格只給實驗室用」，而是**漸進式納管**：真實世界導入服務網格的標準作法就是先挑一個非關鍵命名空間驗證，穩定後再逐個 onboard，不是一次全叢集開啟。`pr-lanes` 是第一批，驗證清單全過且穩定運行後，下一批可以是 `workloads`（vikunja/apprise，無狀態、L4 mTLS 幾乎零額外成本，因為 ztunnel 是 per-node 的、已經在跑）。有狀態服務不進網格則是路線圖既定原則，不隨批次放寬
- **對外曝露泳道**——泳道不另開網域、不進 NPM。驗證從叢集內或宿主機用 `curl` 帶 header 打進去即可
- **mTLS / AuthorizationPolicy 等網格安全能力**——ambient 預設會給 `pr-lanes` 內的流量上 mTLS，這是附帶效果不是本階段目標，不另外設計授權政策

## 為什麼是「共享底座 + 流量路由」，以及為什麼必須兩層

業界的 PR 預覽環境分兩派：

- **A 派 namespace-per-PR**：每個 PR 把整套服務與依賴複製一份到獨立命名空間。忠實、簡單，但成本隨「服務數 × open PR 數」線性成長
- **B 派共享底座 + 流量路由**（Signadot 等工具代表，深度依賴圖的大廠在用）：只把「這個 PR 改動到的那一顆服務」多開一份，其餘依賴全部共用常駐的基準環境；請求帶 routing key，命中改動過的服務就轉進 PR 版本，其餘落回基準環境

本階段實作 B 派。**但 B 派的本質是東西向（service → service）的路由**——請求進來後在依賴圖上一跳一跳傳遞 routing key，每一跳判斷「下一顆服務有沒有這條泳道的版本」。如果只有單一一顆無依賴的服務，路由決策只發生在入口一次，那用任何 ingress controller 的 header 分流都能做到，網格不提供任何額外價值，是「掛著 B 的名字做 A 的簡化版」。

所以 `placeholder-hello` 必須從單層拆成兩層，才有一個真正的東西向跳點讓 waypoint 去攔截。這是本設計裡看似多餘、實則不可省的一步：**沒有第二跳，就沒有 B 派可言。**

兩層的職責：

- `hello-frontend`：baseline 恆定不變，永遠只有一份。nginx，`/` 回自己的頁面，`/api` 用 `proxy_pass` 轉給 `hello-backend`。它扮演「共享底座裡沒被 PR 改動、但會呼叫下游」的角色
- `hello-backend`：baseline 一份 + 每條泳道一份。PR 改的就是它。它扮演「被 PR 改動的那顆服務」

header 傳播靠 nginx `proxy_pass` 預設會把客戶端請求 header 轉給 upstream（`x-pr-lane` 用連字號不是底線，不受 nginx `underscores_in_headers` 預設關閉的影響）。真實世界這一步通常要靠應用程式碼或 tracing library 顯式傳遞，nginx 這裡是免費拿到的，設計上要知道這是簡化，不是通則。

## 現狀約束

**資源（2026-08-18 實測，同日 k3s→compose 反向遷移之後）**：主機 23Gi 總量，16Gi 已用，available 6.5Gi，**swap 4Gi 已用掉 3.0Gi**，`kubectl top node` 顯示記憶體 78%。

同日 `homepage`/`trilium`/`dify`/`evidence-os-website` 遷回 compose，`dify` 命名空間已刪除，連帶釋出它的 2Gi requests / 4Gi limits 配額——**k8s 側的配額空間比原先寬鬆，但主機整體記憶體沒有變寬鬆**（那些服務仍在同一台機器上以 compose 形式運行，只是不再經 k8s 配額計算）。swap 反而從 2.0Gi 漲到 3.0Gi。

叢集現況實測：k3s 平台固定開銷約 3.4Gi（`k3s server` 進程 RSS 1.9Gi + argocd/cilium/kyverno/trivy-operator/sealed-secrets/headlamp 等 pod 合計 1.46Gi），k8s 上的應用負載約 6.7Gi（其中 `llm` 4.0Gi、`lab-environment` 2.0Gi、`workloads` 約 0.6Gi）。本階段新增的 4 個常駐元件（約 576Mi requests）要在這個前提下評估。

**Cilium `cni.exclusive` 未設定**：`vps_oracle/k3s/cilium/values.yaml` 目前沒有 `cni:` 區塊，chart 預設 `cni.exclusive=true`，意思是 Cilium 會**主動刪掉其他 CNI plugin 的設定檔**。istio-cni 是 chained plugin，在這個設定下會被 Cilium 清掉，ztunnel 的流量攔截不會生效。必須先把 Cilium 改成 `cni.exclusive: false`——這是動到活叢集 CNI 的變更，見下方「前置變更」。

**Cilium `bpf.masquerade` 必須維持關閉**：目前未設定（chart 預設 false），正確。Istio 用 link-local IP 做健康檢查，開啟 BPF masquerade 會讓 pod 健康檢查失效，官方明確標示不支援。這一項是「確認不要動」，不是要改。

**Cilium L7 policy 與 ambient 不相容**：目前沒有使用 CiliumNetworkPolicy 的 L7 規則，維持不用即可。

**Kyverno `restrict-image-registry` 會擋掉泳道 image（Enforce）**：政策要求 `ghcr.io/jeromefromcn/*` 的簽章身分符合 `^https://github\.com/Jeromefromcn/docker-gitops/\.github/workflows/[^/]+\.yml@refs/heads/main$`。`pull_request` 事件觸發的 workflow，其 OIDC 身分是 `...@refs/pull/<N>/merge`，**不符合這條 regex**，泳道 pod 會在 admission 階段被拒絕。必須做命名空間範圍的例外，見下方「Kyverno 政策調整」。

**Kyverno `require-vuln-scan-clean`（Enforce）**：以 pod label `app in (placeholder-hello, vikunja-notify-relay)` 匹配。新的兩層 app label 不在清單內，預設不會被攔。它查的是「該 pod owner 既有的 VulnerabilityReport」，全新 image 首次部署時報告還不存在（空集合 → 條件不成立 → 放行），所以不會產生「掃描前無法部署、部署前無法掃描」的死結。

## 架構

```
                  外部 / 宿主機 curl
                        │
                        │  Host: ...   X-PR-Lane: 42（可選）
                        ▼
              hello-frontend Service (NodePort)
                        │
                 ┌──────┴──────┐
                 │ hello-      │  baseline 恆定一份，不隨 PR 複製
                 │ frontend    │  nginx: /api → proxy_pass http://hello-backend
                 │ (baseline)  │  （原樣轉發 X-PR-Lane header）
                 └──────┬──────┘
                        │  ← 這一跳進入網格：ztunnel 攔截，
                        │     因 hello-backend 掛了 waypoint，導向 waypoint
                        ▼
              ┌───────────────────┐
              │  waypoint proxy   │  Envoy，L7。讀 HTTPRoute 規則：
              │  (pr-lanes ns)    │   ・header x-pr-lane=42 → hello-backend-pr-42
              └─────────┬─────────┘   ・無 match（catch-all） → hello-backend
                        │
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
   hello-backend  hello-backend  hello-backend
    (baseline)      -pr-42         -pr-57
                  ↑ 由 ApplicationSet PR Generator 動態生成／回收

命名空間佈局：
  istio-system : istiod / ztunnel(DaemonSet) / istio-cni(DaemonSet)
  pr-lanes     : hello-frontend, hello-backend(baseline), waypoint,
                 + 每條泳道一組 Deployment/Service/HTTPRoute
                 （唯一 istio.io/dataplane-mode=ambient 的命名空間）
  其餘命名空間  : 完全不進網格
```

## 元件與設定

| 項目 | 決定 | 理由 |
|---|---|---|
| Istio 安裝方式 | Helm（`istio/base` + `istio/istiod` + `istio/cni` + `istio/ztunnel`，`profile=ambient`），版本於安裝當下查最新穩定版鎖定後寫回 `vps_oracle/k3s/README.md` | 沿用 phase A/B 裝 Cilium、ArgoCD 的模式。版本不寫死在設計文件，避免過期（同 phase B 的作法） |
| Gateway API CRD | 獨立 GitOps Application，standard channel | waypoint 本身是 `Gateway` 資源、泳道路由是 `HTTPRoute`，兩者都需要這組 CRD；k3s 未內建（已確認叢集內無 gateway CRD、無 IngressClass、無 Traefik） |
| 網格納管範圍 | 只有 `pr-lanes` 命名空間標 `istio.io/dataplane-mode=ambient` | 爆炸半徑控制。既有服務全部不受影響，出事只影響練手 app |
| waypoint 粒度 | 一份，掛在 `hello-backend` **Service** 上（`istio.io/use-waypoint`），非整個命名空間 | 只有 backend 需要 L7 路由；frontend 不需要 waypoint 就不多花一份 Envoy 的資源。這也是 ambient 相對 sidecar 模式的核心優勢——L7 代理按需掛載，不是每個 pod 一份 |
| 入口路徑 | 維持 NodePort 直連 `hello-frontend`，**不裝 Istio ingress gateway** | 泳道的路由決策發生在東西向那一跳（frontend → backend），入口只需要把 header 帶進來。裝 ingress gateway 會多一份 Envoy（約 128Mi）卻不參與任何路由決策。這個取捨同時滿足「貼近真實」（routing key 在網格內部發揮作用，才是 B 派的本質）與「跑得起來」 |
| 泳道複製範圍 | 只複製 `hello-backend`，frontend 與其餘一切共用 baseline | 這就是 B 派的定義。複製整套等於退回 A 派 |
| routing key | HTTP header `x-pr-lane: <PR 編號>` | 純 header，不需要改動 frontend 的程式邏輯（nginx 預設轉發） |
| 泳道觸發條件 | PR 帶 `pr-lane` label 才生成泳道 | 這個 repo 平時是直接推 main 的單人流程，不加 label 過濾的話任何一個 compose 改動的 PR 都會無謂起一條泳道 |
| image tag 傳播 | ApplicationSet template 用 `{{head_sha}}` 直接算出 image tag，不裝 Argo CD Image Updater、不給 CI 任何叢集憑證 | 無新增常駐元件、無新增憑證；ArgoCD 每輪詢一次就重算 desired state，天然幂等。代價是有輪詢延遲（預設 30s），對練手 app 無影響 |
| 泳道回收 | PR 關閉/合併 → 下輪輪詢 generator 不再產出該參數 → Application 自動刪除；Application 帶 `resources-finalizer.argocd.argoproj.io` | 業界共識是「ephemeral 必須真的會過期」，沒有自動回收的預覽環境是資源洩漏。這裡靠 generator + finalizer 兩層保證 |
| 泳道數量上限 | 不在 ApplicationSet 設硬上限，改由 `pr-lanes` 的 ResourceQuota 當背壓 | ApplicationSet 沒有原生的「最多生成 N 個」；配額用完後多出來的泳道 pod 停在 Pending，是優雅降級而非叢集受損。單人 repo 的 PR 量下這已足夠 |

## 泳道路由機制

waypoint 的 L7 路由由多份 `HTTPRoute` 疊加而成，全部 `parentRefs` 指向同一個 `hello-backend` Service（ambient 東西向路由的慣例是 parentRef 指 Service，不是 Gateway）：

- **baseline route**（靜態，寫死在 repo）：無 match 條件的 catch-all → `hello-backend`
- **每條泳道一份 route**（ApplicationSet 生成）：match `headers: [{name: x-pr-lane, value: "<PR 編號>"}]` → `hello-backend-pr-<N>`

Gateway API 規範定義同一 parent 上的多份 HTTPRoute 會合併，規則優先序依序比：最長 path match → method match → **header match 數量** → query param 數量。泳道規則有 1 個 header match，baseline 規則有 0 個，所以泳道規則永遠優先於 baseline，不需要人工排序，也不需要在新增泳道時改動 baseline route。

這個設計的好處是每條泳道的三個資源（Deployment / Service / HTTPRoute）完全由該 PR 的 Application 獨佔，PR 一關全部一起被 prune，baseline 的檔案自始至終沒被碰過。

## Image tag 傳播與 CI

CI 新增一條 workflow（複製 `placeholder-hello.yml` 的既有骨架：QEMU → buildx arm64 → Trivy → Cosign keyless → GHCR），差別在觸發條件與 tag：

- `push` 到 main：tag `${{ github.sha }}`（baseline 用）
- `pull_request`（且 PR 帶 `pr-lane` label，用 `if: contains(github.event.pull_request.labels.*.name, 'pr-lane')` 過濾）：tag `${{ github.event.pull_request.head.sha }}`

**必須用 `github.event.pull_request.head.sha`，不能用 `github.sha`**：`pull_request` 事件下 `github.sha` 是 GitHub 自動產生的 merge commit SHA，而 ArgoCD PR generator 的 `{{head_sha}}` 給的是 PR 分支頂端的 commit SHA，兩者不同。用錯的話 ApplicationSet 會去拉一個根本不存在的 tag，泳道 pod 永遠 `ImagePullBackOff`。這是這條 pipeline 最容易踩的坑。

## Kyverno 政策調整

`restrict-image-registry`（Enforce）目前要求簽章身分結尾是 `@refs/heads/main`，PR 建置的 image 身分是 `@refs/pull/<N>/merge`，會被擋死。作法：

1. 既有的 `restrict-image-registry` 規則**排除 `pr-lanes` 命名空間**——兩條 verifyImages 政策同時命中的話兩條都得過，不排除的話新增寬鬆政策也沒用
2. 新增 `restrict-image-registry-pr-lanes`，只匹配 `pr-lanes` 命名空間的 Pod，`subjectRegExp` 同時接受 `@refs/heads/main` 與 `@refs/pull/[0-9]+/merge`，issuer 與 rekor 設定與原政策相同

刻意不直接放寬原政策的 regex：那會讓**整個叢集**的 image 都能用 PR 分支的簽章部署，等於用一個練手功能的需求去削弱全叢集的主幹分支保證。命名空間範圍的例外把代價侷限在練手命名空間內。

`require-vuln-scan-clean`（Enforce）的 label selector 追加 `hello-frontend`、`hello-backend`，維持 phase E「自建 image 一律納管」的原則。

## Label 與 Service selector 約定

三個 label 各司其職，不能混用：

| label | 值 | 用途 |
|---|---|---|
| `app` | `hello-frontend` / `hello-backend` | 跨 baseline 與所有泳道的服務身分。Kyverno selector 用它，一條就涵蓋全部 |
| `lane` | `baseline` / `pr-<N>` | 區分同一服務的 baseline 版本與各泳道版本 |
| （GitHub PR label）`pr-lane` | — | PR 上的標記，決定 generator 要不要為它生成泳道，與 k8s label 無關 |

**Service selector 必須同時匹配 `app` 與 `lane`**：baseline 的 `hello-backend` Service selector 是 `app=hello-backend, lane=baseline`，泳道的 `hello-backend-pr-<N>` Service selector 是 `app=hello-backend, lane=pr-<N>`。只用 `app` 的話 baseline Service 會把所有泳道 pod 一起選進去，不帶 header 的請求會隨機落到泳道版本——這正是驗證清單第 7e 項要證偽的失敗模式。

## 前置變更：Cilium `cni.exclusive: false`（高風險）

在裝 Istio 之前，必須先改 `vps_oracle/k3s/cilium/values.yaml` 加上：

```yaml
cni:
  exclusive: false
```

否則 Cilium 會刪掉 istio-cni 寫入的 plugin 設定，ztunnel 攔截失效，整個網格靜默不生效（不是報錯，是「裝起來了但什麼都沒攔到」，很難查）。

**這是動到活叢集 CNI 的變更，是本階段最危險的一步**：Cilium 是單節點叢集上所有 pod 的網路來源，`helm upgrade` 會重啟 cilium-agent DaemonSet。既有 pod 的既有連線通常不受影響（Cilium 的 eBPF datapath 在 agent 重啟期間仍在核心裡運作），但新建連線、Service 解析在 agent 重啟的數十秒窗口內可能失敗。這一步要：

- 單獨一次變更、單獨驗證，不跟 Istio 安裝混在同一個 commit
- 事前確認 `bpf.masquerade` 仍為關閉
- 事後跑一輪既有服務的連通性檢查（見驗證清單第 1 項）再往下走

## Repo 佈局

```
vps_oracle/k3s/
  cilium/values.yaml              # 修改：加 cni.exclusive: false
  gateway-api/                    # 新增：Gateway API standard CRD（kustomization 指向上游 tag）
  istio/
    base-values.yaml              # 新增
    istiod-values.yaml            # 新增（含 resources）
    cni-values.yaml               # 新增
    ztunnel-values.yaml           # 新增
  apps/
    hello/                        # 由 placeholder-hello 改造而來
      backend/
        Dockerfile                # 新增：nginx + 一個標示版本的 index.html
        index.html
      k8s/
        namespace.yaml            # pr-lanes，帶 istio.io/dataplane-mode=ambient
        resourcequota.yaml        # 泳道總量背壓
        limitrange.yaml
        frontend-configmap.yaml   # nginx.conf：/api → proxy_pass hello-backend
        frontend-deployment.yaml  # 沿用既有 placeholder-hello image（pin digest）
        frontend-service.yaml     # NodePort，對外入口
        backend-deployment.yaml   # baseline
        backend-service.yaml      # 帶 istio.io/use-waypoint: waypoint
        backend-httproute.yaml    # catch-all → baseline
        waypoint-gateway.yaml     # gatewayClassName: istio-waypoint
      lane/                       # ApplicationSet 的泳道模板（kustomize base）
        kustomization.yaml
        deployment.yaml
        service.yaml
        httproute.yaml
  argocd/apps/
    hello.yaml                    # 取代 placeholder-hello.yaml
    istio.yaml                    # 新增
    gateway-api.yaml              # 新增
    pr-lanes-appset.yaml          # 新增：ApplicationSet（PR Generator）
  kyverno/policies/
    restrict-image-registry.yaml           # 修改：排除 pr-lanes
    restrict-image-registry-pr-lanes.yaml  # 新增
    require-vuln-scan-clean.yaml           # 修改：label selector 追加兩個 app

.github/workflows/
  hello-backend.yml               # 新增（placeholder-hello.yml 改造）
```

原 `apps/placeholder-hello/` 目錄與 `argocd/apps/placeholder-hello.yaml` 移除——它本來就是 phase B 為了練 CI 而設的佔位服務，本階段是把它升級成兩層的泳道練習對象，不是另外再養一個平行的練手 app。搬遷過程 ArgoCD 會從 `workloads` prune 掉舊的、在 `pr-lanes` 建新的；無狀態、無 PVC，不涉及資料搬遷。

## 資源預算

新增常駐元件（起始值，安裝後依實測調整）：

| 元件 | requests | limits | 位置 |
|---|---|---|---|
| istiod | 100m / 256Mi | 500m / 512Mi | istio-system |
| ztunnel (DaemonSet ×1) | 50m / 128Mi | 200m / 256Mi | istio-system |
| istio-cni (DaemonSet ×1) | 50m / 64Mi | 100m / 128Mi | istio-system |
| waypoint | 50m / 128Mi | 200m / 256Mi | pr-lanes（計入命名空間配額） |
| **小計** | **250m / 576Mi** | **1000m / 1152Mi** | |

業界對「小型叢集」的 istiod 建議值是 500m/512Mi requests，那是以約 100 個 mesh pod 為前提；本階段 mesh 內只有 3~10 個 pod，故往下取。這些是起始值不是定論——istiod 若 OOMKilled 就往上調，調整結果寫回 README。

`pr-lanes` 命名空間 ResourceQuota：

| 項目 | 值 | 佔用試算 |
|---|---|---|
| requests.cpu | 400m | waypoint 50m + frontend 25m + backend baseline 25m = 100m，餘 300m |
| requests.memory | 768Mi | 128 + 64 + 64 = 256Mi，餘 512Mi |
| limits.cpu | 1200m | |
| limits.memory | 1536Mi | |

每條泳道 25m/64Mi requests → 配額容得下約 **8 條同時存在的泳道**，第 9 條起 pod 卡在 Pending（優雅降級）。LimitRange 沿用 `workloads` 的形態（defaultRequest 25m/64Mi、default 100m/128Mi），確保沒寫 resources 的 pod（含 Istio 自動生成的 waypoint Deployment）也有預設值不會吃爆配額。

**整體衝擊**：新增約 576Mi requests。k8s 配額側有空間（`dify` 命名空間刪除後釋出 2Gi requests），但主機整體記憶體沒有變寬鬆——swap 已用 3.0Gi。安裝前後都要記錄 `free -h` 與 `kubectl top node`；判斷標準看的是 **swap 使用量與既有服務是否 OOMKill**，不是看 k8s 配額還剩多少（配額寬鬆是 dify 搬走造成的假象，那些服務仍在同一台機器上以 compose 形式吃記憶體）。

## 驗證清單（phase F+G 過關標準）

1. **Cilium 變更後既有服務無損**：`cni.exclusive: false` 套用並等 cilium-agent 重啟完成後，`kubectl get pods -A` 無新增 CrashLoop/NotReady；抽驗**仍在 k8s 上**的服務連通性（vikunja、apprise、llm、lab-environment 各 curl 一次）與跨 pod DNS 解析，確認 phase A 以來的網路行為沒被改壞。compose 側的服務走 docker bridge、不經 Cilium，不在這項檢查範圍內
2. `kubectl -n istio-system get pods` 全部 Running；`istioctl version` 能連上控制平面
3. `kubectl get crd | grep gateway.networking.k8s.io` 有 GatewayClass/Gateway/HTTPRoute
4. `kubectl -n pr-lanes get gateway waypoint` 顯示 `PROGRAMMED=True`，對應的 waypoint Deployment Running
5. `istioctl ztunnel-config workload` 顯示 `pr-lanes` 內的 pod 已納管（protocol 欄為 HBONE），且其他命名空間的 pod **未**被納管——爆炸半徑限制成立的直接證據
6. **baseline 路徑**：`curl http://<node>:<nodeport>/api` 回傳 baseline backend 的內容
7. **泳道端到端**：開一個改動 `hello-backend/index.html` 的 PR 並打上 `pr-lane` label →
   a. GitHub Actions 綠燈，GHCR 出現以 PR head SHA 為 tag 的 image
   b. `kubectl -n argocd get applications` 出現該 PR 的 Application，Synced + Healthy
   c. `kubectl -n pr-lanes get pods -l lane=pr-<N>` Running（證明 Kyverno 驗簽例外生效，沒被 admission 擋下）
   d. `curl -H "x-pr-lane: <N>" http://<node>:<nodeport>/api` 回傳**該 PR 的內容**
   e. `curl http://<node>:<nodeport>/api`（不帶 header）仍回傳 **baseline 內容**——共享底座沒被泳道污染，這是 B 派成立的核心證據
8. **泳道更新**：往該 PR 再推一個 commit，等 CI 完成 + generator 輪詢，確認泳道自動換成新 image（`kubectl -n pr-lanes describe pod` 的 image tag 等於新的 head SHA）
9. **泳道回收**：關閉 PR → 確認 Application 消失、`pr-lanes` 內該泳道的 Deployment/Service/HTTPRoute 全部被 prune，沒有殘留
10. **未打 label 的 PR 不起泳道**：開一個不帶 `pr-lane` label 的 PR，確認 ApplicationSet 不為它生成任何 Application
11. **Kyverno 例外範圍正確**：試著把一個 PR 分支簽出的 image 部署到 `workloads`（非 `pr-lanes`），確認**仍然被擋**——證明例外只開在 `pr-lanes`，沒有全叢集放寬
12. 記錄安裝前後的 `free -h` / `kubectl top node`；把鎖定的 Istio、Gateway API 版本號寫回 `vps_oracle/k3s/README.md`

## 已知限制 / 失敗模式

- **單服務深度的 B 派是縮小模型**：真實的泳道系統要處理多跳傳播、資料庫共用時的資料污染、routing key 在非 HTTP 協定（gRPC metadata、訊息佇列）上的傳遞。本階段兩層拓撲驗證的是機制骨架，不代表能直接套到有狀態服務上
- **header 傳播在真實服務要靠應用程式碼**：nginx `proxy_pass` 免費轉發 header 是這個練手拓撲的巧合；換成任何自寫服務，不顯式把 inbound header 複製到 outbound request，泳道就會在第二跳斷掉
- **輪詢延遲**：PR generator 預設 30s 輪詢 + ArgoCD sync 週期，從 CI 完成到泳道更新有數十秒到分鐘級延遲，不是即時
- **Cilium 與 Istio ambient 的相容性是已知有坑的組合**：社群有 ztunnel 在特定 CNI chaining 設定下起不來的回報。若 ztunnel 無法健康啟動且短時間內查不出原因，回滾比硬查划算——回滾路徑是移除 Istio 的四個 Application、把 `pr-lanes` 的 ambient label 拿掉，Cilium 的 `cni.exclusive: false` 可以留著（對純 Cilium 環境無害）
- **資源是硬約束不是保守估計**：主機已有 3.0Gi 進 swap。若安裝後 swap 使用量明顯上升或既有服務出現 OOMKill，應直接回滾網格而不是繼續壓縮其他服務的配額——這個階段的價值是學習，不值得用既有服務的穩定性去換
- **這個階段需要 PR 流程，但這個 repo 平時是直接推 main 的**：泳道要能驗證，就得真的開 PR。這不是缺陷，但代表本階段之後若要持續使用泳道，工作習慣也要跟著改成走 PR，否則機制裝好了卻沒有觸發它的場景
- **ApplicationSet 沒有生成數量硬上限**：靠 ResourceQuota 當背壓，超額泳道會停在 Pending。單人 repo 的 PR 量下不成問題，但這個設計不適合直接搬到多人團隊
- **PR 分支簽章例外是實質的安全讓步**：`pr-lanes` 內任何從本 repo 的 PR 分支簽出的 image 都能部署。範圍雖然侷限在練手命名空間，但這個命名空間跟其他命名空間共用同一個核心與 API server——命名空間是範圍邊界，不是沙箱

## 交棒給 H

本階段結束後，`pr-lanes` 是叢集內唯一進網格的命名空間，其餘一切維持 phase A~E 的狀態。H 階段（compose 退場評估 / NPM 去留）不依賴本階段任何產出；反過來若 H 階段決定用 k8s-native ingress 取代 NPM，本階段裝好的 Gateway API CRD 與 Istio 可以直接拿來當 ingress 方案的候選之一（Istio Gateway），屆時不用再從零評估——但這只是順帶的可能性，不是本階段承諾的交付物。

若日後要做金絲雀 / 漸進式發布（原 G 階段的後半），本階段的 waypoint 就是所需的 L7 切流點，加上 Argo Rollouts 與按權重的 HTTPRoute `backendRefs.weight` 即可，不需要重裝或重新設計網格。
