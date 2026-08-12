# K3s Phase D — 剩餘服務遷移設計

日期：2026-08-12

對應 [K3s 雲原生實驗平台路線圖](2026-08-05-k3s-cloud-native-platform-roadmap.md) 的 D 階段：把剩餘服務逐個遷進 k3s，輸出每服務的「遷移結果 + compose 去留決策」。本階段範圍：**vikunja 棧**、**dify 全家桶**、**llm 推理棧**遷入；**3x-ui 保留在 compose**（39876 客戶端直連太關鍵，見「3x-ui 去留決策」）。

前置：[Phase C 遷移範本設計](2026-08-09-k3s-phase-c-migration-template-design.md) 已完成並驗證通過。叢集現況（2026-08-12 實測）：7 個 Application 皆 `Synced`/`Healthy`（argocd、phase-a-foundation、placeholder-hello、homepage、trilium、evidence-os-website、root）；NodePort 佔用 `30081`(homepage)/`30082`(trilium)/`30083`(evidence)/`30090`(argocd)；`workloads` 配額 `2C/4Gi`，實際使用 `limits.cpu 1` / `limits.memory 1280Mi`，餘裕充足。

## 範圍

**這階段要做的：**
- 遷 **vikunja 棧** 進 `workloads`：vikunja（含 sqlite 資料搬遷）+ vikunja-notify-relay + apprise（relay 的唯一外部依賴，一起遷才不用跨 docker/k8s 邊界）
- 遷 **dify 全家桶**（9 容器）進新 `dify` 命名空間：db-postgres、pgvector、redis、ssrf-proxy、plugin-daemon、api、worker、worker-beat、web
- 遷 **llm 推理棧** 進新 `llm` 命名空間：llama-cpp、open-webui、sillytavern（目前整棧已停機，等於在 k8s 重建、無切流中斷）
- **3x-ui**：不遷，compose 去留決策記為「保留」
- 交付物：逐服務遷移結果 + 每服務 compose 去留決策

**這階段不做的（留給後續階段）：**
- 3x-ui 遷移——39876 是客戶端直連的原始 TCP（不走 HTTP 反代），有真實故障史（見路線圖現狀約束）；要遷的候選機制（Klipper LB 綁 39876）留在本設計文附錄，本階段不動它
- Ingress / cert-manager 取代 NPM——phase H
- Sealed Secrets / 供應鏈安全（Trivy 准入、Cosign 驗簽、Kyverno）——phase E；D 用「手動建 Secret」暫代（見「Secrets 策略」）
- dify / llm 的 CI 流水線——全是第三方 image（digest 釘住），沒有 build 環節可掛；唯一本地 build 的是 vikunja-notify-relay（見「relay 映像」）
- 資料備份機制——遷移前就存在的既有缺口，phase C 已記錄，不在本階段順手解
- NPM 本身的遷移/退場——phase H 才評估

## 現狀約束

- **資源**：4C/24G（Oracle Ampere ARM），`free -h` 實測 23Gi 總、約 12Gi available。既有的 docker compose 側（monitoring、ccr、provider-switch、portainer、npm、programming-learning-platform、lab-environment 等）加上 k3s 側（argocd、cilium、homepage/trilium/evidence/placeholder）已吃掉約一半記憶體
- **llm 棧目前是停機狀態**：`docker compose ps -a` 顯示 llama-cpp / open-webui / sillytavern 三個容器都不存在（曾被 `docker compose down`）。因此 llm 的遷移沒有「停寫 → 搬資料 → 切流」的節奏，資料（models 1.9G、openwebui 894M、sillytavern 21M）都是靜止的，直接複製進 PVC 即可
- **dify 圖片體積**：7 個 image 未壓縮合計約 8.5GB（dify-api 4.09GB、dify-plugin-daemon 2.26GB 為大宗；dify-api 的主因是 2.42GB 的 Python venv + 420MB apt 層含 `fonts-noto-cjk`）。containerd 與 docker 是獨立的 image store，遷移時要重新拉一份。磁碟無虞（193G 總、89G 可用），成本只有一次性拉取時間；若在意可 `docker save` → `ctr images import` 預載
- **apprise 是 relay 的唯一外部依賴**：relay 以 `APPRISE_BASE_URL=http://apprise:8000` 訪問 apprise（docker DNS）。relay 遷進 k8s 後解析不到 docker DNS，所以 apprise 必須跟著遷（k8s 內同名的 `apprise` Service 讓這個 URL 原樣可通），或把 apprise 的 8000 發布到宿主機讓 k8s 跨邊界訪問——後者把 k8s 工作負載耦合到 compose 宿主機端口，較醜，本設計採前者
- **vikunja 現役是 sqlite，不是 postgres**：`VIKUNJA_DATABASE_TYPE: sqlite`。路線圖 D 的「vikunja+pg」是理想化描述，實際這棧沒跑 postgres。遷移期同時換資料庫引擎風險太高（Phase C 原則：只換執行平台、不同時換版本/架構），本階段 sqlite 原樣遷，`vikunja.db` 進 PVC
- **dify 的 NPM host 有 8 條 custom locations**（實測 NPM DB）：`/console/api`、`/api`、`/v1`、`/files`、`/mcp`、`/triggers`、`/openapi` → api:5001，`/e/` → plugin-daemon:5002，預設 → web:3000。遷移後這 8 條 location 的 Forward Host/Port 要逐一改成對應的 NodePort
- **dify api/worker/worker-beat 共享同一個 storage 目錄**：compose 裡三者都掛 `/etc/dify/storage:/app/api/storage`。k8s 裡這是一個 RWO PVC 同時被三個 pod 掛載——單節點叢集上合法（RWO 的語義是「單一 node」，同一節點的多個 pod 可共用），本階段依賴這點，見「已知限制」
- **dify service 名不能有底線**：k8s Service 名受 RFC 1123 限制，`db_postgres`/`worker_beat`/`plugin_daemon`/`ssrf_proxy` 要改成 `db-postgres` 等連字號名，api/worker 等 env 裡的 `DB_HOST`/`PLUGIN_DAEMON_URL`/`SSRF_PROXY_HTTP_URL` 一併改
- **NPM 的 Forward Hostname/IP 必須是字面 IP**（phase A 已知坑）：所有新 NodePort 都指向 `10.0.0.95`

## 架構

```
Internet ──▶ NPM（宿主機 80/443，唯一入口，本階段不動）
              │
              │ vikunja.jerome.cloudns.asia        ─▶ 10.0.0.95:30084
              │ apprise.jerome.cloudns.asia        ─▶ 10.0.0.95:30085
              │ dify.jerome.cloudns.asia           ─▶ 30086(web 預設) / 30087(api: /api /v1 /files /mcp /triggers /openapi /console/api) / 30088(plugin-daemon: /e/)
              │ ollama.jerome.cloudns.asia         ─▶ 10.0.0.95:30089  (open-webui)
              │ sillytavern.jerome.cloudns.asia    ─▶ 10.0.0.95:30091
              │（panel/sub.3x、3xpanel ─▶ compose 3x-ui，不變）
              ▼
        ┌─────────────────────────────────────────────────────────┐
        │ k3s                                                     │
        │                                                         │
        │  workloads ns（既有）                                    │
        │    vikunja  Deployment+PVC(sqlite+files) ─ NodePort 30084
        │    vikunja-relay Deployment（無狀態，ClusterIP）         │
        │    apprise   Deployment+PVC(config 40K) ─ NodePort 30085│
        │                                                         │
        │  dify ns（本階段新增）                                    │
        │    db-postgres / pgvector / redis   StatefulSet+PVC      │
        │    ssrf-proxy / plugin-daemon / api / worker /           │
        │    worker-beat / web                Deployment          │
        │    （api/worker/beat 共用 storage PVC；                 │
        │      egress NetworkPolicy 做 SSRF 隔離）                │
        │                                                         │
        │  llm ns（本階段新增）                                    │
        │    llama-cpp   Deployment+PVC(models)  ClusterIP        │
        │    open-webui  Deployment+PVC(data)   ─ NodePort 30089  │
        │    sillytavern Deployment+PVC(config) ─ NodePort 30091  │
        └─────────────────────────────────────────────────────────┘
              ▲
              │ ArgoCD root Application
              │   ├─ 既有（argocd / phase-a-foundation / placeholder-hello / homepage / trilium / evidence-os-website）
              │   ├─ vikunja   ← 本階段新增（vikunja + relay）
              │   ├─ apprise   ← 本階段新增
              │   ├─ dify      ← 本階段新增（含 dify ns + quota + NetworkPolicy）
              │   └─ llm       ← 本階段新增（含 llm ns + quota）
```

## 命名空間與配額

依設計決定：**大棧獨立命名空間**，`workloads` 只留小服務。

| 命名空間 | 內容 | 配額 | 理由 |
|---|---|---|---|
| `workloads`（既有） | vikunja + relay + apprise | 不調（`2C/4Gi`） | 加進 vikunja 棧後 requests 約 `350m`/`384Mi`、limits 約 `700m`/`768Mi`，加上既有 `1C/1280Mi` 仍在 `2C/4Gi` 內 |
| `dify`（新增） | 9 容器 | requests `2.5C/2Gi`，limits `3C/4Gi` | 以 `docker stats` 實測（~1.34Gi 總）為基準留 30% 餘裕、limit 翻倍；獨立 ns 才能用自己的配額、不被其他棧擠掉 |
| `llm`（新增） | llama-cpp + open-webui + sillytavern | requests `2C/4Gi`，limits `5C/13Gi` | llama.cpp 的 9G limit 是「防 OOM 上限」不是常駐需求（3B 模型實際 ~2-3G）。**刻意打破 phase C「request==limit」慣例**：request 設低才不會替一個通常閒置的推理棧白白鎖住半台機器的記憶體，limit 設高是保護。節點本身 4C/24G，limits 超賣（5C/13Gi > 物理上限）是正常、且本來就只剩 ~12Gi 可給它 |

dify / llm 的 namespace + ResourceQuota 各自放在對應 app 的 `k8s/` 目錄裡，由各自的 ArgoCD Application 建立與管轄（對照 phase-a-foundation 管 `workloads` 的做法，但本階段把 ns/quota 收進 app 自己，隨 app 一起 prune）。

## 元件與設定

### vikunja 棧（workloads）

| 項目 | 決定 | 理由 |
|---|---|---|
| vikunja image | `vikunja/vikunja:2.4.0`（沿用現行 tag） | Phase C 原則：只換平台不換版本 |
| vikunja 資料庫 | sqlite 原樣遷 | 見「現狀約束」：現役就是 sqlite，遷移期不順便換 postgres |
| vikunja 儲存 | 1 個 PVC（`local-path`，2Gi），子目錄分掛 `files` → `/app/vikunja/files`、`db` → `/db` | 沿用 trilium PVC 模式；`/etc/vikunja` 才 4.8M，2Gi 綽綽有餘。資料搬遷照 trilium 六步（seed pod） |
| vikunja env | 保留全部：`TZ`、`VIKUNJA_SERVICE_SECRET`（secret）、`VIKUNJA_SERVICE_PUBLICURL`、`ENABLEREGISTRATION=false`、`ALLOWNONROUTABLEIPS=true` | `ALLOWNONROUTABLEIPS=true` 在 k8s 一樣要——relay 的 ClusterIP 是私網段，不開會被 vikunja 自己的 SSRF 防護擋掉 |
| vikunja NodePort | `30084`（內網 3456） | NPM→NodePort 橋接 |
| vikunja `enableServiceLinks` | **false** | Service 名 `vikunja` 會注入 `VIKUNJA_PORT=tcp://...`，撞 vikunja 自己讀的 `VIKUNJA_*` 環境變量——trilium 的 `TRILIUM_PORT` 教訓直接重演。**本階段所有遷移 pod 一律設 false** |
| relay image | 推到 GHCR（`ghcr.io/jeromefromcn/vikunja-notify-relay:<tag>`） | 目前是 `docker compose build` 的本地 image，k8s 拉不到。見「relay 映像」 |
| relay | Deployment 無狀態，ClusterIP `vikunja-notify-relay:8080`，`enableServiceLinks: false` | Service 名保持跟 compose 一致，vikunja DB 裡已註冊的 webhook URL `http://vikunja-notify-relay:8080/` 才能原樣解析 |
| apprise image | `caronc/apprise:v1.5.1` | 沿用 |
| apprise 儲存 | 1 個 PVC（40K config） | `/config` 是 apprise 自己的持久化（放 `vikunja-tg-{username}` 那些 target），不是版本化配置，必須 PVC。seed pod 搬 `/etc/apprise/config` |
| apprise NodePort | `30085`（內網 8000） | relay 以 `http://apprise:8000` 訪問（k8s 內 DNS 同名），NPM 的 `apprise.jerome.cloudns.asia` 改指 NodePort |
| 資源 requests/limits | vikunja `100m/128Mi → 300m/256Mi`；relay `50m/64Mi → 100m/128Mi`；apprise `200m/192Mi → 300m/384Mi` | 以 `docker stats` 實測（38Mi/13Mi/135Mi）為基準；合計仍在 `workloads` 配額內 |
| NPM | `vikunja` → `10.0.0.95:30084`、`apprise` → `10.0.0.95:30085` | 域名/SSL/access list 不動 |

### dify（dify 命名空間）

| 項目 | 決定 | 理由 |
|---|---|---|
| image | 沿用 compose 現行 digest（api/worker/worker-beat 共用 `langgenius/dify-api:1.14.2@sha256:0628…`，web `1.14.2@sha256:db73…`，plugin-daemon `0.6.1-local@sha256:fa7a…`，pg 等照舊） | 只換平台不換版本；版本與 image 都釘死 |
| StatefulSet vs Deployment | **db-postgres / pgvector / redis 用 StatefulSet**；其餘（ssrf-proxy、plugin-daemon、api、worker、worker-beat、web）用 Deployment | 單節點上 RWO PVC + Deployment rolling update 時新舊 pod 短暫並存，StatefulSet 的順序化更新讓 RWO 掛載不打架；StatefulSet 也給資料庫穩定的網路身份 |
| Service 命名 | `db-postgres`、`pgvector`、`redis`、`ssrf-proxy`、`plugin-daemon`、`api`、`web`；env 的 `DB_HOST: db-postgres`、`SSRF_PROXY_HTTP_URL: http://ssrf-proxy:3128`、`PLUGIN_DAEMON_URL: http://plugin-daemon:5002` 等一併改 | k8s Service 名不允許底線 |
| 哪些要 NodePort | **web(30086)、api(30087)、plugin-daemon(30088)**；其餘 ClusterIP 內網 | 對應 NPM 的三個後端（預設 → web、7 條 location → api、`/e/` → plugin-daemon）。worker/worker-beat/ssrf-proxy/db/redis/pgvector 無外部入口 |
| SSRF 隔離 | **雙層**：(1) 應用層——沿用 compose 的 `SSRF_PROXY_HTTP_URL/HTTPS_URL=http://ssrf-proxy:3128`，api/worker 的外出 HTTP 走 squid，squid.conf 攔私網/metadata；(2) 網路層——dify ns 的 **egress NetworkPolicy**：api/worker/worker-beat 只准出到同 ns Service（含 ssrf-proxy）+ DNS，不准直連外網；plugin-daemon 准出外網（它的 model 提供方調用是直連、不走 squid，compose 沒給它設 proxy env）；ssrf-proxy 准出外網；web 准出同 ns + 外網（marketplace） | compose 的 `ssrf_proxy_network: internal` 是網絡層隔離但 api/plugin 同時也在 proxy 網絡上、實際上仍有直連外網的通道，屬於「應用層代理 + 殘缺的網絡隔離」。k8s 用 egress NetworkPolicy 把隔離補完整。**ingress 不做 default-deny**——NPM 進來的 `world` 流量要能到 web/api/plugin-daemon 的 NodePort（k8s README 記的坑：default-deny + NPM 需要額外 allow-world，這裡直接不設 default-deny 省掉） |
| SSRF 驗證門檻 | 遷完必須**跑一個真實 workflow**（含 HTTP-request node 與 LLM 對話）確認：SSRF 隔離沒擋到正常模型調用、HTTP node 仍能出外網 | 若 egress 政策把 model 調用誤擋，fallback 是只留應用層隔離、撤掉網絡層（見「已知限制」） |
| 儲存 | 5 個 PVC：`db-postgres`、`pgvector`、`redis`、`plugin-daemon`、`storage`（api/worker/beat 共享，RWO 單節點語義） | 對應 compose 5 個 `/etc/dify/*` 目錄。`storage` 共享依賴單節點（見「已知限制」）。db/pgvector/redis 走 StatefulSet 各自的 PVC |
| `enableServiceLinks` | 全部 **false** | 統一避開 `<SVC>_PORT` 撞 env |
| 秘密 | `dify-secrets`（DB_PASSWORD、PGVECTOR_PASSWORD、REDIS_PASSWORD、SECRET_KEY、INIT_PASSWORD）手動建立 | 見「Secrets 策略」；plugin-daemon 的 `SERVER_KEY`/`DIFY_INNER_API_KEY` 是上游內定值（compose 已提交、作者註明非敏感），留在 manifest 即可 |
| 配置 | ssrf-proxy 的 `squid.conf.template` + `docker-entrypoint.sh` → ConfigMap | 這兩個檔在 repo 裡，走 ConfigMap 掛載 |
| 首啟 | 保留 `MIGRATION_ENABLED: "true"`（api 啟動跑 DB migration）、`INIT_PASSWORD` | 沿用 compose 行為 |

### llm 推理棧（llm 命名空間）

| 項目 | 決定 | 理由 |
|---|---|---|
| llama-cpp | Deployment + ClusterIP `llama-cpp:8080`，models 目錄 → PVC（1.9G），env 保留 `LLAMA_ARG_THREADS=3`/`CTX_SIZE=8192`/`CACHE_RAM=4096`，resources `1C/2Gi → 3C/9Gi` | 沿用 compose 的 router 模式與資源上限（Ampere 優化的 `amperecomputingai/llama.cpp:3.4.2`，別換回 ollama）。目前停機中＝PVC 從 `/etc/llama-cpp/models` 複製，無並發寫入風險 |
| open-webui | Deployment + NodePort `30089`，`/app/backend/data` → PVC（894M），`WEBUI_SECRET_KEY` secret，`OPENAI_API_BASE_URLS=http://llama-cpp:8080/v1`（k8s DNS） | NPM 的 `ollama.jerome.cloudns.asia` 域名實際指的就是 open-webui（歷史遺留命名），域名不動、只把 Forward 改指 NodePort |
| sillytavern | Deployment + NodePort `30091`，config/data/plugins/extensions → PVC（21M），basic auth 憑證 secret | ST 的 `SILLYTAVERN_<path>` env 覆蓋機制在 compose 已用來注入帳密（`.env`），k8s 用 secretKeyRef 注入同名 env。Service 名 `sillytavern` 會注入 `SILLYTAVERN_PORT`，而 ST 的泛用 env 覆蓋機制會誤讀它 → **`enableServiceLinks: false` 必設** |
| 資源 | llama-cpp `1C/2Gi → 3C/9Gi`；open-webui `500m/1Gi → 1C/2Gi`；sillytavern `200m/256Mi → 200m/512Mi` | 合計 limits `4.2C/11.5Gi`，落在 llm ns 配額 `5C/13Gi` 內 |
| 內網通訊 | 只有 open-webui / sillytavern → llama-cpp 需要互相通，ClusterIP 即可 | 不接 NPM 以外任何入口 |

### relay 映像

`vikunja-notify-relay` 是 repo 內唯一本地 build 的 image（Dockerfile + app.py + test_app.py 都在 `vps_oracle/compose/vikunja/notify-relay/`）。k8s 要拉得動，得推到 registry：

- **推薦**：加一個 GitHub Actions workflow，照 `placeholder-hello.yml` 的既有形狀（build `linux/arm64` → Trivy → keyless Cosign → push 到 `ghcr.io/jeromefromcn/vikunja-notify-relay`），trigger 指向 `vps_oracle/compose/vikunja/notify-relay/**`。與路線圖「之後所有部署都走 GitOps」一致，也讓 relay 後續修改可重現
- 退回方案：手動 `docker build` + `docker push` 一次。可接受，但失去 CI 的可重現性

### Secrets 策略（phase E 前的暫代）

**手動、帶外建立 Secret，不進 git**。原因：ArgoCD 的 repo-server 從 git clone，gitignored 的 `.env` 不在 repo 裡，Kustomize `secretGenerator` 讀不到——這條路在 GitOps 下走不通。改用：

- 來源：各 compose 目錄既有的 gitignored `.env`（`vikunja/.env`、`dify/.env`、`llm/.env`）
- 建立：`kubectl create secret generic <name> --from-env-file=<該 .env>`（或 `--from-literal` 指定 key）
- 消費：Deployment/StatefulSet 用 `secretKeyRef` 引用
- ArgoCD 不會動這些 Secret（不在 repo 的資源，prune/selfHeal 只管 ArgoCD 自己管理的），所以能存活；**每次 sync 前要確認 Secret 存在**（plan 的步驟會驗）
- phase E 用 Sealed Secrets 接管後，這些帶外 Secret 退場

| 命名空間 | Secret | 內容 |
|---|---|---|
| workloads | `vikunja` | `VIKUNJA_SERVICE_SECRET` |
| dify | `dify-secrets` | `DB_PASSWORD`、`PGVECTOR_PASSWORD`、`REDIS_PASSWORD`、`SECRET_KEY`、`INIT_PASSWORD` |
| llm | `open-webui` | `WEBUI_SECRET_KEY` |
| llm | `sillytavern` | `SILLYTAVERN_BASICAUTHUSER_USERNAME`、`SILLYTAVERN_BASICAUTHUSER_PASSWORD` |

## Repo 佈局

沿用 phase B/C 慣例，一個 compose stack 對應一個 child Application。dify / llm 的 namespace + quota 收進各自 app 目錄：

```
vps_oracle/k3s/
  argocd/apps/
    vikunja.yaml                # 新增 → ../../apps/vikunja/k8s/（vikunja + relay 同一個 Application）
    apprise.yaml                # 新增 → ../../apps/apprise/k8s/
    dify.yaml                   # 新增 → ../../apps/dify/k8s/
    llm.yaml                    # 新增 → ../../apps/llm/k8s/
  apps/
    vikunja/k8s/
      pvc.yaml                  # local-path，2Gi
      deployment.yaml           # vikunja
      service.yaml              # NodePort 30084
      relay/deployment.yaml     # vikunja-notify-relay
      relay/service.yaml        # ClusterIP 8080
    apprise/k8s/
      pvc.yaml                  # local-path，1Gi（40K config）
      deployment.yaml
      service.yaml              # NodePort 30085
    dify/k8s/
      namespace.yaml            # dify ns
      resourcequota.yaml        # requests 2.5C/2Gi, limits 3C/4Gi
      networkpolicies.yaml      # SSRF egress 隔離
      configmap.yaml            # ssrf squid.conf + entrypoint
      db-postgres.yaml          # StatefulSet + Service + PVC
      pgvector.yaml             # StatefulSet + Service + PVC
      redis.yaml                # StatefulSet + Service + PVC
      ssrf-proxy.yaml           # Deployment + Service
      plugin-daemon.yaml        # Deployment + Service + PVC
      api.yaml                  # Deployment + Service(NodePort 30087)
      worker.yaml               # Deployment
      worker-beat.yaml          # Deployment
      web.yaml                  # Deployment + Service(NodePort 30086)
      storage-pvc.yaml          # api/worker/beat 共享
    llm/k8s/
      namespace.yaml            # llm ns
      resourcequota.yaml        # requests 2C/4Gi, limits 5C/13Gi
      llama-cpp.yaml            # Deployment + Service + PVC(models)
      open-webui.yaml           # Deployment + Service(NodePort 30089) + PVC
      sillytavern.yaml          # Deployment + Service(NodePort 30091) + PVC
```

原 `vps_oracle/compose/{vikunja,dify,llm}/` 保持不動——舊 compose 定義是回滾路徑，phase H 才決定去留。`vps_oracle/compose/3x-ui/` 同理（本就決定保留）。

dify / llm 的 child Application 要加 `syncPolicy.syncOptions: [CreateNamespace=true]`（新命名空間由 ArgoCD 建立，`k8s/` 目錄裡照樣放 `namespace.yaml` 供它管轄）；vikunja / apprise 落在既有 `workloads` ns，不需要。

## 遷移 SOP（沿用 phase C，逐服務套用）

phase C 的 SOP 原樣適用，逐服務重複（盤點 → 翻譯 manifest → 搬資料 → 進 GitOps → 內部驗證 → 切流 → 外部驗證 → 舊容器停機）。本階段新增三個注意點：

1. **多容器棧的依賴順序**：dify 有 9 個 pod、Service 間有依賴。ArgoCD sync 一次全建，靠 initContainer/readiness 而非依賴排序；但**驗證要從底層往上**（db/redis healthy → api/worker 起來 → web 起來 → 跑 workflow）
2. **DB 資料搬遷順序**：照 trilium 六步，seed pod 觸發 `WaitForFirstConsumer` provisioner → rsync → chown（dify 的 storage 屬主是 uid 1001，postgres/pgvector/redis 的資料目錄屬主是各自 image 的 postgres/redis uid，搬完要 `chown` 對）
3. **NPM custom locations**：dify 那 8 條 location 要逐一改 Forward Host/Port，不只改預設 forward。用 NPM automation API（`vps_oracle/compose/npm/.npm-automation.env` + README）逐 location `PUT`

## 遷移順序

1. **vikunja 棧**（最簡單、自包含）——驗證「多 pod 互相依賴 + sqlite PVC + relay 進 registry + webhook URL 沿用」這套，為後面兩個棧打底
2. **dify**（最大、最重）——9 容器、3 個 StatefulSet、SSRF NetworkPolicy、5 個 secret、8 條 NPM location。自包含、低外部風險
3. **llm**（目前停機，無切流）——排最後因為它是休眠狀態、不急著復活，且資源佔用最大（一跑就 3C/9G）

每個服務遷完並穩定（過關清單通過）才開下一個。

## 驗證清單（phase D 過關標準）

**共通（每個服務）：**
1. `kubectl -n <ns> get applications` → 新增的 `vikunja`、`apprise`、`dify`、`llm` 皆 `Synced` + `Healthy`
2. `kubectl get pods -n <ns>` → 全部 `Running`，無 `CrashLoopBackOff`
3. PVC 皆 `Bound`
4. **內部連通**：切 NPM 前先 `curl http://localhost:<NodePort>` 驗證（vikunja 登入頁、apprise 根路徑、dify web 首頁、open-webui 登入頁、sillytavern）
5. **資料完整性**：搬遷後 PV 目錄檔案數/大小與基準一致（phase C 的「檔案數別在停容器瞬間量」教訓）；有狀態服務在 UI 實際讀寫驗證
6. **外部無感**：改 NPM 後 `curl https://<域名>` 正常 + 瀏覽器實操
7. **舊 compose 容器停機保留**：`docker ps -a` 為 `Exited`，未被刪除（llm 本就無容器）

**服務特定：**
8. **vikunja**：登入、建任務；**Telegram 通知端到端**（改任務觸發 webhook → relay → apprise → Telegram 收到）——證明 relay+apprise 遷移後整條鏈還通
9. **dify**：登入（`INIT_PASSWORD` 首登）；跑一個**真實 workflow**：LLM 對話 + 含 HTTP-request node 的應用（證明 SSRF 隔離沒誤擋、模型調用正常、HTTP node 能出外網）；上傳一份文件進知識庫（證明共享 storage 的讀寫正常）
10. **llm**：open-webui 開對話 → llama.cpp 正常推理（3B 模型）；sillytavern 能連後端
11. **配額**：`kubectl describe resourcequota -n {dify,llm}` → `Used` 在 hard cap 內；`workloads` 也在
12. **NodePort**：新 NodePort（30084-30089、30091）無撞號（`kubectl get svc -A` 複查）

## 已知限制 / 失敗模式

- **dify 共享 storage 依賴單節點語義**：RWO PVC 被 api/worker/beat 三個 pod 掛載，靠「RWO=單一 node、本叢集只有一個 node」成立。一旦上多節點就會擋第二個 pod——本階段接受，記錄在案
- **dify egress NetworkPolicy 可能誤擋模型調用**：設計上 plugin-daemon 直連外網（model 提供方）、api/worker 走 squid。若實測發現 api/worker 有沒走 squid 的必要外呼，policy 會把它擋掉 → 過關清單第 9 條就是要抓這個；真擋到就撤掉網絡層、只留應用層 SSRF（跟 compose 現狀一致），不影響遷移本身
- **relay 映像要先上 registry**：vikunja sync 依賴 `ghcr.io/jeromefromcn/vikunja-notify-relay` 已存在。順序上先跑 CI（或手動 push）再 sync
- **手動 Secret 是帶外狀態**：ArgoCD 不建也不修它，刪了就沒了（pod 起不來）。plan 每個服務 sync 前驗證 secret 存在；phase E 接 Sealed Secrets 前這是已知妥協
- **llm 配額打破 request==limit 慣例**：`requests 2C/4Gi, limits 5C/13Gi`。這是有意的（見「命名空間與配額」），未來加 llm 服務要記得 limits 超賣是設計的一部分
- **dify 大 image 拉取**：~8.5GB 一次性下載進 containerd；open-webui 單張 6.5GB。磁碟 89G 可用無虞，只是首次 sync 會慢。若在意可 `docker save` + `ctr images import` 預載
- **TZ**：全部設 `TZ=Asia/Hong_Kong`，但 image 沒有 tzdata 就無效（k8s README 的對照表）。遷完用 `date` 實測每個容器，與 compose 行為對齊即可，不額外追
- **webhook 重註冊**：vikunja DB 裡已註冊的 webhook URL（`http://vikunja-notify-relay:8080/`）因 Service 同名而沿用，不需重跑 `register-telegram-webhooks.sh`；但該腳本本身以後若重跑，`http://vikunja:3456` 的 API base 要改成 k8s Service 位址（plan 提一句）
- **NPM 切流瞬間短暫斷線**：改 location/forward 會斷既有連線。vikunja/dify 不是長連線敏感型（對比 3x-ui 的 VLESS），影響可忽略

## 3x-ui 去留決策（compose 保留）

- **決策：保留在 compose，不遷**。39876 是客戶端直連的 VLESS+Reality 原始 TCP，不走 HTTP 反代，且有過真實故障（2026-07-24 incident：淺層探測 + `ulimit`）。遷移的動作者要求零中斷，而任何 k8s 方案（擴 NodePort 範圍要重啟 k3s、hostNetwork 與 phase E 的 PSS/Kyverno 衝突）都要動到一個運作良好的線上端口——風險/收益不成比例
- 3x-ui 留在 docker `proxy` 網絡不影響其他遷移：NPM 的 `panel.3x`/`sub.3x`/`3xpanel` 轉發、靜態 IP/DNS hosts 覆寫全部原樣
- **附錄（未來若想遷的候選機制）**：Klipper LB（k3s 內建 LoadBalancer）綁 `39876`，不需要重啟 k3s、pod 保持隔離——是最可能的路；要處理的是宿主機防火牆對 39876 的放行、以及把 xray 的 DNS hosts 覆寫從 docker 網絡（172.19.0.3）改成指向 NPM 的可達位址。本階段不實作

## 交棒給 phase E

Phase E（供應鏈安全）依賴本階段：**Sealed Secrets 接管 D 的手動 Secret**、**Kyverno/PSS 基線**要處理本階段留下的三個已知衝突（trilium 的無 `runAsUser`、3x-ui 若遷的 hostNetwork、dify 共享 storage 若改 hostPath 的例外）——D 階段盡量用對的抽象（PVC、NetworkPolicy、secretKeyRef），把需要開例外的面壓到最小。

本階段同時是 phase G（服務網格）的前置：dify 棧的 Service 命名與 NetworkPolicy 模型、llm 棧的大資源預算，都會是 G 階段「哪些服務進網格」的考量輸入。
