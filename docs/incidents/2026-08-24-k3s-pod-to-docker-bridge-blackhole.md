# 排查記錄：k3s pod 連不到 docker compose 容器，封包被 fwmark 導去 lo 黑洞

日期:2026-08-24
狀態:根因已確認，刻意不修（見下方「為什麼不修」）

## 背景

設計 [K3s Phase K（可觀測性接入）](../superpowers/specs/2026-08-24-k3s-phase-k-observability-design.md)時，原本打算讓 `pr-lanes` 的 Envoy/waypoint 把日誌、追蹤直接推（push）到 docker compose 網路裡新裝的 Loki、Jaeger。動工前先驗證這條路徑通不通，發現完全不通——這不是一次服務中斷，而是設計階段的連通性驗證直接卡死，記錄下來避免下次又花時間重查一遍。

## 排查過程

從 `pr-lanes` 內任一 pod（`kubectl exec` 進 `hello-backend`）連 compose 的 Prometheus 固定 IP：

```bash
kubectl -n pr-lanes exec hello-backend-xxx -- curl -m4 http://172.19.0.4:9090/-/healthy
# curl: (28) Operation timed out after 4002 milliseconds with 0 bytes received
```

先排除範圍：

- **host → compose Prometheus**：`curl http://172.19.0.4:9090/-/healthy` → `200`，服務本身健康
- **pod → 外部網際網路**：`curl http://1.1.1.1` → `301`，pod 的一般 egress 正常
- **一個完全不在 ambient mesh 裡的臨時 pod**（`default` namespace，無 ztunnel 攔截）一樣連不到 `172.19.0.4:9090` → 排除 ztunnel/ambient mesh 是元兇
- 叢集裡沒有任何 `NetworkPolicy`/`CiliumNetworkPolicy`/`CiliumClusterwideNetworkPolicy`（`argocd` namespace 除外，跟這條路徑無關）→ 排除 K8s/Cilium 策略層級的顯式拒絕

`tcpdump` 直接抓包定位：在目的地 docker bridge（`br-99f461e27ed6`）和本機實體網卡（`enp0s6`）上同時抓，濾條件是目的地 `172.19.0.4:9090`，重送一次請求——**兩邊都是 0 packets captured**。封包沒有被拒絕，是根本沒有被送到任何一個網路介面上。

`sudo cilium-dbg monitor --type drop` 全程監看，重送請求——沒有為這條 IPv4 流量產生任何 drop 事件（只有背景雜訊的 IPv6 鄰居發現封包）。代表 Cilium 的 eBPF policy 層級沒有主動丟棄它。

用 `sudo cilium-dbg monitor -v`（不篩 drop，看完整 trace）重送請求，抓到關鍵一行：

```
-> stack flow 0x4bbf5bf4 , identity 35328->world state new ifindex 0 orig-ip 0.0.0.0: 10.42.0.199:35494 -> 172.19.0.4:9090 tcp SYN
```

Cilium 正確把目的地識別成 `world`（叢集外），並且把封包交給「stack」（一般核心網路堆疊）處理——**不是**在 Cilium 這層被丟棄，之後才消失。

轉向查核心的 policy routing：

```bash
$ ip rule show
9:      from all fwmark 0x200/0xf00 lookup 2004
100:    from all lookup local
32766:  from all lookup main
32767:  from all lookup default

$ ip route show table 2004
local default dev lo proto kernel scope host
```

找到根因：一條優先權極高（`9`，比 `main` 表的 `32766` 早很多）的規則，把任何帶 `fwmark 0x200/0xf00` 的封包導去 table 2004，而這張表只有一條路由——`dev lo`。任何被打上這個 mark 的封包，不管原本目的地是誰，全部被導去 loopback，沒有任何 NAT/REDIRECT 改寫目的地，就這樣在 `lo` 上消失，不會被送到任何實體/橋接介面，也不會產生 Cilium policy 層級的 drop 事件（因為這是核心的路由決策，不是 Cilium eBPF 主動攔截）。

## 根因

`fwmark 0x200` 這個 mark 幾乎可以肯定是 Cilium 與 istio-cni 之間既有的流量重定向機制的一部分——把疑似要送給 mesh 本地代理（ztunnel/waypoint）的流量標記後導去本地處理。這台機器上 `vps_oracle/k3s/cilium/values.yaml` 已經記錄過同一類「Cilium 與 istio-cni 重定向機制互相搶跑」的先例（phase F+G Task 14，`socketLB.hostNamespaceOnly` 修的那個問題：Cilium 的 eBPF 資料面在 istio-cni 的 iptables REDIRECT 規則有機會保留原始 ClusterIP 之前，就先把它解析成後端 Pod IP）。這次是同一類問題的另一個實例，只是觸發條件不同——目的地是叢集外的私網位址（`172.19.0.0/16`，docker 的 `proxy` 網路），而非 ClusterIP。

具體是 Cilium 本身、還是 istio-cni 裝在每個 pod netns 裡的 iptables 規則寫入這條 fwmark，尚未查證到底——非 mesh 成員的 pod 一樣中招，代表這條規則的作用範圍**不是**逐 pod 由 istio-cni 寫入的（那樣非 mesh pod 不會有這條規則），更像是 Cilium 節點層級統一套用的機制，但這只是推論，沒有進一步確認。

## 為什麼不修

這條重定向機制目前是 ztunnel/waypoint 流量能正常工作的核心機制之一。貿然調整（例如試著把 `172.19.0.0/16` 從這條規則排除）風險是可能連帶弄壞現在運作正常的 mesh 流量重定向，而且需要先完整弄懂究竟是哪個元件寫入這條規則才能安全下手——這是一個值得獨立立項的深度調查，不該在設計可觀測性配置的過程中順手動刀。

Phase K 的設計完全繞開這個限制：不讓 pod 主動連出去打 docker compose 網路，改成三種遙測（指標/日誌/追蹤）全部走反方向——compose 的 Prometheus/Grafana 主動連 k3s 的 NodePort（見 [Phase K 設計文檔](../superpowers/specs/2026-08-24-k3s-phase-k-observability-design.md)），這條方向不受這個問題影響（已在生產環境驗證過，見 [2026-08-19 NPM NodePort 事故記錄](2026-08-19-npm-to-k3s-nodeport-outage.md)）。

## 教訓

- **這個限制不是 `pr-lanes` 或本次調查對象特有的**——任何 k3s pod 想連到 docker compose 網路裡的任何容器，都會撞到同一堵牆。未來任何想讓 k3s pod 主動連出去打 compose 容器的設計，動工前應該先重複這裡的診斷步驟（`tcpdump` 抓兩端 + `cilium-dbg monitor` + `ip rule`/`ip route show table <n>`），不要假設「同一台機器、有路由表項目」就代表通得了
- **`cilium-dbg monitor --type drop` 沒抓到 drop 事件，不代表封包沒被攔截**——這次的攔截發生在核心的 policy routing 層（`ip rule`/自訂路由表），不是 Cilium 的 eBPF policy enforcement，兩者是完全不同的機制，只看 Cilium 自己的 drop 監控會誤判成「Cilium 沒有攔截」
- **`ip rule show` + 逐一檢查每張自訂路由表**，應該是這類「封包憑空消失、沒有任何拒絕訊號」情境的標準排查步驟之一，比單純看 `iptables`/`cilium-dbg monitor` 更早發現問題——這次是查到很後面才想到看這裡
