# vps_oracle/host-native/cc-window

Host-native 服務，非 docker compose 管理（跟 `vps_oracle/host-native/inspector/`、`vps_oracle/host-native/host-firewall/` 一樣是 `<host>/host-native/` 下直接跑在宿主機的 systemd 服務，見 repo 根 README「目錄結構」一節）。

## 這是什麼

[cc-window](https://github.com/pickjason/cc-windows)（npm 包名 `cc-window`）是第三方本地網頁版 Claude Code 多會話管理台：一屏監控全機所有 `claude` CLI 會話、網頁裡新建會話、操作每個會話的交互式終端。原始碼不 vendor 進這個 repo，只用 `npm install -g` 裝固定版本，這裡只管 systemd 常駐 + 部署設定。

## 為什麼不用 docker

它的核心機制決定了容器化會直接跟自己的設計打架，不只是「能不能包」的問題：

- 靠輪詢 `claude agents --json` 拿全機會話名冊，`claude` CLI 必須裝在同一個環境的 `PATH` 上並且已登入
- 會話狀態來自 `~/.claude/projects/**/*.jsonl`、`~/.claude/monitor/events.jsonl`（hooks 寫入）、`~/.claude/settings.json`，都在宿主機使用者 home 下
- 會話本身用 `node-pty` 起、橋接到專用 tmux socket（`ccwindow`）——如果要管住你在宿主機 shell 裡直接開的會話，就得跟宿主機共用同一個 tmux socket，等於放棄容器隔離

所以整套跑在宿主機原生環境裡：`node`/`npm`、`tmux`、已登入的 `claude` CLI 都已經在這台機器上（見下面「環境確認」）。

## 安全：無內建鑑權，必須鎖在 access list 後面

cc-window 自己在文件裡就寫明：**沒有內建鑑權 token，能連上該端口的任何進程都能控制你的會話**。因此：

- `CC_HOST` 沒有釘死在官方預設的 `127.0.0.1`，理由見下面「為什麼 `CC_HOST` 是 `172.19.0.1` 不是 `127.0.0.1`」——但同樣**只**監聽一個非公網可達的位址，不對外
- 對外只能透過 NPM 反代，且反代記錄的 Access List 選 **`self-only-and-auth`**（id 2，跟 `self-only` 放行同樣的來源 IP，額外要求過 Basic Auth——這個 repo 現有的四個「無內建鑑權的管理面板」都用這條），不是預設的 `self-only`
- 絕對不要把 `CC_HOST` 改成 `0.0.0.0` 或宿主機的公網介面（`10.0.0.95`）

### 為什麼 `CC_HOST` 是 `172.19.0.1` 不是 `127.0.0.1`

cc-window 跑在宿主機原生環境，`127.0.0.1` 是宿主機自己的 loopback；NPM 是跑在 `proxy` 這個 docker bridge 網路裡的容器，它的網路命名空間**沒有**宿主機的 loopback，連不到綁在 `127.0.0.1` 上的服務——跟 `vps_oracle/host-native/npm-nodeport-relay/README.md` 記錄的那次「容器連不到宿主機服務」是同一類問題。

`proxy` 網路是手動建立的 `external: true` 網路（`docker network create proxy`，見 `vps_oracle/compose/npm/docker-compose.yml`），網關固定是 `172.19.0.1`（`docker network inspect proxy` 查得到，綁在宿主機的 `br-99f461e27ed6` 介面上，是宿主機自己真實擁有的位址，不是哪個容器的 IP）。cc-window 直接綁這個位址：

- NPM 容器本身就在 `proxy` 網路裡，網關位址天生可達，不用額外加 relay
- 這個位址不是公網介面，Oracle 的公網流量到不了這裡，跟綁 `127.0.0.1` 的暴露面實質上等價，只是換了一個「僅內部可達」的地址而已
- 跟 `3x-ui`（`172.19.0.2`）、`npm`（`172.19.0.3`）用同一個手動建立、不會隨 compose 重建的網路，穩定性有先例

風險提示跟 npm README 裡 3x-ui/npm 那兩個釘死 IP 一樣：如果哪天 `proxy` 網路被刪掉重建，網關位址理論上可能變（一般不會，因為它是手動建的 `external` 網路，不會被任何單一 compose 的 `up`/`down` 影響），要留意。

## 環境確認（2026-08-24）

| 依賴 | 版本 | 說明 |
|---|---|---|
| Node.js | v20.20.2 | 滿足 `cc-window` 要求的 `>=20` |
| tmux | 3.4 | 支援本地終端交接、服務重啟會話不丟；沒有會降級成直連 `node-pty`（關服務即結束會話） |
| `claude` CLI | `/home/ubuntu/.local/bin/claude`，已登入 | `claude agents --json` 已驗證可跑 |
| npm 全域 prefix | `/usr` | `npm install -g` 需要 `sudo`，二進位落在 `/usr/bin/cc-window` |

「一鍵打開本地終端」交接功能靠 `osascript` + Terminal.app，僅 macOS；這台是 Linux VPS，該功能自動降級成複製 `tmux attach` 指令，其餘功能不受影響。

## 安裝

固定版本，不用 `npx`/`latest`，理由跟本 repo「鏡像版本鎖定」的約定一致——避免上游發新版時，systemd 重啟服務就悄悄換了行為。

```bash
sudo npm install -g cc-window@0.2.1
```

升級版本：改這份 README 的版本號 + 上面指令重跑一次，`sudo systemctl restart cc-window.service`，跑幾輪確認正常再收尾。

## 部署

unit 檔案裡 `ExecStart` 指向全域安裝的二進位路徑（`/usr/bin/cc-window`），不是這個 repo 裡的檔案，所以用複製、不是軟連結（改動只影響裝了哪個 npm 版本，不影響這份 unit 檔案本身的內容）：

```bash
sudo cp cc-window.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cc-window.service
```

## 驗證

```bash
systemctl status cc-window.service
curl -sS -o /dev/null -w '%{http_code}\n' http://172.19.0.1:4317/   # 期望 200，宿主機本機可直接測（172.19.0.1 是宿主機自己的 bridge 介面）
docker exec npm curl -sS -o /dev/null -w '%{http_code}\n' http://172.19.0.1:4317/   # 從 NPM 容器視角再測一次，確認反代那條路徑真的通
journalctl -u cc-window.service -n 50
```

## NPM 反代 + homepage

反代設定按 repo 根 README「給服務接入 NPM 反代」一節的標準欄位，Access List 選 `self-only-and-auth`（見上面「安全」一節，不是預設的 `self-only`）：

| 字段 | 值 |
|---|---|
| Domain Names | `cc-window.jerome.cloudns.asia` |
| Forward Hostname / IP | `172.19.0.1`（cc-window 綁定的 `proxy` 網路網關位址，見上面「為什麼 `CC_HOST` 是 `172.19.0.1`」；不是容器，不能填服務名靠 Docker DNS 解析） |
| Forward Port | `4317` |
| Access List | `self-only-and-auth` |

homepage 卡片見 `vps_oracle/compose/homepage/config/services.yaml`。
