# vps_oracle/inspector

Host-level巡檢腳本，非 docker compose 管理（跟 `vps_oracle/k3s/` 一樣是 `<host>/` 下的非 compose 子目錄，見 repo 根 README「目錄結構」一節）。設計背景、分級規則、自我保護規則見
[`docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md`](../../docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md)。

**通知語言**：Telegram 報告標題與內文一律英文（2026-08-16 用戶要求；repo 文件維持中文）。`tests/test-inspect.sh` 有對應斷言（標題、分節標頭、無 CJK 字元）。

## 現況（phase 1）

已實作：
- `checks/stray-vscode-sessions.sh` — 游離/卡死的 claude session、脫離連線的 server-main 樹
- `checks/vscode-server-versions.sh` — 堆積的 `.vscode-server/cli/servers/*` 版本目錄

尚未實作（見另一份 phase 2 計畫）：docker 層與 k3s 層的資源清理 checks。新增時只要在 `checks/` 加一個新的可執行腳本，`inspect.sh` 用 glob 自動發現，不用改這裡任何現有代碼。

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
./tests/test-inspect.sh   # 最後一段會真的打 apprise inspector-tg，Telegram 群組要收得到
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

## apprise target

`inspector-tg` 已於 2026-08-16 註冊完成（沿用 vikunja 既有 bot token，指向 Telegram 群組 "OCI System inspection"）。apprise 現在是 k3s NodePort（`http://localhost:30085`），不是 docker 容器，見 spec 文件「通知格式」節的更新說明。

## 上線紀律

1. `INSPECTOR_DRY_RUN=1` 先跑幾輪，核對報告跟實際狀態相符（尤其 `stray-vscode-sessions.sh` 不能把還在互動的 session 判定為游離）。
2. 正式模式上線後先觀察幾天的 Telegram 報告，確認沒有誤殺才算穩定——不是一上線就信任自動 kill。
