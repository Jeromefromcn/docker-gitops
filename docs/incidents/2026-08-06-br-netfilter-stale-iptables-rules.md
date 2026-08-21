# 事故記錄：br_netfilter 引爆 Docker 殘留 iptables 規則，導致 bridge 內部容器互連失敗

日期：2026-08-06
狀態：已解決
本文件刻意不提交 git，純粹留作排查過程的忠實記錄。

## 背景：完整因果鏈的起點

這個問題的起點，是使用者為了給 k3s 騰出記憶體，手動 `docker compose down` 了 `programming-learning-platform` 這個不屬於本 repo 管理的專案（見 [container-topology.md](../container-topology/v1.md)「不受本仓库管理的其他项目」一節）。k3s 安裝過程中發現這個 compose 其實還有用，於是使用者又把它 `docker compose up` 回來——**這個 down/up 週期，就是後面一連串問題的真正起點**，跟這次 k3s 安裝工作本身交織在一起，缺一不可。

## 完整時間線（使用者提供的關鍵背景 + 技術排查串起來）

1. **使用者操作**：`docker compose down` 停掉 `programming-learning-platform`，釋放記憶體給 k3s 安裝用
2. **這次任務**：Task 1 安裝 k3s，systemd unit 的 `ExecStartPre` 執行 `modprobe br_netfilter`——這是 Kubernetes 網路的標準前提條件，載入後連帶把全機共用的 `net.bridge.bridge-nf-call-iptables` 打開，效果是「連同一個 docker bridge 網路內部的容器互連流量，都要送去給 iptables 的 `raw`/`PREROUTING`、`FORWARD` 等 chain 評估」——這在此之前是不會發生的
3. **使用者操作**：發現 `programming-learning-platform` 還有用，`docker compose up` 把它帶回來。這次 up 建立了一個全新的 bridge（`br-b951f3fb0958`），但 Docker 自己在稍早 `down` 掉舊網路時，沒有把它自己加在 `raw` table 裡的防 IP 偽造規則清乾淨——留下幾條指向已經不存在的舊 bridge 介面（`br-66885a1f7aad`）的殘留 `DROP` 規則。這些規則因為例外條件指向的介面已經不存在，「介面不等於一個不存在的東西」永遠成立，等於變成無條件擋掉所有送到這幾個容器 IP 的封包
4. **使用者發現**：`up` 回來之後服務不可用——因為 `br_netfilter` 已經在第 2 步被打開了，第一次讓這批殘留規則真正發揮作用（在 `br_netfilter` 打開之前，這類殘留規則完全無害，純 bridge 內部流量根本不會被送進 `raw`/`PREROUTING` 去比對）
5. **使用者操作**：嘗試重啟 docker daemon 來解決服務不可用的問題——**這個重啟沒有解決 `programming-learning-platform` 的問題**（殘留的 `raw` table 規則不會因為 daemon 重啟而被清掉，因為它們掛在已經不存在的介面名稱上，daemon 重啟不會主動去比對現存介面清單做這種清理），但**把 `npm`、`3x-ui` 等所有掛在 `proxy` 網路上的容器 IP 全部打亂重新分配了一次**——這正是後續一連串 NPM access list / 3x-ui 代理訪問不了問題的根因（詳見另一份文件 [2026-08-06-proxy-access-ip-mismatch.md](2026-08-06-proxy-access-ip-mismatch.md)，這裡不重複展開，只在因果鏈裡點出關聯）
6. **後續排查**（本文重點）：使用者回報 `programming-learning-platform` 的 docker 網路內部，任何兩個容器之間都連不通，問是不是這次 k3s 相關的操作導致的

## 技術排查過程

### 第一步：確認現象、排除表面原因

- `docker exec programming-learning-platform-nginx-1 nc -zv -w3 172.18.0.3 9090` 逾時（`Operation timed out`，不是「連線被拒絕」，代表封包在網路層被擋，不是應用程式沒在監聽）
- 換好幾組容器互測（nginx→prometheus、nginx→mysql、api-server→mysql）全部一樣連不通，排除是單一 flow 或單一容器的問題
- 對照組：我們自己的 monitoring stack（grafana→prometheus，同樣是 bridge 內部互連）完全正常——確認不是全機通殺，只有 `programming-learning-platform` 這個網路中招

### 第二步：定位機制——確認是 br_netfilter

`lsmod | grep br_netfilter` 確認模組已載入，`sysctl net.bridge.bridge-nf-call-iptables` 顯示 `= 1`。做了一次決定性的對照測試：臨時把這個 sysctl 設回 `0`，`programming-learning-platform` 的容器互連立刻恢復正常；設回 `1`，問題立刻重現。這證實了**機制**（是這個開關在起作用），但還沒找到**具體是哪條規則**在擋。

### 第三步：追蹤封包實際去向

依序排除了以下幾種可能，逐一用實測證據排除：
- **bridge port STP 狀態**：`bridge link show` 確認所有 port 都是 `forwarding`，不是 `blocking`
- **tc/nftables/ethtool 層級過濾**：veth 上沒有 tc filter、沒有 XDP drop 計數、沒有額外的 nftables bridge family 表
- **ebtables**：規則是空的，policy 全部 ACCEPT
- **ARP 快取過期**：檢查來源容器的 ARP 表，目的地 MAC 位址是對的、跟目標容器現在的真實 MAC 一致
- **conntrack 狀態**：（一開始這台機器沒裝 conntrack 工具，使用者授權後現場 `apt install conntrack` 裝上）即時監看 conntrack 事件，發現**這個特定 flow 從頭到尾沒有在 conntrack 裡建立任何紀錄**——代表封包在進入連線追蹤系統之前就已經被處理掉了，指向 `raw` table（`raw` table 在 conntrack 之前被評估，是唯一能讓封包完全不留下 conntrack 紀錄就被丟棄的地方）

### 第四步：在 raw table 找到真正的規則

`iptables -t raw -L PREROUTING -n -v -x --line-numbers` 列出完整規則，找到成對出現的兩組規則，同樣的目的地 IP（`172.18.0.2` 到 `172.18.0.8`），但引用了兩個不同的 bridge 介面：

```
DROP  !br-66885a1f7aad  ->  172.18.0.3   (4967 個封包命中過，持續在累加)
...（172.18.0.2/4/5/6/7/8 同樣模式，共 7 條）

DROP  !br-b951f3fb0958  ->  172.18.0.3   (0 個封包命中過)
...（同樣的 7 個 IP，共 7 條）
```

`ip link show br-66885a1f7aad` 回報 `Device "br-66885a1f7aad" does not exist`——確認這是已經被刪除的舊 bridge。因為 iptables 由上而下評估、命中第一條就停止，所有流量都先撞上這組指向不存在介面的殘留規則被擋下，新規則（`br-b951f3fb0958` 那組）完全沒有機會被評估到，所以顯示 0 命中，不代表它們沒問題，只是輪不到它們。

### 第五步：精準修復

只刪掉那 7 條指向 `br-66885a1f7aad` 的殘留規則（`iptables -t raw -D PREROUTING <行號>`，從大到小刪以免行號位移錯亂），完全不動 `bridge-nf-call-iptables`（保持 `1`，k3s/Cilium 需要的行為原封不動）。刪完立刻重測，`172.18.0.3:9090` 從逾時變成 `open`。

另外掃了一遍整個 `raw` table，比對規則裡引用的所有介面名稱跟目前 `ip link show type bridge` 真實存在的介面清單，確認沒有其他殘留（只剩引用現存介面的規則）。

### 第六步：完整驗證

- `programming-learning-platform` 四組容器兩兩互連全部打通
- 我們自己的 monitoring stack（grafana↔prometheus）沒受影響
- k3s node 狀態 `Ready`、`cilium status` 顯示 `Cilium: OK`
- 全機容器狀態總覽，沒有其他異常

## 回答幾個直接的問題

**這跟 k3s 有沒有關係？** 有，但關係是「觸發條件」，不是「k3s 本身有 bug」。`br_netfilter` + `bridge-nf-call-iptables=1` 是所有主流 Kubernetes 發行版/CNI 方案的標準前提條件，k3s 這樣做完全正常、照文件走。

**這是真實的 bug 嗎？** 是，但 bug 在 **Docker 自己身上**：dockerd 在網路被 `down`/重建時，沒有把它自己加在 `raw` table 裡的防 IP 偽造規則清乾淨，留下指向已刪除介面的殘留規則。這個 bug 在純 Docker 環境（沒有任何 Kubernetes/CNI 組件）下永遠不會被察覺，因為純 bridge 內部流量根本不會被送進 `raw`/`PREROUTING` 去比對這些規則——k3s 沒有製造這個 bug，只是第一次打開了一扇會讓這個潛伏的殘留規則產生實際效果的門。

**有辦法避免嗎？** 沒辦法根除（不能不裝 `br_netfilter`，那是 k3s 網路能不能動的硬性前提；也沒辦法修 dockerd 自己的清理邏輯，那是上游程式碼）。能做的是**降低觸發機率**跟**提早發現**：
- 避免不必要的 `docker compose down` + `up` 週期，尤其避免在記憶體緊張、需要臨時騰資源這種情境下頻繁對同一個網路做 down/up（這正是這次的起點）
- 如果之後又遇到「同一個 docker bridge 內部容器突然互連不通」這個特定症狀，現在有完整可複製的排查路徑：`sysctl` 開關對照測試鎖定機制 → conntrack 有沒有留下紀錄判斷是不是卡在 `raw` table → 比對 `iptables -t raw -S PREROUTING` 引用的介面名稱跟 `ip link show type bridge` 目前真實存在的介面，抓出「引用不存在介面」的殘留規則

## 跟另一個事故的關聯

這次 daemon 重啟（第 5 步，使用者嘗試修復 `programming-learning-platform` 但沒修好）雖然沒解決本文要處理的問題，但把 `npm`、`3x-ui` 在 `proxy` 網路上的 IP 全部重新洗牌了一次，是另一份事故記錄（[2026-08-06-proxy-access-ip-mismatch.md](2026-08-06-proxy-access-ip-mismatch.md)）裡「NPM access list 訪問不了」問題的根因起點。兩份事故表面上看起來毫不相關（一個是 docker bridge 內部連不通，一個是 NPM 反代訪問不了），實際上是同一串操作鏈裡分岔出來的兩條後果，不是巧合。
