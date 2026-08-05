# vps_oracle/compose/npm

## 安全架構：用 access list 把 NPM 反代的服務關進「內網」

大部分掛在 NPM 後面的服務（grafana、homepage、dify、trilium、vikunja、apprise、portainer，以及 NPM 自己的管理面板）**不是公開給任何人訪問的**，而是刻意用 NPM 的 Access List 把來源鎖在「伺服器自己」或「`proxy` 這個 docker 網路裡的 IP」——一般公網訪客連過去只會拿到 403。

**3x-ui 是唯一的例外**，故意不受 access list 限制，因為它就是進門用的鑰匙：先透過 3x-ui 的 VLESS/Reality 代理連上，流量經過伺服器解密、再打回 `*.jerome.cloudns.asia` 時，來源看起來就是伺服器自己（符合 access list 的放行條件），這樣才進得去被鎖住的那些服務。等於是「先連代理，才能訪問內網服務」的模式，把公網上的一台機器偽裝成一個只有連了代理才進得去的私有內網。

## 目前的 Access List（透過 NPM API 查證，2026-08-06）

| Access List | 放行規則 | 用在幾個 proxy host | 額外要求 |
|---|---|---|---|
| `self-only`（id 1） | `172.19.0.2/32`（npm 自己在 `proxy` 網路的 IP）、`161.118.254.107`（伺服器目前的公網 IP） | 13 個 | 無 |
| `self-only-and-auth`（id 2） | 同上兩條 | 4 個 | 還要過 Basic Auth（帳號 `jerome`） |

`161.118.254.107` 是伺服器目前的公網出口 IP（`curl https://ifconfig.me` 查得到），**不是固定不變的**——如果哪天 Oracle 換了這台機器的公網 IP，這兩條 access list 都要跟著更新，不然連代理進來的流量也會被擋在外面。

## 已知問題（待排查，2026-08-06 發現，尚未解決）

透過 3x-ui 代理訪問 `*.jerome.cloudns.asia` 時遇到 `ERR_CONNECTION_CLOSED`，不是預期的行為（照設計應該要能連通）。研判跟 hairpin NAT 有關：流量從 3x-ui（在這台伺服器上）要打回同一台伺服器的公網域名，這種「繞一圈打回自己」的路由在 Oracle Cloud 環境有時候會被卡住。從伺服器本機直接 `curl https://npm.jerome.cloudns.asia/` 是通的（乾淨的 200），代表 nginx／access list 本身沒問題，問題出在代理那條路徑的路由。之後排查可以從這個方向下手。

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
