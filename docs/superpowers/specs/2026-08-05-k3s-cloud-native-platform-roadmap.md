# K3s 雲原生實驗平台 — 路線圖

日期：2026-08-05

## 背景

`vps_oracle` 目前用 docker compose 管理約十個獨立棧（見 [container-topology.md](../../container-topology.md)）。目標是在同一台機器（4C/24G，Oracle Cloud VPS）上用 K3s 復刻一套完整的雲原生軟件開發運維實驗平台，涵蓋 CNI、服務網格、GitOps CI/CD、供應鏈安全、多環境泳道等業界標準組件棧，用於貼近 SRE 崗位的技術對標與學習。

這是一個橫跨數月、包含多個獨立子系統的工程，拆成多個階段，每階段各自走 spec → plan → implement → 驗證的完整循環。本文件是跨階段的總覽路線圖，不是某一階段的詳細設計——各階段的詳細設計文檔會回頭連結到這裡。

## 目標

- **基礎設施要健壯**，不是玩具級 PoC
- **概念/功能對標業界標準**（CNI、mesh、GitOps、供應鏈安全一應俱全），但**組件可選省資源版本**（例如輕量 Ingress controller、單副本控制面），以適配 4C/24G 的資源預算
- **平滑遷移**：現有服務對外域名、端口不變
- compose 環境去留**逐服務判斷**，非必須全部遷移

## 現狀約束

來自 [container-topology.md](../../container-topology.md) 與現場 `free -h` 實測（2026-08-05）：

- 記憶體：23Gi 總量，已用 11Gi，可用約 6.4Gi；CPU 4 核心。既有負載（llm、dify 等）已佔用相當一部分 headroom
- `npm`（Nginx Proxy Manager）是唯一發布宿主機 80/443 的容器，其餘服務靠 `proxy` 網路 + Docker DNS 被反代，不直接發布端口
- `3x-ui` 例外：39876（VLESS+Reality）是原始 TCP，客戶端直連，不能走 HTTP 反代——遷移時這個端口不能斷。該服務有過真實故障（見 [2026-07-24-3x-ui-vless-unreachable.md](../../incidents/2026-07-24-3x-ui-vless-unreachable.md)）：淺層健康檢查（只測端口)測不出 xray-core 內部異常，以及默認 `ulimit -n 1024` 在長連接場景下可能耗盡。遷移到 k8s 時，probe 設計需要延續「檢查進程存活」而非只測端口，且 `ulimits.nofile` 等宿主機層面配置需要在 k8s 層找到對應（如 `securityContext` 或 initContainer）
- 同機還跑著兩個不屬本 repo 管理的專案（`lab-environment`、`programming-learning-platform`），直接佔用 8080/9090/3001/3100 等宿主機端口，與 k8s 生態常見默認端口（Grafana、Prometheus 等）撞車。**衝突時以 k8s 側為主**：k8s 內組件保持慣用默認端口，改由這兩個非 k8s 管理的容器讓出端口（改其 compose/配置裡發布的宿主機端口），而不是反過來讓 k8s 組件遷就它們

## 階段路線圖

| 階段 | 目標 | 交付物 | 依賴 |
|---|---|---|---|
| A. 叢集基礎層 | K3s + containerd + Cilium（CNI/NetworkPolicy）+ 存儲 + 資源預算（ResourceQuota/LimitRange） | 空的但可連通的叢集，NPM 能打進來 | — |
| B. GitOps 啟動 | ArgoCD（app-of-apps）+ GitHub Actions CI 骨架（build→Trivy→Cosign） | 之後所有部署都走 GitOps，不手動 `kubectl apply` | A |
| C. 遷移範本 + 首批 | 挑 2 個低風險服務跑通 compose→k8s 範本，驗證域名/端口零變動：homepage（配置類無狀態）+ trilium（帶真實資料，順帶跑通 PVC 與資料搬遷） | 可複製的遷移 SOP | A、B |
| D. 剩餘服務遷移 | 資料庫類服務（vikunja+pg、dify 全家桶）、llm 推理棧、3x-ui 的 39876 TCP 透傳 | 逐服務遷移 + compose 去留決策 | C |
| D+. 唯讀集群面板 | 裝 Headlamp（view-only RBAC），與 compose 側 portainer 並行互補——portainer 管 docker，Headlamp 管 k8s | Headlamp 經 NPM 反代（獨立子網域 + `self-only` ACL，比照 ArgoCD），上 homepage 卡片（Infra Services 分類，比照 ArgoCD 現狀）；resources requests 50m/64Mi、limits 200m/256Mi | D |
| E. 供應鏈安全加固 | Trivy 准入門禁、Cosign 驗簽、Sealed Secrets、Kyverno | 鏡像/部署有政策把關 | B、D 服務已上線 |
| F+G. 服務網格驅動的 PR 泳道 | Istio Ambient（istiod + ztunnel + istio-cni + waypoint）+ ArgoCD ApplicationSet PR Generator；PR 泳道不做 namespace 全量複製，改用共享基準環境 + waypoint 依 header 做 L7 流量路由。`placeholder-hello` 改造成兩層（`hello-frontend` → `hello-backend`）並搬進專屬的 `pr-lanes` 命名空間——沒有第二跳就沒有東西向路由可攔，這一層拆分是機制成立的前提 | PR 分支自動起隔離的路由泳道（只複製被改動的那顆服務，非獨立 namespace 複製）；為未來金絲雀發布預留同一套 waypoint 機制 | B、E（需調整 Kyverno 驗簽政策） |
| H. compose 退場評估 | 逐服務判斷是否還需保留 compose | 最終環境收斂決策 | D |

## D+ 選型備註

- **為何是 Headlamp 而非 Kubernetes Dashboard/Rancher/Lens/K9s**：常駐 Web 面板是唯一符合「界面安裝」語意的形態——K9s、Lens 是本機客戶端工具，靠 kubeconfig 連線，不用裝進叢集；Rancher 是多叢集管理平台，額外的 etcd/controller 開銷在 4C/24G 已用掉一半的預算下風險過高；Kubernetes Dashboard 官方版是 kong gateway + api + web + metrics-scraper 四元件組合，量級接近 ArgoCD 那次安裝，Headlamp 是單一 Deployment、單一容器（Go 後端打包 React 前端），資源開銷小得多（社群常見配置 requests 100m CPU/128Mi、limits 500m CPU/256Mi；官方 chart 預設不設限制）
- **權限範圍**：唯讀可視化為主，綁定一個只有 `view` ClusterRole 的 ServiceAccount token 登入——寫入操作在 API 層被 RBAC 擋掉，不只是 UI 隱藏按鈕，貫徹「變更走 GitOps、不走面板」的路線圖原則
- **與 portainer 的關係**：並行互補，不是取代——portainer 靠 docker socket 只看得到宿主機 docker 容器（含兩個非本 repo 管理的專案），k3s 用 containerd，portainer 看不到 pod；Headlamp 補的是 portainer 看不到的 k8s 側，兩者管的是不同的執行環境
- **對外曝露**：比照 ArgoCD 已驗證過的模式（NodePort → NPM → 獨立子網域，`self-only` access list，TLS 終止在 NPM），不另立新模式
- **homepage 卡片**：原規劃比照 3x-ui 排除在外（具叢集可視化能力歸類為安全敏感），但 ArgoCD 實際已經上了卡片，先例已經不成立，Headlamp 比照現狀一併上卡（Infra Services 分類）

## 遷移原則（貫穿全程）

1. 域名/端口對外不變，NPM 繼續當外層入口，其自身的遷移刻意不排進 A~F+G 任何一階段，留到 H 階段才評估：
   - NPM 是「域名/端口不變」承諾的錨點——A~D 每遷移一個服務都是「k3s 內先跑通，再改 NPM 轉發規則」，NPM 本身不動才能讓使用者無感；若 NPM 自己也在遷移中變動，等於同時挪動錨點和被固定的東西，風險疊加
   - 誰接管宿主機 80/443 是前置問題，依賴 A 階段還沒定案的 ingress controller 選型，順序上不可能提前決定
   - NPM 的「遷移」實質上可能是「用 k8s-native ingress + cert-manager 取代 NPM」而非把 NPM 容器化搬進去，這個定性判斷要等 D 階段所有服務都遷完、穩定後才有依據
2. 每階段走完整 spec → plan → implement → 驗證後，才開下一階段的詳細設計
3. 遷移每個服務前，先在叢集內驗證通，再切流量，舊 compose 容器保留到確認穩定再退場

## F+G 合併的原因

原規劃 F（ArgoCD ApplicationSet PR Generator + 泳道配額隔離，namespace-per-PR 全量複製）與 G（Istio Ambient 服務網格 + 漸進式發布）是分開的兩階段，彼此間有已知張力：namespace-per-PR 的隔離模型跟 waypoint 集中在同一 namespace 共用的模型互相打架，原文件曾把這個取捨留到 G 階段才決定。

重新設計後兩階段合併，原因是 PR 泳道改走「共享基準環境 + waypoint 依 header 做 L7 流量路由」（業界對「無深度依賴圖的獨立服務」的標準做法之一，只複製被改動的那一顆服務，其餘共用），而不是 namespace 全量複製——這個做法本身就需要 Istio Ambient 的 waypoint 才能成立，等於 F 階段的交付物直接依賴 G 階段的核心元件，先後拆兩階段沒有意義，張力也隨之消失（沒有 namespace-per-PR，就沒有跟 waypoint 集中模型衝突的問題）。

代價：F+G 合併後的資源門檻大幅提高（istiod + ztunnel + istio-cni + waypoint 合計，即使調到最低量級，也逼近當初裝 dify 那一次的開銷），且提前引入服務網格這個原本規劃在 D 主要服務穩定後才上的重量級元件；範圍縮小為只套用 `placeholder-hello`，不含金絲雀發布（金絲雀/漸進式發布留在同一套 waypoint 機制之後，視需要再擴大範圍，不在這次交付物內）。

## 待 H 階段細化的設計取捨

- 宿主機 80/443 同時間只能被一個進程綁定：現在是 npm 佔著；若換 k3s ingress（k3s 預設 Traefik + 內建輕量 LoadBalancer「Klipper LB」）在前面，等於換一個進程去佔同一個端口，npm 必須讓出——要嘛直接退場，要嘛改綁到其他端口（如 8080/8443）只保留給還沒遷移到 ingress 規則的邊緣情況用。兩者不能同時持有 80/443，切換過程要設計成不中斷的 cutover，不是簡單的「兩邊同時開著」
- ingress 能做到 npm 的核心功能，但走的是不同機制，不是圖形介面點選：
  - HTTPS：靠 `cert-manager`（k8s 原生 ACME 客戶端）自動申請/續期 Let's Encrypt 證書，綁到 ingress 資源上。功能對等，且不會有 npm 已知的「SSL 開關自己重置」的 bug（見 README「給服務接入 NPM 反代」章節），但要另外學 Issuer/Certificate CRD、HTTP-01 vs DNS-01 challenge 這套概念
  - Access List（IP 白名單/Basic Auth）：靠 ingress controller 的 annotation 或 Middleware CRD，例如 Traefik 的 `IPAllowList`/`BasicAuth` Middleware，或 nginx-ingress 的 `nginx.ingress.kubernetes.io/whitelist-source-range` 之類 annotation。功能對等，但配置方式是 YAML，不是表單勾選
- npm 現有的每個 proxy host（SSL 設定、access list 規則等）到 H 階段需要**逐條手動翻譯**成 ingress 的 annotation/CRD，不是一鍵遷移，這是 H 階段實際工作量的主要來源

## 各階段設計文檔

（隨階段推進逐一補上連結）

- A：[叢集基礎層設計](2026-08-05-k3s-phase-a-cluster-foundation-design.md)
- B：[GitOps 啟動設計](2026-08-07-k3s-phase-b-gitops-design.md)
- C：[遷移範本 + 首批服務設計](2026-08-09-k3s-phase-c-migration-template-design.md)
- D：[剩餘服務遷移設計](2026-08-12-k3s-phase-d-remaining-migrations-design.md)
- D+：待建立
- E：待建立
- F+G：[服務網格驅動的 PR 泳道設計](2026-08-18-k3s-phase-fg-mesh-pr-lanes-design.md)
- H：待建立
