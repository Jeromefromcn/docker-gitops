# 排查記錄：compose 的 prometheus/grafana 連不到 k3s NodePort，預設閘道解析到錯的 docker network

日期:2026-08-24
狀態:根因已確認，修法已寫進 [Phase K 設計文檔](../superpowers/specs/2026-08-24-k3s-phase-k-observability-design.md)，尚未實作套用

## 背景

設計 [K3s Phase K（可觀測性接入）](../superpowers/specs/2026-08-24-k3s-phase-k-observability-design.md)時，確認 k3s pod 無法主動連出去打 docker compose 網路（見 [同日的另一篇排查記錄](2026-08-24-k3s-pod-to-docker-bridge-blackhole.md)）後，改採反方向設計：讓 compose 既有的 Prometheus/Grafana 主動連 k3s 的 NodePort 去拉指標/日誌/追蹤。這個方向理論上是這台機器上唯一已經在生產環境跑過的路徑（NPM 反代 headlamp/lab-environment grafana/argocd 走的就是這條路，見 [2026-08-19 NPM NodePort 事故記錄](2026-08-19-npm-to-k3s-nodeport-outage.md)），驗證時卻發現行不通。

## 排查過程

用一個已經確定存活、正常運作的 k3s NodePort（headlamp，`30098`）從 compose 的 `prometheus` 容器內部測試：

```bash
$ docker exec prometheus wget -T4 -qO- http://10.0.0.95:30098
wget: can't connect to remote host (10.0.0.95): No route to host
```

`No route to host` 在 Linux 網路裡通常對應到收到一個明確的拒絕（例如 ICMP host-prohibited），不是單純的封包消失——先懷疑是 `host-firewall.sh` 的 `INPUT` 鏈擋下。但 `host-firewall.sh` 早在 2026-08-19 就已經為「docker `proxy` 網路 → k3s NodePort 範圍」加過明確的放行規則：

```
ipt INPUT -s 172.19.0.0/16 -p tcp -m tcp --dport 30000:32767 -j ACCEPT
```

理論上應該通。查 `prometheus` 容器實際掛的網路：

```bash
$ docker inspect prometheus --format '{{json .NetworkSettings.Networks}}'
{
  "monitoring_default": {"Gateway": "172.20.0.1", "IPAddress": "172.20.0.2", "GwPriority": 0, ...},
  "proxy":              {"Gateway": "172.19.0.1", "IPAddress": "172.19.0.4", "GwPriority": 0, ...}
}
```

`prometheus` 容器同時掛了**兩張**網路：專案自己的 `monitoring_default`（`172.20.0.0/16`）和給固定 IP 用的 `proxy`（`172.19.0.0/16`，`host-firewall.sh` 那條放行規則綁定的正是這個網段）。兩張網路的 `GwPriority` 都是 `0`（平手，沒有明確指定優先權），實測 Docker 把 `monitoring_default` 解析成實際的預設閘道：

```bash
$ docker inspect prometheus --format '{{.NetworkSettings.Networks.monitoring_default.Gateway}}'
172.20.0.1
```

也就是說，`prometheus` 容器對外發起連線（含這次連 `10.0.0.95:30098`）走的是 `monitoring_default`（`172.20.0.0/16`），不是 `proxy`（`172.19.0.0/16`）——封包從錯的網路出去，來源位址不落在 `host-firewall.sh` 規則的 `172.19.0.0/16` 範圍內，被規則鏈末端預設的 `REJECT --reject-with icmp-host-prohibited` 擋下，對容器內的 `wget` 就表現成 `No route to host`。

對照組：查 NPM 容器（現有生產路徑，確定能通）的網路設定：

```bash
$ grep -A5 "networks:" vps_oracle/compose/npm/docker-compose.yml
    networks:
      proxy:
        ipv4_address: 172.19.0.3
```

NPM **只掛了 `proxy` 一張網路**，沒有多網路的歧義，預設閘道天然就是 `172.19.0.1`——這正是它能連 k3s NodePort 而 `prometheus`/`grafana`（兩者都跟 `prometheus` 一樣是 `default` + `proxy` 雙掛）目前不能連的差異所在。

## 根因

`vps_oracle/compose/monitoring/docker-compose.yml` 的 `prometheus`、`grafana` 兩個 service 都同時掛了自己專案的 `default` 網路和共用的 `proxy` 網路（`proxy` 原本只是為了拿一個固定 IP，讓 NPM 之類的東西能反代進來，不是設計給它們主動對外連線用的）。Docker 在兩張網路 `GwPriority` 相同（都是預設值 `0`）時，選了 `default` 網路（`monitoring_default`）當實際預設閘道，而不是 `proxy`——這不是隨機的，但也沒有顯式配置保證一定選中 `proxy`，純粹是 Docker 內部的網路排序規則。過去沒人發現，是因為這兩個容器從來沒有主動對外連過 k3s NodePort（它們一直是被連的一方，或者只在 `default` 網路內部跟其他 compose 容器互連），這次是第一次嘗試，才第一次暴露這個歧義。

## 修法（已寫進 Phase K 設計，尚未套用）

`prometheus`、`grafana` 兩個 service 的 `networks.proxy` 加上明確的 `priority`（Compose Spec 支援的欄位，數字越大優先權越高），讓 `proxy` 網路確定成為預設閘道，蓋過 `default` 網路：

```yaml
services:
  prometheus:
    networks:
      default: {}
      proxy:
        ipv4_address: 172.19.0.4
        priority: 1
```

`grafana` 同樣處理。套用後用同一個 `docker exec prometheus wget ... 10.0.0.95:30098` 指令重測，回應非 timeout/no-route-to-host 即代表修復生效——這一步是 [Phase K 實作](../superpowers/specs/2026-08-24-k3s-phase-k-observability-design.md)的前置條件，不修這個，K 階段規劃的 compose scrape/query k3s NodePort 全部連不通。

## 教訓

- **compose 容器掛多張 docker network 時，不能假設「掛了某張網路」就等於「對外連線會走那張網路」**——實際預設閘道取決於 `GwPriority`（或沒設時的內部排序），需要用 `docker inspect --format '{{.NetworkSettings.Networks.<net>.Gateway}}'` 明確驗證，不能只看 `networks:` 區塊列了什麼
- **`host-firewall.sh` 的來源網段限制（`-s 172.19.0.0/16`）隱含一個前提**：呼叫者的封包真的會從那個網段出去。這個前提對單網路容器（像 NPM）天然成立，對多網路容器不成立，未來任何新的 compose service 想利用這條既有的「docker proxy net → k3s NodePort」路徑，都要先確認自己是不是也踩了同一個坑，不能只照抄 NPM 的防火牆規則邏輯就假設會通
- **`No route to host` 在容器情境下的常見成因是宿主機防火牆的顯式 REJECT，但這裡的根因其實更早一步——是容器自己選錯了出口網路**，防火牆規則本身完全正確；排查這類錯誤時，先確認封包實際從哪張網路出去，比直接懷疑防火牆規則寫錯更快定位問題
