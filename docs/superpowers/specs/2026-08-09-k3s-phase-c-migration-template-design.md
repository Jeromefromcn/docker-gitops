# K3s Phase C — 遷移範本 + 首批服務設計

日期：2026-08-09

對應 [K3s 雲原生實驗平台路線圖](2026-08-05-k3s-cloud-native-platform-roadmap.md) 的 C 階段：挑 1~2 個低風險服務跑通 compose→k8s 範本，驗證域名/端口零變動。交付物：可複製的遷移 SOP。

前置：[Phase B GitOps 啟動設計](2026-08-07-k3s-phase-b-gitops-design.md) 已完成並驗證通過。叢集現況：ArgoCD app-of-apps 正常運作（`root` + `argocd` / `phase-a-foundation` / `placeholder-hello` 三個子 Application 皆 `Synced`/`Healthy`），全部開 `prune`/`selfHeal`；NPM→NodePort 橋接模式已驗證過兩次（phase A 的 smoke-test、phase B 的 ArgoCD UI）。

## 範圍

**這階段要做的：**
- 遷移 **homepage**（`ghcr.io/gethomepage/homepage:v1.13.2`）——建立「配置類無狀態服務」的遷移範本
- 遷移 **trilium**（`triliumnext/trilium:v0.104.1`）——建立「帶真實資料的服務」遷移範本，含 PVC 與資料搬遷步驟
- 兩者都納入 app-of-apps（`argocd/apps/` 各一個 Application），部署進 `workloads` 命名空間
- NPM 兩條既有 proxy host 改指向 k8s NodePort，域名不變、使用者無感
- 把整套步驟寫成可複製的 SOP，供 phase D 逐服務套用

**這階段不做的（留給後續階段）：**
- CI 流水線——homepage/trilium 都是直接取用的第三方 image，本 repo 沒有 Dockerfile 可 build，phase B 那條 build→Trivy→Cosign 沒有 build 環節可掛。比照 phase A/B 對 Cilium/ArgoCD 官方 image 的既有做法：在 manifest 裡鎖定 tag，交給 ArgoCD 部署即可
- 舊 compose 容器刪除——切流驗證通過後只**停機不刪除**，作為回滾點；最終去留是 phase H 的決策（路線圖遷移原則 3）
- trilium 資料備份機制——見「已知限制」，是遷移前就存在的既有缺口，不在本階段範圍
- 其餘服務（vikunja+pg、dify、llm、3x-ui）——phase D
- Ingress / cert-manager 取代 NPM——phase H

## 現狀約束

- **資源**：`free -h` 實測 13Gi available。兩個服務的實際佔用（`docker stats`）：homepage 110MiB、trilium 246MiB，CPU 皆近乎閒置
- **`workloads` 配額**：目前 hard cap `requests.cpu: 1` / `requests.memory: 2Gi` / `limits.cpu: 1` / `limits.memory: 2Gi`，已用 `50m`/`64Mi` requests、`100m`/`128Mi` limits（只有 `placeholder-hello`）
- **StorageClass**：`local-path`（`rancher.io/local-path`），`reclaimPolicy: Delete`，**`volumeBindingMode: WaitForFirstConsumer`** —— 這個綁定模式直接決定了資料搬遷的步驟順序，見下方「trilium 資料搬遷」
- **trilium 現有資料**：`/etc/trilium/data`，12MB，屬主 `1000:1000`
- **trilium 的執行身份**：容器以 root 啟動 entrypoint，再由 `su -c node ./main.cjs node` 自行降權到 uid 1000（`docker top` 實測）。**k8s 這邊不能設 `runAsUser`**，否則 entrypoint 的 `su` 會失敗——保持跟 compose 完全一致的行為
- **NodePort 佔用**：目前只有 `30090`（ArgoCD）

## 架構

```
Internet ──▶ NPM（宿主機 80/443，唯一入口，本階段不動）
              │
              │ homepage.jerome.cloudns.asia ─▶ 10.0.0.95:30081 ┐
              │ trilium.jerome.cloudns.asia  ─▶ 10.0.0.95:30082 ┤
              ▼                                                  │
        ┌──────────────────────────────────────────────────────┐ │
        │ k3s ── workloads 命名空間                     ◀───────┘ │
        │                                                        │
        │  homepage   Deployment + NodePort Service              │
        │    └─ ConfigMap（config/*.yaml）─▶ initContainer 複製   │
        │         ─▶ emptyDir（可寫）─▶ 主容器 /app/config        │
        │                                                        │
        │  trilium    Deployment + NodePort Service               │
        │    └─ PVC（local-path，5Gi）─▶ /home/node/trilium-data  │
        └──────────────────────────────────────────────────────┘
              ▲
              │ ArgoCD root Application
              │   ├─ argocd / phase-a-foundation / placeholder-hello（既有）
              │   ├─ homepage           ← 本階段新增
              │   └─ trilium            ← 本階段新增
```

## 元件與設定

| 項目 | 決定 | 理由 |
|---|---|---|
| Image | 沿用 compose 現行 tag：`ghcr.io/gethomepage/homepage:v1.13.2`、`triliumnext/trilium:v0.104.1` | 遷移階段只換執行平台，不同時換版本——出問題時能明確歸因於遷移本身，而不是版本差異 |
| CI | 不建 | 見「這階段不做的」：第三方 image，無 build 環節可掛 |
| homepage 配置載體 | ConfigMap + initContainer 複製進 emptyDir | homepage 會往 config 目錄寫東西（自己的 `logs/homepage.log`，以及啟動時把預設的 `kubernetes.yaml`/`proxmox.yaml` 之類補進去——現有 `config/logs/homepage.log` 有實際記錄），ConfigMap 卷是唯讀的，直接掛會讓它寫入失敗。initContainer 把 ConfigMap 內容 `cp` 進 emptyDir、主容器掛 emptyDir，配置仍然版本化，寫入也不會炸 |
| homepage 容器狀態小組件 | 移除 | 靠唯讀掛載 `/var/run/docker.sock` 實作，k8s 裡沒有對等機制。移除 `docker.yaml` 的 provider 定義與 `services.yaml` 每張卡片的 `container`/`server` 欄位；頂部 `search`/`resources`/`datetime` 三個全域小組件不依賴 docker.sock，原樣保留。改接 homepage 原生的 Kubernetes provider 需要額外的 ServiceAccount + RBAC，為了一個狀態指示燈不值得，明確捨棄 |
| trilium 存儲 | 標準動態 PVC（`local-path` StorageClass），5Gi | 刻意不用 hostPath 直掛現有目錄。hostPath 雖然能省掉搬遷步驟，但繞過 PVC 的生命週期管理，且是 Pod Security Standard「Restricted」與 Kyverno 常見預設規則明令禁止的模式——phase E 就要上 Kyverno，屆時等於要嘛開例外、要嘛重構，不如現在就用對的抽象。5Gi 相對現有 12MB 有大量餘裕，`local-path` 底層是宿主機目錄、不預先佔用空間，開大不花成本 |
| trilium `securityContext` | 不設 `runAsUser` | 見「現狀約束」：entrypoint 以 root 起、自行 `su` 降權到 uid 1000。強制 `runAsUser: 1000` 會讓 `su` 失敗 |
| 資源 requests/limits | homepage `100m`/`192Mi` → `300m`/`384Mi`；trilium `100m`/`320Mi` → `500m`/`640Mi` | 以 `docker stats` 實測值（110MiB / 246MiB）為基準留約 30% 餘裕當 request，limit 再翻倍 |
| `workloads` 配額 | 本階段**不調整** | 加上兩個新服務後：requests `250m`/`576Mi`、limits `900m`/`1152Mi`，都還在 `1`/`2Gi` 之內。但 `limits.cpu` 只剩 `100m` headroom——**phase D 開始前必須先調高配額**，否則第一個新 Application 就會被 quota 擋下。這是已知的、預期在 phase D 處理的事，不是本階段的缺口 |
| 對外暴露 | NodePort：homepage `30081`、trilium `30082` | 沿用 phase A/B 已驗證兩次的 NPM→NodePort 橋接模式。固定 NodePort（非隨機分配）才能讓 NPM 的轉發規則穩定 |
| NPM 設定 | 只改既有兩條 proxy host 的 Forward Hostname/IP + Port，其餘不動 | 域名、SSL 憑證、access list 全部原樣保留，使用者端零變動 |

## Repo 佈局

沿用 phase B 建立的慣例：

```
vps_oracle/k3s/
  argocd/apps/
    homepage.yaml                  # 新增：子 Application → ../../apps/homepage/k8s/
    trilium.yaml                   # 新增：子 Application → ../../apps/trilium/k8s/
  apps/
    homepage/
      k8s/
        configmap.yaml             # config/*.yaml 內容（去掉 docker provider 與卡片的 container/server）
        deployment.yaml
        service.yaml               # NodePort 30081
    trilium/
      k8s/
        pvc.yaml                   # local-path，5Gi
        deployment.yaml
        service.yaml               # NodePort 30082
```

原 `vps_oracle/compose/homepage/`、`vps_oracle/compose/trilium/` 兩個目錄**保持不動**——舊 compose 定義是回滾路徑的一部分，phase H 才決定去留。

## trilium 資料搬遷

`local-path` 的 `WaitForFirstConsumer` 綁定模式決定了步驟順序：PVC 建好之後不會立刻產生宿主機目錄，必須等到有 Pod 真的掛載它並被排程，provisioner 才會建目錄。所以不能「先建 PVC → 複製資料 → 起 Deployment」，而是：

1. **停寫**：`cd vps_oracle/compose/trilium && docker compose stop`（使用者已確認搬遷期間不會有寫入，因此無資料分叉風險）
2. **記錄基準**：搬遷前記下 `/etc/trilium/data` 的檔案數與總大小，作為搬遷後比對的依據
3. **建 PVC + 觸發 provisioner**：手動 apply `pvc.yaml` 與一個一次性的輔助 Pod（掛載該 PVC、`sleep`），跟 phase A `netpol-tester` 同款的手動 apply/delete 工具 Pod 套路。等 PVC 變 `Bound`，從 PV 的 `spec.hostPath` 取得實際宿主機目錄
4. **灌資料**：`sudo rsync -a /etc/trilium/data/ <PV 目錄>/`，然後 `sudo chown -R 1000:1000 <PV 目錄>`（provisioner 建的目錄屬主是 root，trilium 的 node 進程是 uid 1000）
5. **收工具 Pod**：刪掉輔助 Pod（PVC 保留，資料留在原地）
6. **交給 GitOps**：commit + push `trilium.yaml` 這個 Application 與 `apps/trilium/k8s/` 全部 manifest（含 `pvc.yaml`），ArgoCD sync 時會「認領」這個已存在且資料已就位的 PVC——跟 phase B 把 phase A 手動 apply 的 namespace/quota 收編進 GitOps 是同一個模式

搬遷不動原始的 `/etc/trilium/data`（`rsync` 只讀來源），舊 compose 容器停機保留，因此回滾成本極低：`docker compose start` 即可，資料還在原處。

## 遷移 SOP（本階段的核心交付物）

適用於 phase D 每一個服務，逐服務重複：

1. **盤點**：讀 compose 定義，列出 image tag、卷、環境變數、NPM 轉發目標、實測資源佔用（`docker stats`）
2. **翻譯 manifest**：Deployment + Service（固定 NodePort）；卷按性質分流——版本化的配置走 ConfigMap（若服務會寫入該目錄，套 initContainer→emptyDir 模式），有真實資料的走 PVC
3. **搬資料**（僅有狀態服務）：照上方「trilium 資料搬遷」六步
4. **進 GitOps**：`argocd/apps/<service>.yaml` + `apps/<service>/k8s/`，commit、push、sync
5. **內部驗證**：`kubectl -n workloads get pods` Running；`curl http://localhost:<NodePort>` 功能正常——**先在叢集內驗證通，再切流量**（路線圖遷移原則 3）
6. **切流**：改 NPM 該條 proxy host 的 Forward Hostname/IP（宿主機內網 IP，**必須是字面 IP 不能是主機名**——phase A 已知坑）與 Forward Port（NodePort），域名/SSL/access list 全部不動
7. **外部驗證**：從外網 `curl https://<域名>` 確認無感
8. **舊容器停機**：`docker compose stop`（不 `down`、不刪資料），留作回滾點

## 驗證清單（phase C 過關標準）

1. `kubectl -n argocd get applications` → 含新增的 `homepage`、`trilium`，皆 `Synced` + `Healthy`
2. `kubectl -n workloads get pods` → homepage、trilium 皆 `Running`，無 `CrashLoopBackOff`
3. `kubectl -n workloads get pvc trilium` → `Bound`
4. **資料完整性**：搬遷後 PV 目錄的檔案數與總大小跟步驟 2 記錄的基準一致；且從 trilium UI 實際打開既有筆記確認內容正常（檔案數對得上不等於應用讀得出來，兩個都要驗）
5. **內部連通**：`curl http://localhost:30081`（homepage 首頁）、`curl http://localhost:30082`（trilium 登入頁）皆正常回應——這步必須在切 NPM 之前完成
6. **外部無感**：切流後 `curl https://homepage.jerome.cloudns.asia`、`curl https://trilium.jerome.cloudns.asia` 正常，且瀏覽器實際操作一遍（homepage 卡片可點、trilium 能登入並讀寫筆記）
7. `kubectl describe resourcequota -n workloads` → `Used` 在 hard cap 之內，且確認 `limits.cpu` 剩餘 headroom 已記錄下來（phase D 前要調高）
8. **Self-heal 實測**：拿 homepage 做破壞測試（`kubectl -n workloads scale deployment homepage --replicas=0`），確認自動復原。**刻意不用 trilium 做**——它是有真實資料的服務，沒有理由為了測一個已經在 phase B 驗證過的機制而讓它多停機一次
9. 舊 compose 容器：`docker ps -a` 確認 homepage/trilium 為 `Exited` 狀態且**未被刪除**

## 已知限制 / 失敗模式

- **trilium 資料無備份**：`/etc/trilium/data` 目前沒有任何自動備份機制（image 內建的 `backup/` 子目錄是 trilium 自己的資料庫快照，跟宿主機層級的備份不是一回事，同一顆磁碟壞掉一起沒）。這是遷移前就存在的缺口，本階段不順手解決以免範圍蔓延，但遷到 PVC 之後資料實際落在 `/var/lib/rancher/k3s/storage/` 底下、路徑不再直觀，值得單獨開一個工作項處理
- **`local-path` 的 `reclaimPolicy: Delete`**：刪掉 PVC 會連同宿主機上的資料目錄一起刪除。ArgoCD 的 `prune: true` 意味著把 `pvc.yaml` 從 git 移除並 sync 就會觸發這件事。原始資料還在 `/etc/trilium/data`（搬遷不動它）所以目前有救，但 phase H 決定刪除舊 compose 資料之後，這層保險就沒了——屆時處理 PVC 要格外小心
- **trilium 不能設 `runAsUser`** 與 phase E 的 Kyverno/PSS「Restricted」基線直接衝突（該基線要求 `runAsNonRoot: true`）。phase E 需要為 trilium 開例外，或改用能以非 root 啟動的 image。現在記下來，不現在解
- **homepage 的 ConfigMap→emptyDir 模式意味著 homepage 寫進 config 目錄的東西（含自己的 log）在 Pod 重啟後消失**。對 homepage 而言無妨（log 不重要，配置每次從 ConfigMap 重新複製），但這個模式不能無腦套用到「會把重要狀態寫回配置目錄」的服務上——phase D 套用 SOP 時要逐服務判斷
- **NodePort 手動分配**：`30081`/`30082` 是人工挑的，沒有任何機制防止未來的 Application 撞號。服務數量還少時可接受；phase D 會讓這份清單長到需要在 README 裡集中記錄
- **切流瞬間的短暫中斷**：改 NPM 轉發規則會斷開既有連線。兩個服務都不是長連線敏感型（對比 3x-ui 的 VLESS），影響可忽略

## 交棒給 phase D

Phase D（剩餘服務遷移）依賴本階段留下的：上方那份「遷移 SOP」、`apps/homepage/`（無狀態 + ConfigMap 範本）與 `apps/trilium/`（PVC + 資料搬遷範本）兩套可複製的 manifest 佈局、以及 NPM→NodePort 切流的實作經驗。

Phase D 開工前必須先做的一件事：**調高 `workloads` 的 ResourceQuota**（見上方「元件與設定」，`limits.cpu` 屆時只剩 `100m` headroom）。

Phase D 會碰到本階段刻意沒覆蓋的新問題：多容器服務的拆分（dify 全家桶）、Service 間依賴與啟動順序、資料庫類服務的 StatefulSet vs Deployment 取捨、3x-ui 的 39876 原始 TCP 透傳（不能走 HTTP 反代，見路線圖現狀約束），以及 llm 推理棧的大記憶體/多核資源預算。
