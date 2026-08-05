# vps_oracle/compose/npm

## 安全架構：用 access list 把 NPM 反代的服務關進「內網」

大部分掛在 NPM 後面的服務（grafana、homepage、dify、trilium、vikunja、apprise、portainer，以及 NPM 自己的管理面板）**不是公開給任何人訪問的**，而是刻意用 NPM 的 Access List 把來源鎖在「伺服器自己」或「`proxy` 這個 docker 網路裡的 IP」——一般公網訪客連過去只會拿到 403。

**3x-ui 是唯一的例外**，故意不受 access list 限制，因為它就是進門用的鑰匙：3x-ui 自己的 xray 設定（`/app/bin/config.json` 裡的 `dns.hosts`）有一條 `"domain:jerome.cloudns.asia": "172.19.0.3"` 的覆寫規則——凡是透過 3x-ui 代理訪問任何 `*.jerome.cloudns.asia` 網域，xray **不走公網 DNS 解析**，而是直接在 `proxy` 這個 docker 網路內部把流量轉給 `172.19.0.3`（也就是 npm）。因為這段路徑完全不出宿主機、不會被 Docker 的 SNAT 改寫來源，nginx 看到的來源就是 **3x-ui 容器自己真正的 IP**——這正是 access list 放行 `172.19.0.2` 的原因。等於是「先連代理，才能訪問內網服務」的模式，把公網上的一台機器偽裝成一個只有連了代理才進得去的私有內網。

**這兩個 IP 都要釘死靜態值，缺一不可**：
- `3x-ui` 固定 `172.19.0.2`（對應 access list 放行的來源）
- `npm` 固定 `172.19.0.3`（對應 xray DNS 覆寫指到的目標）

兩邊都在各自 `docker-compose.yml` 的 `networks.proxy.ipv4_address` 寫死，不然 Docker 動態分配一旦重建容器就可能換掉 IP，這兩個服務只要有一個漂移，代理進來的流量就會被送錯地方或被 access list 擋下來（2026-08-06 發生過一次：npm 一度被單獨釘在 `172.19.0.2`，結果跟 xray 覆寫規則的 `172.19.0.3` 對不上，透過代理訪問任何服務都連不上，查了很久才發現是這兩個 IP 對調了）。

## 目前的 Access List（透過 NPM API 查證，2026-08-06）

| Access List | 放行規則 | 用在幾個 proxy host | 額外要求 |
|---|---|---|---|
| `self-only`（id 1） | `172.19.0.2/32`（3x-ui 在 `proxy` 網路的 IP）、`161.118.254.107`（伺服器目前的公網 IP） | 13 個 | 無 |
| `self-only-and-auth`（id 2） | 同上兩條 | 4 個 | 還要過 Basic Auth（帳號 `jerome`） |

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
