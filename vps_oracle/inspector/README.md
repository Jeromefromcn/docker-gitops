# vps_oracle/inspector

Host-level巡檢腳本，非 docker compose 管理（跟 `vps_oracle/k3s/` 一樣是 `<host>/` 下的非 compose 子目錄，見 repo 根 README「目錄結構」一節）。設計背景、分級規則、自我保護規則見
[`docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md`](../../docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md)。

**通知語言**：Telegram 報告標題與內文一律英文（2026-08-16 用戶要求；repo 文件維持中文）。`tests/test-inspect.sh` 有對應斷言（標題、分節標頭、無 CJK 字元）。

## 現況（phase 2）

已實作（phase 1）：
- `checks/stray-vscode-sessions.sh` — 游離/卡死的 claude session、脫離連線的 server-main 樹
- `checks/vscode-server-versions.sh` — 堆積的 `.vscode-server/cli/servers/*` 版本目錄

已實作（phase 2，docker 層）：
- `checks/docker-stopped-containers.sh`（auto）— exited 超過 7 天的容器
- `checks/docker-dangling-images.sh`（auto）— dangling 超過 7 天的 image
- `checks/docker-build-cache.sh`（auto）— 超過 7 天的 build cache
- `checks/docker-unused-networks.sh`（auto）— 無容器掛載的自訂 network
- `checks/docker-restart-storms.sh`（alert）— RestartCount 異常高 / 持續 Restarting
- `checks/docker-unused-volumes.sh`（alert）— 無容器掛載的 volume（匿名聚合成一行，具名逐行）
- `checks/docker-compose-logging-drift.sh`（alert）— compose 服務缺 `logging.options.max-size`
- `checks/docker-oversized-logs.sh`（alert）— 單檔超過 50MiB 的 `*-json.log`

已實作（phase 2，k3s 層）：
- `checks/k3s-evicted-pods.sh`（auto）— Failed 殘留 pod
- `checks/k3s-completed-jobs.sh`（auto）— 完成超過 3 天的 Job
- `checks/k3s-containerd-images.sh`（auto）— 無容器引用的 containerd image（`sudo crictl`）
- `checks/k3s-released-pvs.sh`（alert）— Released PV
- `checks/k3s-stuck-terminating.sh`（alert）— 卡超過 15 分鐘的 Terminating pod
- `checks/k3s-oom-killed-containers.sh`（alert）— `lastState.terminated.reason=OOMKilled` 且發生在 24 小時內；`k3s-evicted-pods.sh` 抓不到這種情況（pod 全程停留 `Running`，只是 container 被殺重啟），2026-08-17 io_pressure_critical 事件（jaeger/trivy 都因 limit 太緊被 OOM Kill）之後補上

閾值都是各腳本開頭的 env var，可從 systemd unit 的 `Environment=` 或手動執行時覆寫。

**範圍邊界**：`vscode-server-versions.sh` 只清 `cli/servers/<version>/` 這種大目錄（單個 500-650M 級別），不動 `~/.vscode-server/code-<commit>` 這類小得多的 CLI tunnel binary（~27M/個）——spec 沒把它們列進范围，之后想扩再加新 check。

## 執行

```bash
cd vps_oracle/inspector
./inspect.sh                    # 正式跑一次，會發 Telegram
INSPECTOR_DRY_RUN=1 ./inspect.sh  # 只印 would-kill/would-delete，不動手
```

## 測試

```bash
cd vps_oracle/inspector
./tests/test-common.sh
./tests/test-stray-vscode-sessions.sh
./tests/test-vscode-server-versions.sh
./tests/test-inspect.sh        # 最後一段會真的打 apprise inspector-tg，Telegram 群組要收得到
./tests/test-docker-stopped-containers.sh
./tests/test-docker-dangling-images.sh
./tests/test-docker-build-cache.sh
./tests/test-docker-unused-networks.sh
./tests/test-docker-restart-storms.sh
./tests/test-docker-unused-volumes.sh
./tests/test-docker-compose-logging-drift.sh
./tests/test-docker-oversized-logs.sh
./tests/test-k3s-evicted-pods.sh
./tests/test-k3s-completed-jobs.sh
./tests/test-k3s-containerd-images.sh
./tests/test-k3s-alerts.sh
./tests/test-k3s-oom-killed-containers.sh
```

`tests/test-common.sh` 是全案最重要的一份測試——它驗證的是「絕不誤殺自己」這條規則本身，不能只靠人工看一遍代碼，見 spec 的「自我保護規則」一節。

## 部署

```bash
sudo ln -sf $(pwd)/systemd/docker-gitops-inspector.service /etc/systemd/system/
sudo ln -sf $(pwd)/systemd/docker-gitops-inspector.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now docker-gitops-inspector.timer
```

用 symlink 不是複製——改代碼、`git pull`/`git commit` 完就是生效狀態，不用另外跑 install.sh（見 claude-code-notify 的教訓：獨立 install 步驟容易忘記跑）。改動 unit 檔案結構本身（不是 `inspect.sh` 內容）時才需要重新 `daemon-reload`。

手動觸發一次：`sudo systemctl start docker-gitops-inspector.service`；看結果：`sudo systemctl status docker-gitops-inspector.service` / `journalctl -u docker-gitops-inspector.service -n 50`。

## k3s 存取（phase 2 一次性設置）

k3s checks 不用 admin kubeconfig，用最小權限 SA（`workloads/docker-gitops-inspector`：pods/jobs get+list+delete、PV get+list，其余一律拒絕）：

```bash
cd vps_oracle/inspector
./k3s/setup-kubeconfig.sh     # apply RBAC + 寫 state/kubeconfig（gitignored，600）
```

腳本冪等，重跑安全。RBAC manifest 在 `k3s/rbac.yaml`——不在 `vps_oracle/k3s/manifests/`（那是 ArgoCD 地盤，見 k3s/README）。

兩個 check 用到密碼免輸入的 `sudo -n`（都是唯讀列舉或單一清理指令）：`docker-oversized-logs.sh`（讀 `/var/lib/docker/containers`）、`k3s-containerd-images.sh`（`crictl` socket 是 root-only）。若日後收回 NOPASSWD，這兩個 check 會在報告裡發 alert 說明被跳過，不會掛住。

## apprise target

`inspector-tg` 已於 2026-08-16 註冊完成（沿用 vikunja 既有 bot token，指向 Telegram 群組 "OCI System inspection"）。apprise 已於 2026-08-18 遷回 docker compose（`vps_oracle/compose/apprise`），只在 `proxy` 網路內用容器名給其他容器訪問；inspector 是 host-native 腳本、不在任何 docker network 裡，因此 apprise compose 額外綁了 `127.0.0.1:8000:8000` 給它用，`APPRISE_URL` 預設值也改成 `http://localhost:8000`（見 `lib/common.sh`）。

## 上線紀律

1. `INSPECTOR_DRY_RUN=1` 先跑幾輪，核對報告跟實際狀態相符（尤其 `stray-vscode-sessions.sh` 不能把還在互動的 session 判定為游離）。
2. 正式模式上線後先觀察幾天的 Telegram 報告，確認沒有誤殺才算穩定——不是一上線就信任自動 kill。
