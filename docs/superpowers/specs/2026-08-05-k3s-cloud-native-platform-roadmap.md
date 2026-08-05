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
- 同機還跑著兩個不屬本 repo 管理的專案（`lab-environment`、`programming-learning-platform`），直接佔用 8080/9090/3001/3100 等宿主機端口，規劃時要避開

## 階段路線圖

| 階段 | 目標 | 交付物 | 依賴 |
|---|---|---|---|
| A. 叢集基礎層 | K3s + containerd + Cilium（CNI/NetworkPolicy）+ 存儲 + 資源預算（ResourceQuota/LimitRange） | 空的但可連通的叢集，NPM 能打進來 | — |
| B. GitOps 啟動 | ArgoCD（app-of-apps）+ GitHub Actions CI 骨架（build→Trivy→Cosign） | 之後所有部署都走 GitOps，不手動 `kubectl apply` | A |
| C. 遷移範本 + 首批 | 挑 1~2 個低風險無狀態服務（homepage、trilium）跑通 compose→k8s 範本，驗證域名/端口零變動 | 可複製的遷移 SOP | A、B |
| D. 剩餘服務遷移 | 有狀態服務（vikunja+pg、dify 全家桶）、llm 推理棧、3x-ui 的 39876 TCP 透傳 | 逐服務遷移 + compose 去留決策 | C |
| E. 供應鏈安全加固 | Trivy 准入門禁、Cosign 驗簽、Sealed Secrets、Kyverno | 鏡像/部署有政策把關 | B、D 服務已上線 |
| F. 多環境 PR 泳道 | ArgoCD ApplicationSet PR Generator + 泳道配額隔離 | PR 分支自動起隔離環境 | B |
| G. 服務網格 | Istio Ambient，按 namespace 選擇性啟用，有狀態服務不進網格 | L4/L7 流量治理 | D 主要服務已穩定 |
| H. compose 退場評估 | 逐服務判斷是否還需保留 compose | 最終環境收斂決策 | D |

## 遷移原則（貫穿全程）

1. 域名/端口對外不變，NPM 繼續當外層入口（至少初期；是否最終也遷入叢集留到後期評估）
2. 每階段走完整 spec → plan → implement → 驗證後，才開下一階段的詳細設計
3. 遷移每個服務前，先在叢集內驗證通，再切流量，舊 compose 容器保留到確認穩定再退場

## 各階段設計文檔

（隨階段推進逐一補上連結）

- A：待建立
- B：待建立
- C：待建立
- D：待建立
- E：待建立
- F：待建立
- G：待建立
- H：待建立
