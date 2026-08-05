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
| C. 遷移範本 + 首批 | 挑 1~2 個低風險無狀態服務（homepage、trilium）跑通 compose→k8s 範本，驗證域名/端口零變動 | 可複製的遷移 SOP | A、B |
| D. 剩餘服務遷移 | 有狀態服務（vikunja+pg、dify 全家桶）、llm 推理棧、3x-ui 的 39876 TCP 透傳 | 逐服務遷移 + compose 去留決策 | C |
| E. 供應鏈安全加固 | Trivy 准入門禁、Cosign 驗簽、Sealed Secrets、Kyverno | 鏡像/部署有政策把關 | B、D 服務已上線 |
| F. 多環境 PR 泳道 | ArgoCD ApplicationSet PR Generator + 泳道配額隔離 | PR 分支自動起隔離環境 | B |
| G. 服務網格 + 漸進式發布 | Istio Ambient，按 namespace 選擇性啟用，有狀態服務不進網格；金絲雀發布（Argo Rollouts + waypoint 做 L7 流量切分） | L4/L7 流量治理 + 漸進式發布 | D 主要服務已穩定 |
| H. compose 退場評估 | 逐服務判斷是否還需保留 compose | 最終環境收斂決策 | D |

## 遷移原則（貫穿全程）

1. 域名/端口對外不變，NPM 繼續當外層入口，其自身的遷移刻意不排進 A~G 任何一階段，留到 H 階段才評估：
   - NPM 是「域名/端口不變」承諾的錨點——A~D 每遷移一個服務都是「k3s 內先跑通，再改 NPM 轉發規則」，NPM 本身不動才能讓使用者無感；若 NPM 自己也在遷移中變動，等於同時挪動錨點和被固定的東西，風險疊加
   - 誰接管宿主機 80/443 是前置問題，依賴 A 階段還沒定案的 ingress controller 選型，順序上不可能提前決定
   - NPM 的「遷移」實質上可能是「用 k8s-native ingress + cert-manager 取代 NPM」而非把 NPM 容器化搬進去，這個定性判斷要等 D 階段所有服務都遷完、穩定後才有依據
2. 每階段走完整 spec → plan → implement → 驗證後，才開下一階段的詳細設計
3. 遷移每個服務前，先在叢集內驗證通，再切流量，舊 compose 容器保留到確認穩定再退場

## 待 G 階段細化的設計取捨

- Ambient 的 waypoint 是 namespace（或更細至 service account）層級的 Deployment，不是每個 pod 一份，可以把需要 L7（含金絲雀切流）的服務集中到同一個 namespace，共用一份單副本 waypoint，資源開銷小
- 這與 F 階段「按 PR 泳道分 namespace」的隔離模型有潛在衝突：若某個做金絲雀的服務也會被 PR 泳道複製出獨立環境，需要在 G 階段決定——每條泳道各自起一個 waypoint，還是把金絲雀/L7 示例限定在主環境、不隨泳道複製

## 待 H 階段細化的設計取捨

- 宿主機 80/443 同時間只能被一個進程綁定：現在是 npm 佔著；若換 k3s ingress（k3s 預設 Traefik + 內建輕量 LoadBalancer「Klipper LB」）在前面，等於換一個進程去佔同一個端口，npm 必須讓出——要嘛直接退場，要嘛改綁到其他端口（如 8080/8443）只保留給還沒遷移到 ingress 規則的邊緣情況用。兩者不能同時持有 80/443，切換過程要設計成不中斷的 cutover，不是簡單的「兩邊同時開著」
- ingress 能做到 npm 的核心功能，但走的是不同機制，不是圖形介面點選：
  - HTTPS：靠 `cert-manager`（k8s 原生 ACME 客戶端）自動申請/續期 Let's Encrypt 證書，綁到 ingress 資源上。功能對等，且不會有 npm 已知的「SSL 開關自己重置」的 bug（見 README「給服務接入 NPM 反代」章節），但要另外學 Issuer/Certificate CRD、HTTP-01 vs DNS-01 challenge 這套概念
  - Access List（IP 白名單/Basic Auth）：靠 ingress controller 的 annotation 或 Middleware CRD，例如 Traefik 的 `IPAllowList`/`BasicAuth` Middleware，或 nginx-ingress 的 `nginx.ingress.kubernetes.io/whitelist-source-range` 之類 annotation。功能對等，但配置方式是 YAML，不是表單勾選
- npm 現有的每個 proxy host（SSL 設定、access list 規則等）到 H 階段需要**逐條手動翻譯**成 ingress 的 annotation/CRD，不是一鍵遷移，這是 H 階段實際工作量的主要來源

## 各階段設計文檔

（隨階段推進逐一補上連結）

- A：[叢集基礎層設計](2026-08-05-k3s-phase-a-cluster-foundation-design.md)
- B：待建立
- C：待建立
- D：待建立
- E：待建立
- F：待建立
- G：待建立
- H：待建立
