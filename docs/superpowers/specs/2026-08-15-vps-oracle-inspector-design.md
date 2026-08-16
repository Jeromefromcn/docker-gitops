# vps_oracle 巡檢腳本設計

日期：2026-08-15

## 背景

兩份事故文檔記錄了同一條因果鏈的上下游：

- [2026-08-15-ccr-vscode-extension-stall.md](../../incidents/2026-08-15-ccr-vscode-extension-stall.md)：VS Code 擴展 + ccr 第三方 provider 組合下，逐 token SSE 事件導致 CLI 卡在 stdout 寫入、session 不退出（觸發器，已由 sse-coalesce 中間件修復）。
- [2026-08-15-vscode-sessions-resource-spike.md](../../incidents/2026-08-15-vscode-sessions-resource-spike.md)：卡死的 session 拖著整棵 exthost 樹不死，用戶重開窗口重試又疊加新樹，加上 Remote-SSH server 脫離會話後永久存活、多個 server 版本目錄堆積，20 小時內漸進吃光記憶體，最終在多窗口同時重連時引發 IO 風暴、負載衝到 38.7。已用手動殺進程 + 加 4G swap + 清理 server 版本目錄解決，並在 `host-metrics-rules.yml` 補了 PSI/swap/D-state/記憶體趨勢共 7 條 Grafana 告警規則。

這些告警規則能看到"資源在惡化"，但看不到"是哪個具體進程/容器/session 在佔用、能不能動手清"——這正是本設計要補的那一塊：一個會**定期跑、能識別具體目標、按規則自動清理或告警**的巡檢機制。

## 目標與範圍

- 偵測並（按規則分級）清理宿主機上的游離 VS Code 會話樹、脫離連線的 Remote-SSH server 樹、堆積的 server 版本目錄。
- 偵測並清理 docker 層與 k3s 層的磁碟佔用類游離資源（停止容器、dangling image、build cache、未用 network/volume、Evicted pod、堆積的 Completed Job、containerd 未用 image、Released PV）。
- 每次執行結束都發一則 Telegram 報告（透過既有的 `apprise` 容器），不管有沒有異常，讓"巡檢有沒有在跑"本身可觀察。
- 可擴充：以後新增巡檢項目是加一個新的 check 腳本，不用改主流程。

**非目標**：不重複 Prometheus/Grafana 已覆蓋的聚合指標類告警（CPU/記憶體/磁碟用量、PSI、swap 存亡、記憶體趨勢預測）；不做"自動改 compose/k8s 配置檔案"這類配置變更，只做資源清理與告警。

## 架構：宿主機腳本，不進 docker

**為什麼不做成容器**（詳細討論見對話記錄，此處記結論）：

1. **權限模型**：清理宿主進程（VS Code exthost/claude/codex 會話樹）需要宿主 PID 可見性與 kill 權限。容器化的唯一做法是 `pid: host`，疊加操作 docker 資源所需的 `docker.sock` 掛載，會成為這個 fleet 裡權限最大的容器——比 README 已標記為"已知高風險例外"的 portainer（僅 `docker.sock`）還大一層。`pid: host` 下容器內 root 等同宿主 root，這層容器化並未換來真正的隔離收益。
2. **維護成本**：容器化不會省掉宿主層的排程配置——容器內建 cron 需額外依賴，不建的話還是得靠宿主 cron/systemd 去觸發 `docker compose run`，宿主這一步一步都沒省下來。同時多了 Dockerfile/鏡像維護、以及"改腳本忘記 `--build`"這個 vikunja-notify-relay 已經踩過的坑。
3. **倉庫既有慣例**：`CLAUDE.md` 明確允許 `<host>/` 下存在非 compose 的基礎設施目錄（`k3s/` 是先例），宿主巡檢腳本正好落在這個慣例裡。

**目錄結構**（`vps_oracle/inspector/`）：

```
vps_oracle/inspector/
├── inspect.sh              # 主入口：依序執行 checks/ 下所有腳本，彙總結果，發 Telegram
├── checks/                 # 每個檢查項一個獨立可執行腳本
│   ├── stray-vscode-sessions.sh
│   ├── vscode-server-versions.sh
│   ├── docker-stopped-containers.sh
│   ├── docker-dangling-images.sh
│   ├── docker-build-cache.sh
│   ├── docker-unused-networks.sh
│   ├── docker-restart-storms.sh
│   ├── docker-unused-volumes.sh
│   ├── docker-compose-logging-drift.sh
│   ├── docker-oversized-logs.sh
│   ├── k3s-evicted-pods.sh
│   ├── k3s-completed-jobs.sh
│   ├── k3s-containerd-images.sh
│   ├── k3s-released-pvs.sh
│   └── k3s-stuck-terminating.sh
├── lib/
│   └── common.sh            # 共用函式：自身進程鏈計算、PID 身份核對、二段式 kill（TERM→等待→KILL）、發送 apprise
├── systemd/
│   ├── docker-gitops-inspector.service
│   └── docker-gitops-inspector.timer
├── state/                   # gitignore，執行時狀態（去重/上次結果比對用）
└── README.md
```

**擴充機制**：新 check = 在 `checks/` 丟一個新腳本，`inspect.sh` 用 glob 自動發現並執行，不用改主邏輯。每個 check 腳本是獨立可執行檔，輸出約定格式的結構化結果（每行一個 JSON：`{"tier":"auto"|"alert","action":"killed"|"would-kill"|"flagged","target":"...","detail":"..."}`），`inspect.sh` 收集所有輸出彙總成一則 Telegram 訊息。

## Check 清單與分級規則

分級邏輯：規則能明確判定、風險可控、可逆或可重建的 → **自動處理**；判定條件本身有模糊地帶、或誤判代價不對稱地高（如刪掉還有用的資料）→ **只告警**，交人工判斷。閾值先給預設值，都做成腳本開頭的變數，之後依實際巡檢報告觀察再調。

### 自動處理

| Check | 判定條件 | 動作 | 對應事故 |
|---|---|---|---|
| 游離 VS Code session 樹 | session transcript 最後一行是完整的 `result`（已正常結束）且進程仍存活超過閾值（預設 30 分鐘） | TERM 整棵子樹，等 4 秒後對倖存者補 KILL | 直接對應：卡死 bug 導致 session 不退出，這是兜底——即使以後換個原因卡死，也不會再無聲堆積 20 小時才被發現 |
| 脫離連線的 server-main 樹 | ppid=1（已脫離終端）且底下無任何活躍 exthost 超過閾值（預設 2 小時無 CPU 活動） | 同上 | 直接對應：Remote-SSH server 脫離會話後永久存活 |
| VS Code server 版本目錄堆積 | 非 `lru.json` 最近使用版本、無進程引用、保留數已超過 N（預設留 2 個） | 刪除目錄 | 直接對應：6 個版本目錄/3.8G 的手動清理動作 |
| Docker 已停止容器 | `status=exited` 且退出超過 N 天（預設 7 天） | `docker rm` | 擴充 |
| Docker dangling image | 產生超過 N 天（預設 7 天） | `docker image prune` | 擴充 |
| Docker build cache | 候選超過 N 天（預設 7 天） | `docker builder prune` | 擴充，磁碟佔用類 |
| Docker 未用 network | 無容器掛載的自訂 network | `docker network prune` | 擴充，重建成本近乎零 |
| k3s Evicted/Failed pod | `status.phase=Failed` 的殘留 pod | `kubectl delete pod` | 擴充，k8s 公認標準衛生操作 |
| k3s Completed Job 堆積 | 超過 N 個或超過 N 天的已完成 Job | `kubectl delete job` | 擴充 |
| k3s containerd 未用 image | 對應 `docker image prune` 的 containerd 版 | `crictl rmi --prune` | 擴充 |

### 只告警

| Check | 判定條件 | 報告內容 | 原因 |
|---|---|---|---|
| 疑似卡死的 session | transcript 無 `result`（可能仍在執行）但進程存活超過異常長時間（預設 6 小時） | PID、cwd、session id、存活時長 | 無法區分"長任務"與"卡死"，早期預警——對應事故裡"積累期 20 小時無人察覺"想解決的問題 |
| Docker 重啟風暴 | RestartCount 異常高或持續 `Restarting` | 容器名、重啟次數 | 自動重啟不解決根因，可能掩蓋配置錯誤 |
| Docker 未用 volume | 存在但未被任何容器掛載 | volume 名 | 可能有資料，誤刪風險不對稱（容器/image 可重建，volume 數據不一定能） |
| compose 檔 logging 配置漂移 | 掃描 `<host>/compose/*/docker-compose.yml`，找出沒有 `logging.options.max-size` 的服務 | 檔案路徑、服務名 | 這是"發現配置漏洞"，不該由巡檢腳本自己改 compose 檔案 |
| 容器日誌檔異常大 | `/var/lib/docker/containers/*/*-json.log` 實際大小異常 | 容器名、檔案大小 | 可能是 logging 設定沒生效，需人工排查 |
| k3s Released PV | 不再綁定但仍佔磁碟 | PV 名 | 可能有資料，道理同 docker volume |
| k3s 卡住的 Terminating pod | 超過閾值仍卡在 Terminating | pod 名、命名空間 | 通常代表 finalizer/node 問題，需人工判斷是否強制刪除 |
| 任何命中「自身進程鏈」的目標 | 見下方自我保護規則 | `skipped: self-chain overlap` | 絕不動手 |

## 自我保護規則

直接對應事故文檔裡踩過的坑，寫進 `lib/common.sh`：

1. 執行前先算出自身進程鏈（腳本 PID + 父鏈 + systemd cgroup），任何 grep/ps 比對都要排除這條鏈——事故文檔踩過「`ps -eo args | grep` 把自己的命令行搜進去」的自匹配 bug。
2. kill 前重新核對目標 PID 的身份（cmdline + start time），防 PID 複用誤殺。
3. 二段式：TERM 先，等待後對倖存者才 KILL，不一開始就 `-9`。
4. kill 樹前校驗「待殺清單」與「自身進程鏈」無交集，有交集就整組中止並標記為異常（而非只跳過那一項）。

這幾個函式是全案裡最不能出錯的部分——錯了可能巡檢腳本殺死自己所在的會話，需要有最小驗證腳本，不能只靠人工過一遍（見下方測試方式）。

## 通知格式

透過既有的 `apprise` 服務（`http://localhost:30085/notify/inspector-tg`），HTML 格式，沿用 vikunja-notify-relay 已有模式。**注意**：apprise 已於 phase D 遷入 k3s（`workloads` namespace，NodePort `30085`），不再是 docker `proxy` 網路上的容器，因此走宿主機本機的 NodePort，而不是容器名 DNS。新增一個 apprise target `inspector-tg`，指向 Telegram 群組 "OCI System inspection"（bot token / chat id 不進 git，只作為 apprise store 裡的執行時資料，用法與現有 `vikunja-tg-<username>` target 一致；已於 2026-08-16 註冊並測試通過，沿用同一個 bot token）。

**通知語言一律英文**（2026-08-16 上線時用戶要求；repo 文件維持中文）。分節標頭、空報告、標題都固定英文，check 腳本產生的 `detail` 文本也一律英文；`tests/test-inspect.sh` 有「payload 無 CJK 字元」的自動斷言鎖死這條規則。

範例（與 `inspect.sh` 實際輸出格式一致）：

```
🔍 Inspection report vps_oracle · 2026-08-16 09:00

Auto-handled
✅ killed: claude PID 3177808
   session <id> (cwd=/home/ubuntu/jerome/foo) finished 2880s ago, still alive past 1800s threshold
✅ deleted: Stable-df53daabb18cd157bdb08c7f01c34df936cf12f4
   not in top 2 lru.json entries, no active process, size=656M

Needs manual review
⚠️ claude PID 5521
   session <id> (cwd=/home/ubuntu/jerome/foo) alive 25920s with no transcript result yet -- may be a long task or stuck

Run took 4.2s
```

若完全沒異常，只發「✅ All clear — nothing needed attention」一行——確保巡檢本身有沒有在跑是可觀察的。

## 部署

- systemd service 以 `ubuntu` 用戶身份執行（不用 root）——kill 的目標進程本來就是 `ubuntu` 身份跑的；docker 操作靠 `ubuntu` 在 `docker` group；k3s 操作靠一份唯讀 kubeconfig 複本。若之後發現某個操作確實需要 root，單獨用 `sudo` 包那一小段，不整個 service 提權。
- `ExecStart` 直接指向 repo checkout 內的 `inspect.sh` 路徑，不另外 `install.sh` 同步一份——改代碼、`git pull`/`git commit` 完就是生效狀態，避開 claude-code-notify"忘記跑 install.sh"的坑。首次安裝或改動 unit 檔案結構時才需要手動 `systemctl daemon-reload`。
- timer：`OnCalendar=09:00,21:00`，`Persistent=true`（機器重啟不錯過）。
- 手動觸發：`systemctl start docker-gitops-inspector.service`。
- apprise target 註冊（照抄 vikunja 既有模式，token/chat id 不落盤，只作為指令參數傳入一次；因 apprise 現況是 k3s NodePort 而非 docker `proxy` 網路容器，故直接對宿主機本機的 NodePort 發送，不需要 `docker run --network proxy` 包一層）：
  ```bash
  curl -s -X POST \
    --data-urlencode "urls=tgram://<bot_token>/<chat_id>/" \
    http://localhost:30085/add/inspector-tg
  ```
  已於 2026-08-16 執行：bot token 沿用既有 vikunja bot（從 apprise PVC 裡已持久化的 `vikunja-tg-jerome.cfg` 讀出），chat id 透過該 bot 的 Telegram `getUpdates` API 查得（群組 "OCI System inspection" 已把 bot 拉進去）。`inspector-tg` target 已建立並發送測試訊息驗證通過。

## 測試方式

1. `INSPECTOR_DRY_RUN=1` 模式——自動 tier 只印「would kill/would delete」不真的動手，先跑幾輪核對報告跟實際狀態相符。
2. 為 `lib/common.sh` 的自我保護函式（自身進程鏈計算、PID 身份核對）寫最小驗證腳本，確保這段邏輯本身沒有 bug。
3. dry-run 過後切正式模式，先觀察幾天的 Telegram 報告，確認沒有誤殺才算穩定，而非一上線就信任自動 kill。

## 未來可擴充（本版不做）

以下是討論中提到、但為了控制首版範圍而暫不列入的延伸方向，之後想加時作為新 check 腳本補上即可：磁碟熱點掃描（大檔案/大目錄）、zombie（Z 狀態）進程計數、`systemctl --failed` 掃描、NPM 反代 SSL 開關被靜默重置的偵測（README 已知坑）。
