# 排查記錄：compose 的 prometheus/grafana 連不到 k3s NodePort，預設閘道解析到錯的 docker network

日期:2026-08-24
狀態:已修復並套用（2026-08-24）。**最初寫進 [Phase K 設計文檔](../superpowers/specs/2026-08-24-k3s-phase-k-observability-design.md)的修法（`networks.<name>.priority`）實測在這台機器上無效**，實際採用的是把 compose 專案自己的 `default` 網路改成 `internal: true`，詳見下面「修法」

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

再補一組對照實驗把變因收斂到「來源 IP」這一項：同一個 `prometheus` 容器，只改目的地 IP，分別打兩張網橋在宿主機上的位址（NodePort 服務本來就聽 `0.0.0.0`，兩個位址都是合法目的地），但因為兩者都是 on-link（直連路由，不經預設閘道），封包的來源 IP 會分別落在各自的網段：

```bash
# 走 proxy 網橋（on-link，src=172.19.0.4，落在防火牆放行網段內）
$ docker exec prometheus wget -T4 -qO- http://172.19.0.1:30098
<!DOCTYPE html>          # 通

# 走 monitoring_default 網橋（on-link，src=172.20.0.5，不在放行網段內）
$ docker exec prometheus wget -T4 -qO- http://172.20.0.1:30098
wget: can't connect to remote host (172.20.0.1): No route to host
```

同一個容器、同一個 NodePort、只差來源 IP，結果一通一不通——證明路由/DNAT/Cilium 那一側全都是好的，唯一的變因就是封包從哪張網路出去（也就是預設閘道選了誰）。

## 根因

`vps_oracle/compose/monitoring/docker-compose.yml` 的 `prometheus`、`grafana` 兩個 service 都同時掛了自己專案的 `default` 網路和共用的 `proxy` 網路（`proxy` 原本只是為了拿一個固定 IP，讓 NPM 之類的東西能反代進來，不是設計給它們主動對外連線用的）。Docker 在兩張網路 `GwPriority` 相同（都是預設值 `0`）時，選了 `default` 網路（`monitoring_default`）當實際預設閘道，而不是 `proxy`——這不是隨機的，但也沒有顯式配置保證一定選中 `proxy`，純粹是 Docker 內部的網路排序規則。過去沒人發現，是因為這兩個容器從來沒有主動對外連過 k3s NodePort（它們一直是被連的一方，或者只在 `default` 網路內部跟其他 compose 容器互連），這次是第一次嘗試，才第一次暴露這個歧義。

## 修法

### 死路一條：`networks.<name>.priority`（原本寫進 Phase K 設計的那個修法）

Compose Spec 有 `networks.<name>.priority` 欄位（數字越大越優先），對應 engine 的 `GwPriority`，看起來就是為這個場景設計的。**在這台機器上實測完全無效**：

| 測的版本（`docker-compose-plugin` 套件版本 / CLI 回報） | `docker compose config` | `up -d` 後的 `GwPriority` | NodePort 測試 |
|---|---|---|---|
| `5.1.1-1~ubuntu.24.04~noble` / `v5.1.4`（本來裝的） | 解析、驗證都正常 | 仍是 `0` | 照樣 `No route to host` |
| `5.1.4-1~ubuntu.24.04~noble` / `v5.1.4`（純打包版本號變動） | 同上 | 仍是 `0` | 同上 |
| `5.5.0-1~ubuntu.24.04~noble` / `v5.5.0`（apt 能拿到的最新） | 同上 | 仍是 `0`（`--force-recreate` 強制重建也一樣） | 同上 |

同時確認 **engine 那一側的原語是好的**——拿一個丟棄式容器測：

```bash
$ docker network connect --gw-priority 1 <net> <throwaway>
$ docker inspect <throwaway> --format '{{...GwPriority}}'   # → 1，正確生效
```

結論：不是版本落後、不是 YAML 寫錯，是 **compose 沒有把這個欄位轉發給 engine 的 `NetworkConnect`/`ContainerCreate`**。這條路在這台機器上升級 compose 也繞不過去，別再試。（`docker-compose-plugin` 現在停在 `5.5.0`，是這次排查升上去就沒再退回。）

### 實際採用：把 compose 專案自己的 `default` 網路改成 `internal: true`

既然沒辦法「把 `proxy` 的優先權抬上去」，就反過來「把 `default` 從選舉裡拿掉」。**internal 網路根本不會被分配閘道，也就不參與預設路由選舉**——`proxy` 於是自動成為 `prometheus`/`grafana` 唯一的出口，來源 IP 落回 `172.19.0.0/16`，`host-firewall.sh` 那條既有規則直接生效，防火牆一個字都不用改。

丟棄式驗證（先在一個 throwaway 專案上做完才動真的）：

```bash
$ docker network create --internal --subnet 172.31.99.0/24 gwtest-internal
$ docker run -d --name gwtest-c --network gwtest-internal busybox:1.36 sleep 600
$ docker network connect proxy gwtest-c
$ docker exec gwtest-c ip route
default via 172.19.0.1 dev eth1          # ← proxy 拿到預設路由
172.19.0.0/16 dev eth1 scope link  src 172.19.1.8
172.31.99.0/24 dev eth0 scope link  src 172.31.99.2   # ← internal 網路，連 gw 都沒有
$ docker exec gwtest-c wget -T4 -qO- http://10.0.0.95:30098
<!DOCTYPE html>                          # 通
```

副作用是 `monitoring_default` 這張網路本身不再提供出公網的路徑，只掛這一張網路的容器就出不了公網。逐一檢查四個容器：`prometheus`/`grafana` 有 `proxy` 當出口不受影響（Grafana 的 Telegram 告警走的就是這條）、`node-exporter` 本來就不需要出網（反而是收斂攻擊面），**只有 `blackbox-exporter` 真的要出公網**（它得去探測 `prometheus.yml` 裡那批 `https://*.jerome.cloudns.asia`）。所以單獨給它掛一張只屬於本專案的 `egress` 網橋——刻意不用共用的 `proxy`：那是對外反代平面，把一個「能被 Prometheus 指使去打任意 URL」的 exporter 放進去等於白送一個 SSRF 跳板。

最終形狀（`vps_oracle/compose/monitoring/docker-compose.yml`，完整的 why 註釋在檔案裡）：

```yaml
services:
  prometheus:        # networks 區塊沒動：default + proxy(172.19.0.4)
  grafana:           # networks 區塊沒動：default + proxy
  node-exporter:     # 沒動：只在 default（現在等於沒有出網能力）
  blackbox-exporter:
    networks: [default, egress]      # 唯一改動的 service

networks:
  default:
    internal: true                   # ← 修法本體
  egress:                            # 只給 blackbox-exporter 出公網
  proxy:
    external: true
```

### 驗證

```bash
$ docker exec prometheus wget -T5 -qO- http://10.0.0.95:30098 | head -2
<!DOCTYPE html>
<html lang="en">
$ docker exec grafana wget -T5 -qO- http://10.0.0.95:30098 | head -2
<!DOCTYPE html>
<html lang="en">
$ docker exec prometheus ip route
default via 172.19.0.1 dev eth1      # ← 從 172.20.0.1 換成 proxy 的閘道
```

回歸檢查全過：Prometheus 18 個 target 全 `up`（含所有 blackbox 公網探測）、NPM 反代 Grafana 回 200、k3s 那個 hostNetwork socat relay 打 `172.19.0.4:9090` 仍回 `Prometheus Server is Healthy.`（`prometheus` 的固定 IP 有保住）、Grafana 出公網（Telegram 告警路徑）正常。

### 評估過但沒選的選項

| 選項 | 為什麼沒選 |
|---|---|
| `host-firewall.sh` 加一條 `-s 172.20.0.0/16 --dport 30000:32767 ACCEPT` | 能通，而且零容器重建。但 `172.20.0.0/16` 是 docker 從位址池動態分配的，網路一旦被重建就可能換號、規則靜默失效——這正是 [2026-08-16 幽靈規則事故](../../vps_oracle/host-firewall/README.md)（compose 網路重建後重用 `172.18.0.0/16`，把殘留規則套到新網路上）那一類的坑。要防這個就得在 compose 裡釘死 subnet，於是變成「改兩個檔案 + 一條跨檔案的隱性耦合」，反而比現在這個修法複雜；而且它是繞過根因（封包還是從錯的網路出去），下次這兩個容器要連宿主機上別的東西又會再撞一次 |
| 事後補 `docker network connect --gw-priority 1 proxy <容器>`（腳本 + systemd unit，比照 `host-firewall.sh` 的模式） | engine 層確實有效，但這個設定綁在**容器實例**上：任何人跑一次 `docker compose up -d` 重建容器就靜默失效，得靠 `docker events` 之類的機制守著才可靠。多一個 unit、多一個會無聲失效的失敗模式 |
| `prometheus`/`grafana` 只掛 `proxy`，把 `node-exporter`/`blackbox-exporter` 也拉進 `proxy` | 得把兩個沒有認證的 exporter（其中一個還是 SSRF 跳板）塞進共用的對外反代平面，攻擊面明顯變大，改動也最大 |
| `cap_add: NET_ADMIN` + 容器內加 `10.0.0.95/32 via 172.19.0.1` 靜態路由 | 為了一條路由給兩個容器發 `NET_ADMIN`，還要多一個 helper 容器在啟動時跑 `ip route add`。新權限 + 新元件，換一個 internal 一行就能達成的效果 |
| 目標位址改用 `172.19.0.1:<NodePort>` 而不是 `10.0.0.95:<NodePort>` | **不用改任何設定就已經是通的**（見上面「排查過程」的對照實驗）：`172.19.0.1` 對容器是 on-link，走 `proxy` 介面出去，來源 IP 天然合規。但它依賴「NodePort 綁在 `0.0.0.0`」這個目前為真、將來可能被 Cilium `nodePort.addresses` 收窄的前提，而且用一個 docker 網橋位址去指代「k3s 節點」很難讀。留在這裡當備案 |

## 教訓

- **compose 容器掛多張 docker network 時，不能假設「掛了某張網路」就等於「對外連線會走那張網路」**——實際預設閘道取決於 `GwPriority`（或沒設時的內部排序），需要用 `docker inspect --format '{{.NetworkSettings.Networks.<net>.Gateway}}'` 明確驗證，不能只看 `networks:` 區塊列了什麼
- **`host-firewall.sh` 的來源網段限制（`-s 172.19.0.0/16`）隱含一個前提**：呼叫者的封包真的會從那個網段出去。這個前提對單網路容器（像 NPM）天然成立，對多網路容器不成立，未來任何新的 compose service 想利用這條既有的「docker proxy net → k3s NodePort」路徑，都要先確認自己是不是也踩了同一個坑，不能只照抄 NPM 的防火牆規則邏輯就假設會通
- **`No route to host` 在容器情境下的常見成因是宿主機防火牆的顯式 REJECT，但這裡的根因其實更早一步——是容器自己選錯了出口網路**，防火牆規則本身完全正確；排查這類錯誤時，先確認封包實際從哪張網路出去，比直接懷疑防火牆規則寫錯更快定位問題
- **Compose Spec 有寫、`docker compose config` 也能驗證通過的欄位，不代表 compose 真的會把它送到 engine**。`networks.<name>.priority` 就是這樣：三個套件版本（5.1.1 / 5.1.4 / 5.5.0）都靜默吃掉這個欄位，`GwPriority` 永遠是 `0`。判斷一個 compose 欄位有沒有真的生效，唯一可信的方法是**套用後 `docker inspect` 看 engine 側的實際狀態**，不是看 `docker compose config` 的輸出，也不是看 spec 文件
- **想控制多網路容器走哪張網路出去，`internal: true` 比 `priority` 可靠**：internal 網路根本拿不到閘道，自然被排除在預設路由選舉之外，這是 docker 的既定行為而不是優先權比大小。反過來說，「把不該當出口的網路標成 internal」通常比「把該當出口的網路優先權調高」更貼近意圖，也順手把那張網路上不需要出網的容器（這裡是 `node-exporter`）的攻擊面收掉
- **要拿掉一整張網路的出網能力前，先逐個容器問「它需不需要出公網」**。這次四個容器裡只有 `blackbox-exporter` 需要，漏掉它的話所有公網探測會全部變紅，而且要等一個 scrape 週期才看得出來。給它補出口時也別圖省事塞進共用的 `proxy`——一個能被指使去打任意 URL 的 exporter 放進反代平面就是 SSRF 跳板，寧可多開一張只給它用的網橋
