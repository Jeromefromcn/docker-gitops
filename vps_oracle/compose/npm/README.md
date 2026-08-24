# vps_oracle/compose/npm

## 安全架構：用 access list 把 NPM 反代的服務關進「內網」

大部分掛在 NPM 後面的服務（grafana、homepage、dify、trilium、vikunja、apprise、portainer，以及 NPM 自己的管理面板）**不是公開給任何人訪問的**，而是刻意用 NPM 的 Access List 把來源鎖在「伺服器自己」或「`proxy` 這個 docker 網路裡的 IP」——一般公網訪客連過去只會拿到 403。

**3x-ui 是唯一的例外**，故意不受 access list 限制，因為它就是進門用的鑰匙：3x-ui 自己的 xray 設定（`/app/bin/config.json` 裡的 `dns.hosts`）有一條 `"domain:jerome.cloudns.asia": "172.19.0.3"` 的覆寫規則——凡是透過 3x-ui 代理訪問任何 `*.jerome.cloudns.asia` 網域，xray **不走公網 DNS 解析**，而是直接在 `proxy` 這個 docker 網路內部把流量轉給 `172.19.0.3`（也就是 npm）。因為這段路徑完全不出宿主機、不會被 Docker 的 SNAT 改寫來源，nginx 看到的來源就是 **3x-ui 容器自己真正的 IP**——這正是 access list 放行 `172.19.0.2` 的原因。等於是「先連代理，才能訪問內網服務」的模式，把公網上的一台機器偽裝成一個只有連了代理才進得去的私有內網。

**這兩個 IP 都要釘死靜態值，缺一不可**：
- `3x-ui` 固定 `172.19.0.2`（對應 access list 放行的來源）
- `npm` 固定 `172.19.0.3`（對應 xray DNS 覆寫指到的目標）

兩邊都在各自 `docker-compose.yml` 的 `networks.proxy.ipv4_address` 寫死，不然 Docker 動態分配一旦重建容器就可能換掉 IP，這兩個服務只要有一個漂移，代理進來的流量就會被送錯地方或被 access list 擋下來（2026-08-06 發生過一次：npm 一度被單獨釘在 `172.19.0.2`，結果跟 xray 覆寫規則的 `172.19.0.3` 對不上，透過代理訪問任何服務都連不上，查了很久才發現是這兩個 IP 對調了）。

## 目前的 Access List（透過 NPM API 查證，2026-08-24）

| Access List | 放行規則 | 用在幾個 proxy host | 額外要求 |
|---|---|---|---|
| `self-only`（id 1） | `172.19.0.2/32`（3x-ui 在 `proxy` 網路的 IP）、`161.118.254.107`（伺服器目前的公網 IP） | 17 個 | 無 |
| `self-only-and-auth`（id 2） | 同上兩條 | 10 個 | 還要過 Basic Auth（帳號 `jerome`） |

`self-only-and-auth` 掛的 10 個 proxy host 都是**無內建鑑權的管理面板**：`npm`（NPM 自己的管理面板）、`grafana`、`portainer`、`cc-window`（host-native 的 Claude Code 多會話看板，2026-08-24 加入，見 [`vps_oracle/host-native/cc-window/README.md`](../../host-native/cc-window/README.md)）、`redisinsight`（統一 Redis 的管理界面，見 [`vps_oracle/compose/redis/README.md`](../../compose/redis/README.md)，2026-08-24 加入）、`jaeger`（mesh-observability 的分散式追蹤 UI，反代到 k3s NodePort 30114，2026-08-24 加入）等。規則：**凡無內建鑑權的服務，一律用 `self-only-and-auth`，不要用 `self-only`**（`self-only` 只擋「來源」，不擋「誰」——同一台機器上任何使用者/程序都能訪問）。

`161.118.254.107` 是伺服器目前的公網出口 IP（`curl https://ifconfig.me` 查得到），**不是固定不變的**——如果哪天 Oracle 換了這台機器的公網 IP，這兩條 access list 都要跟著更新，不然沒經過 3x-ui、直接從公網打進來的流量（例如 blackbox_exporter 自己的探測）會被擋在外面。

## 怎麼改 Access List

**UI**：登入 `npm.jerome.cloudns.asia`（要先過 access list，或直接用伺服器本機/SSH 隧道進去）→ Access Lists → 選 `self-only` 或 `self-only-and-auth` → 編輯 Clients。

**API**（伺服器本機執行，不用先過 access list，走內部 `proxy` 網路直連 npm 管理埠）：
```bash
source vps_oracle/compose/npm/.npm-automation.env
docker run --rm --network proxy curlimages/curl:latest sh -c "
TOKEN=\$(curl -sS -X POST http://npm:81/api/tokens -H 'Content-Type: application/json' -d '{\"identity\":\"$NPM_AUTOMATION_EMAIL\",\"secret\":\"$NPM_AUTOMATION_PASSWORD\"}' | sed -n 's/.*\"token\":\"\([^\"]*\)\".*/\1/p')
curl -sS 'http://npm:81/api/nginx/access-lists?expand=items,clients' -H \"Authorization: Bearer \$TOKEN\"
"
```
查完 access list 的 `id` 之後，改用 `PUT /api/nginx/access-lists/{id}` 帶完整的 `clients` 陣列（含要保留的舊規則 + 新規則）更新。

**改完 access list 一定要跑一次 `docker exec npm nginx -t`**：更新 access list 會連帶重新產生掛在它底下的所有 proxy host 配置，可能把下面那個 dify 的問題重新裝回去。

## API 建 Let's Encrypt 證書（2.15.1 schema，2026-08-24 踩過）

用 API 建 proxy host 前需要先有證書。NPM 2.15.1 的 `POST /api/nginx/certificates` **不接受**舊文件（repo 根 README 的 SSL 標籤頁）寫的 `email` 頂層欄位、也不接受 `meta.letsencrypt_agree` / `meta.letsencrypt_email`——那些是舊版欄位，新版 schema 會回 `400 data/meta must NOT have additional properties`。

**可用 body**（`meta` 只需 `dns_challenge`；`letsencrypt_email`/`agree` 新版會自己填預設值）：
```bash
curl -sS -X POST 'http://npm:81/api/nginx/certificates' -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"provider":"letsencrypt","domain_names":["<domain>"],"meta":{"dns_challenge":false}}'
```
建完拿到 `certificate_id`，再建 proxy host（`forward_host` 填容器名、`forward_port` 填容器內埠、`access_list_id` 填對應 list 的 id）。

## 2026-08-21：升級到 2.15.1，以及一次 90 秒全站中斷

**升級原因**：面板首頁的 Proxy Hosts 只顯示 16，實際有 24。2.12.3 的 `report.js` 把 `permission_visibility` 寫成 `visibility`，取到的永遠是 `undefined`，計數於是永遠退回「只算當前登入使用者擁有的 host」——用自動化帳號（`claude`）建的那 8 個全部沒算進去。列表頁一直是對的，只有首頁那個數字不準。上游在 **2.14.0** 修好。順帶拿到 2.15.0 的一個安全修復：任何已認證使用者可透過 `PUT` 改自己的 `roles` 欄位——正好打在 `.npm-automation.env` 裡那個本該最小權限的 `claude` 帳號上。

**中斷經過**：`docker compose up -d` 重建容器後，nginx 反覆啟動失敗：

```
nginx: [emerg] host not found in upstream "dify-api" in /data/nginx/proxy_host/24.conf:74
```

443 上約 90 秒完全沒有程序監聽——不是某個站 502，是全部站點連不上。處理：把 `24.conf` 改名成 `24.conf.disabled-2026-08-21`，s6 的重試迴圈下一輪就起來了。

**這跟升級無關**。proxy host 24（dify）有 8 條 Custom Location 指向 `dify-api:5001` / `dify-plugin-daemon:5002`，而 dify 全套容器 45 小時前就停了。字面量上游必須在載入配置時解析（機制見 repo 根 README 的「能不用 Custom Locations 就不用」一節），所以回滾到 2.12.3、或單純 `docker restart npm`、或宿主機重啟，結果完全一樣。之前四天沒事，只是因為那個 nginx 行程是在 dify 還活著的時候起來的。

**升級本身驗證過的項目**：兩條 DB migration（`redirect_auto_scheme`、`trust_forwarded_proto`）正常套用；24 張憑證 `certbot renew --dry-run` 全部成功（全是 HTTP-01，沒用任何 DNS plugin，所以 2.15.0 那條 certbot 5.6 的 DNS plugin 警告不適用）；上面那套 API 流程的掛載路徑沒變。

### 遺留狀態：dify 的反代

目前 **DB 裡 host 24 仍是 enabled，磁碟上卻沒有它的 conf**，兩邊不一致。這個狀態下 npm 重啟是安全的。

會把 `24.conf` 寫回去、也就是把雷重新裝上的只有這三件事，**全都需要人手動操作，不會自己發生**——自動續期只跑 `certbot renew` 然後更新資料庫的到期時間，不重新產生任何 host 配置：

| 觸發動作 | 影響範圍 |
|---|---|
| 編輯 `self-only` access list（例如公網 IP 變了要更新放行規則） | 重寫掛在它底下的 15 個 host 配置，含 24 |
| 在面板裡編輯或 enable host 24 | 重寫 24 |
| 重新**申請**（不是續期）dify 的憑證 | 重寫用到該域名的 host |

要根治就兩條路：把 dify 啟回來（`dify-api` 能解析了，雷自然消失），或在面板裡把 host 24 disable。在那之前，做完上表任一動作都順手 `docker exec npm nginx -t` 確認一次；`vps_oracle/host-native/inspector/checks/npm-nginx-config.sh` 也會在 12 小時內抓到。

### 一個已知的日誌噪音

每個請求會寫一行 `[warn] using uninitialized "trust_forwarded_proto" variable`。磁碟上的 host 配置還是 2.12.3 產生的，缺 2.14.0 新增的 `set $trust_forwarded_proto "F";`；新映像的 `conf.d/include/force-ssl.conf` 自己帶兜底預設值，**行為跟升級前完全一致**，純粹是日誌噪音，而且有 logrotate 管著。它不會自己消失，要清掉得讓對應 host 的配置重新產生一次（見上表）——但那同時也會把 dify 的雷裝回去，兩件事是同一個開關。
