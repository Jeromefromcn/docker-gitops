# 事故記錄：Cilium socket-LB 收窄到 host namespace，NPM 反代到 k3s NodePort 全斷

日期:2026-08-19
狀態:已解決

## 背景

同日稍早完成的 [phase F+G](../misc/2026-08-19-k3s-phase-fg-pr-lanes-summary.md)(Istio Ambient mesh + PR 預覽泳道)裡,[b79455f](../../vps_oracle/k3s/cilium/values.yaml) 把 Cilium 的 `socketLB.hostNamespaceOnly` 設為 `true`——這是解決 waypoint 收不到流量問題的正確修復,phase F+G 文檔裡端到端驗證過。之後使用者回報「k3s 環境部署的服務都不能訪問了」。

## 排查過程

`kubectl get pods -A`、ArgoCD Application 列表、node 狀態全部 Healthy/Synced,`pr-lanes` 命名空間裡 `hello-frontend`/`hello-backend` 也是 1/1 Ready。從宿主機本機 `curl 127.0.0.1:<NodePort>` 和 `curl 10.0.0.95:<NodePort>` 全部 200,waypoint 的 in-cluster 路由也正常——集群內部完全健康,一度以為跟今天的開發無關。

轉折點是想到 Cilium 的 eBPF NodePort 資料面掛在物理網卡(`enp0s6`)上,`127.0.0.1` 走 loopback 根本不經過那條路徑,不能證明外部可達;同時想起 NPM 容器是 `docker compose` 的 bridge 網路(`proxy`,172.19.0.0/16),不是 host network mode。改成從 NPM 容器內部 `docker exec npm curl 10.0.0.95:<NodePort>`,立刻失敗(`Couldn't connect to server`,0ms,即時被拒)。同樣的目標地址從宿主機自己發起完全正常——這個「host namespace 通、容器 netns 不通」的落差,跟今天唯一的相關改動(`socketLB.hostNamespaceOnly`)精準對上。

查了 `vps_oracle/host-firewall/host-firewall.sh`(host 防火牆的唯一權威來源,git 管控),`INPUT` 鏈從來沒有對 k3s NodePort 範圍(30000-32767)開過口子——之前之所以能通,完全是 Cilium socket-LB 之前的「Full」覆蓋範圍在悄悄兜底:任何進程(不只是 k8s pod,包含所有 docker-compose 容器)發起的到 Service/NodePort 位址的連線,都會在 `connect()` 階段被 Cilium 直接改寫成後端 pod IP,完全繞過 `iptables INPUT` 鏈。改成 `hostNamespaceOnly: true` 後,這條繞行只留給「主機自己的網路命名空間」,NPM 這類 docker bridge 容器全部被排除,直接落進 `INPUT` 鏈預設的 `REJECT --reject-with icmp-host-prohibited`。

直接讀 NPM 的實際生產配置(`docker exec npm cat /data/nginx/proxy_host/30.conf`,headlamp 的反代)確認 `$server = 10.0.0.95`、`$port = 30098`,證實這正是真實生產路徑,不是猜測——grafana.lab、argocd、jaeger、consul 等全部同一種模式,所以表現為「k3s 所有服務都不能訪問」,而不只是今天改動的 pr-lanes/hello。

## 根因(兩層,缺一不可)

`socketLB.hostNamespaceOnly: true` 本身是對的、必要的(PR 泳道的 waypoint L7 路由需要它),但它有一個從未被記錄過的副作用:之前 NPM → k3s NodePort 這條路徑能通,完全是 socket-LB 「Full」覆蓋範圍的意外副作用——這個範圍下,Cilium 對*任何*進程(不分 netns,只要在同一台機器的 cgroup 階層下)的 `connect()` 呼叫做 socket 層級改寫,直接把目的位址換成後端 pod IP,連封包都還沒組出來就完成轉發,完全不經過一般的路由/iptables 路徑。收窄成 host-namespace-only 後,NPM 這類 docker bridge 容器的 `connect()` 不再被改寫,連線退化成一般 TCP 封包,而這種封包沒有任何有效送達路徑:

1. **host 防火牆從未放行過這條路徑。** `host-firewall.sh` 的 `INPUT` 鏈從來没有對 k3s NodePort 範圍(30000-32767)開過口子。
2. **就算防火牆放行,也沒有東西在收。** 用一個跟 NodePort 完全無關、單純自架的 `socat` 監聽埠做?對照實驗:同樣從 NPM 容器連,一樣是「立即拒絕」——證實問題不是 Cilium NodePort 邏輯本身的特例,而是這種「同一台機器上、非 host netns 發起、目的地是本機位址」的封包(hairpin),既不會被 Cilium 掛在 `enp0s6` 上的 NodePort eBPF 攔到(封包是本機路由送達,根本沒有真的從網卡進來),也沒有 socket-LB 幫忙改寫了——兩條 Cilium 的 NodePort 實現路徑(host netns 的 socket 改寫、外部封包的網卡 eBPF)都覆蓋不到這個情境。

## 修復(兩部分)

**1. `vps_oracle/host-firewall/host-firewall.sh`** 加一條明確的 `INPUT` 放行規則,把上面第一層根因的口子打開:
```
ipt INPUT -s 172.19.0.0/16 -p tcp -m tcp --dport 30000:32767 -j ACCEPT
```
來源限定在 docker `proxy` 網路(NPM 所在網路)的網段,目的端口限定在 k3s 的 NodePort 範圍,不對外開放,風格跟既有的 `-s 10.42.0.0/16`(pod CIDR → 特定端口)規則一致。

**2. 新增 [`vps_oracle/npm-nodeport-relay/`](../../vps_oracle/npm-nodeport-relay/)**,補上第二層根因缺的「有東西在收」:一個 systemd 模板服務,每個 NPM 依賴的 NodePort 各起一個 `socat` 實例,監聽在 host netns、轉發到 `127.0.0.1:<同一個 port>`。因為這個轉發本身是從 host netns 發起的 `connect()`,依然會被 socket-LB 正確改寫到後端 pod——用「host netns 裡真的有進程在收」取代「指望 Cilium 幫忙轉」。NPM 的設定完全不用改,原樣打 `10.0.0.95:<NodePort>`,現在會落到這個 relay 上而不是黑洞裡。

兩部分缺一不可:光加防火牆規則,`socat` 對照實驗裡换成 NodePort 本身的埠一樣連不上(前面驗證過);光加 relay 不加防火牆規則,連線在 `INPUT` 鏈的預設 `REJECT` 就先被擋了。

## 驗證

兩部分都上線後,從 NPM 容器內部重測所有它實際依賴的 NodePort:
```bash
docker exec npm curl -sS -m5 -o /dev/null -w "%{http_code}\n" http://10.0.0.95:30090/   # argocd
docker exec npm curl -sS -m5 -o /dev/null -w "%{http_code}\n" http://10.0.0.95:30092/   # consul
docker exec npm curl -sS -m5 -o /dev/null -w "%{http_code}\n" http://10.0.0.95:30094/   # grafana
docker exec npm curl -sS -m5 -o /dev/null -w "%{http_code}\n" http://10.0.0.95:30095/   # jaeger
docker exec npm curl -sS -m5 -o /dev/null -w "%{http_code}\n" http://10.0.0.95:30097/   # api-gateway
docker exec npm curl -sS -m5 -o /dev/null -w "%{http_code}\n" http://10.0.0.95:30098/   # headlamp
```
全部回 200(consul 回 301,是它自己 UI 的正常導轉,不是錯誤)。

## 教訓

改 Cilium socket-LB 覆蓋範圍這類「看起來只影響 k8s 內部」的集群級網路設定時,要意識到它可能也在為集群外部(同機的 docker-compose 容器)的路徑兜底——尤其是這台機器上 k3s 和 docker compose 混部、共用同一個宿主機網路棧的架構。下次再調整 socket-LB / kube-proxy 相關設定,應該同步檢查 NPM 這類非 k8s 消費者的可達性,而不是只跑 k8s 自己的端到端驗證。
