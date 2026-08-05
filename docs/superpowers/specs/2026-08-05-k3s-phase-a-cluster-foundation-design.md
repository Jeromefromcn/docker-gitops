# K3s Phase A — 叢集基礎層設計

日期：2026-08-05

對應 [K3s 雲原生實驗平台路線圖](2026-08-05-k3s-cloud-native-platform-roadmap.md) 的 A 階段：K3s + containerd + Cilium（CNI/NetworkPolicy）+ 存儲 + 資源預算（ResourceQuota/LimitRange）。交付物：空的但可連通的叢集，NPM 能打進來。

## 範圍

**這階段要做的：**
- 單節點 k3s 叢集，Cilium 當 CNI（含 kube-proxy replacement），local-path-provisioner 當存儲
- 一個帶 ResourceQuota/LimitRange 的 workload 命名空間
- 用一次性冒煙測試驗證「NPM → k3s」的連通路徑，以及 NetworkPolicy 真的能擋流量
- 驗證完，叢集回到空的狀態；`vps_oracle/k3s/` 留下可重跑的驗證工具

**這階段不做的（留給後續階段）：**
- Ingress controller 選型（Traefik/nginx-ingress）—— 留到 phase C 真的遷移服務時再定，理由見下方「NPM 橋接」一節
- ArgoCD/GitOps —— phase B
- 任何實際服務遷移 —— phase C 起
- NPM 自身的遷移或替換 —— 路線圖原則已明確排除到 phase H

## 現狀約束（延續路線圖）

單機 4C/24G，現有 docker 服務已佔用 11Gi、CPU 4 核心跟所有服務共用；aarch64（Ampere Altra）、cgroup v2、iptables-nft 模式、無 ufw；k3s 使用自己內建的 containerd，與宿主機既有的 Docker daemon 是兩條獨立的容器執行時，互不感知、互不搶佔資源命名空間。

## 架構

```
Internet ──80/443──▶ npm（docker，本階段不變）
                        │ extra_hosts: host-gateway
                        ▼
                  宿主機 IP : NodePort（30000-32767）
                        │
                  ┌─────────────────────────────┐
                  │  k3s 單節點叢集（containerd）  │
                  │  - Cilium CNI                │
                  │    (kube-proxy replacement)  │
                  │  - Hubble relay + UI          │
                  │  - local-path-provisioner     │
                  │  - namespace: workloads       │
                  │    (ResourceQuota 1C/2Gi)     │
                  │  - 冒煙測試 pod（驗證完即刪）  │
                  └─────────────────────────────┘
```

## 元件與設定

| 項目 | 決定 | 理由 |
|---|---|---|
| 拓撲 | 單節點 k3s，server 角色 | 只有一台機器；k3s 的 server 節點預設就是 schedulable，不用額外拿掉 taint |
| CNI | Cilium，`kube-proxy-replacement: true` | 少一套 iptables 規則、少一個常駐進程；單節點下沒有跨節點路由要驗證，啟用的風險等同並存模式 |
| Cilium tunnel 模式 | VXLAN（chart 默認值） | 單節點所有 pod-to-pod 流量都在本機，native routing 沒有實際收益，用默認值減少變數 |
| 觀測 | Hubble relay + UI 都裝 | 對應路線圖的 SRE 學習目標；資源開銷（兩個常駐 pod）在 1C/2Gi quota 之外，算 kube-system 系統開銷 |
| k3s 內建 Traefik / ServiceLB | 裝機時 `--disable traefik --disable servicelb` | ingress controller 選型留到 phase C；單節點用不到 LoadBalancer 型 Service，NodePort 就夠 |
| 存儲 | local-path-provisioner，路徑用 k3s 默認 `/var/lib/rancher/k3s/storage` | 跟官方文件/社群討論的路徑一致，之後排查問題好對照 |
| 版本鎖定 | 安裝時查 k3s stable channel 與 Cilium 最新 Helm chart 的實際版本號，安裝後把鎖定的版本號寫回 `vps_oracle/k3s/README.md` | 本文件寫作於 2026-08，但設計者的知識截止在 2026-01，寫死版本號有很高機率是過時甚至不存在的版本；用「安裝時查最新 stable 並鎖定」這個程序取代具體號碼，落地時才把準確版本記錄下來 |
| kubeconfig | 不進 repo；從 `/etc/rancher/k3s/k3s.yaml` 複製到 `~/.kube/config`，`chmod 600` | 含叢集憑證，屬機密；repo 約定「不提交任何密鑰」 |

## Repo 佈局

新增 `vps_oracle/k3s/`，跟 `vps_oracle/compose/`（本次重整理後的既有 compose 棧目錄）平行：

```
vps_oracle/k3s/
  README.md              # 安裝步驟、驗證方式、各階段版本記錄
  install/config.yaml     # k3s server 啟動參數（非機密）
  cilium/values.yaml       # Helm values（非機密）
  manifests/
    namespace.yaml         # workloads 命名空間
    resourcequota.yaml      # 1 核 / 2Gi
    limitrange.yaml          # 未寫 resources 的 pod 套用的預設值
    smoke-test.yaml           # nginx + 固定 NodePort 30080，可重複使用的連通性/NetworkPolicy 驗證工具
```

`vps_oracle/k3s/` 底下不放任何 kubeconfig、node token 等機密——這些留在 `/etc/rancher/k3s/`、`/var/lib/rancher/k3s/`，不進 repo。

## NPM 橋接

NPM（docker compose 容器）跟 k3s（獨立 containerd + CNI 網路）是兩個完全不同的容器運行時，彼此看不到對方的容器網路。路線圖的遷移原則已明確：NPM 自身的網路歸屬/配置在 A~G 全程不動，留到 phase H 才評估是否被 k8s-native ingress 取代。所以橋接方式只有一條路可走：**NPM 轉發到宿主機層級**，不是容器對容器直連。

具體做法：
- `vps_oracle/compose/npm/docker-compose.yml` 加：
  ```yaml
  extra_hosts:
    - "host.docker.internal:host-gateway"
  ```
- k3s 側冒煙測試的 Service 用固定 `nodePort: 30080`（不用隨機分配，NPM 那邊的轉發規則才可重現、可寫進文件）
- 驗證時在 NPM 建一條臨時 proxy host，Forward Hostname/IP 填 `host.docker.internal`，Forward Port 填 `30080`；驗證完刪掉這條臨時記錄

這個模式（host-gateway 轉發到宿主機端口）之後如果 phase C 真的裝了 ingress controller，也是同一套機制繼續用，只是 Forward Port 換成 ingress controller 的 NodePort——不用等到那時候才重新設計橋接方式。

## 命名空間與資源配額

- 命名空間：`workloads`（單一命名空間，phase A 不需要按服務分）
- ResourceQuota：`requests.cpu: 1`, `requests.memory: 2Gi`, `limits.cpu: 1`, `limits.memory: 2Gi`（request 與 limit 一致，不留寬放空間——phase A 唯一的住戶是冒煙測試 pod，用不到彈性；phase C/D 塞入真實服務時如果 1/2Gi 不夠，直接調大這個 quota，不影響已跑起來的 pod）
- LimitRange：給沒寫 `resources.requests/limits` 的 container 套一個保守預設值（例如 `default: 200m/256Mi`, `defaultRequest: 100m/128Mi`），防止手滑的 pod 吃光配額
- kube-system 裡的 Cilium/Hubble/CoreDNS/local-path-provisioner 不受這個 quota 限制——quota 只管 `workloads` 命名空間，這是預期行為，不是遺漏

## 驗證清單（phase A 過關標準）

1. `kubectl get nodes` → `Ready`
2. `cilium status --wait` 健康，確認輸出裡 `KubeProxyReplacement: True`
3. Hubble relay/UI 可達（`hubble status`，或對 UI service port-forward 確認能開）
4. `kubectl describe resourcequota -n workloads` 顯示配額生效
5. 冒煙測試 pod（`smoke-test.yaml`）跑起來，宿主機上 `curl localhost:30080` 有回應
6. **NetworkPolicy 實測**：在 `workloads` 命名空間再部署一個 pod，套一條 deny-all `NetworkPolicy`，驗證兩個 pod 之間流量被擋（用 `kubectl exec` 從一個 pod curl 另一個，預期逾時/拒絕）——這是路線圖 A 階段目標明寫的「CNI/**NetworkPolicy**」，只驗證連通性不夠
7. 經 NPM 臨時 proxy host，從外網對測試網域 curl，驗證 `Internet → npm → 宿主機:30080 → k3s pod` 全鏈路
8. 收尾：刪除冒煙測試的 Deployment/Service、刪除 NetworkPolicy 測試用的第二個 pod、刪除 NPM 臨時 proxy host，讓叢集回到「空」的狀態；`manifests/smoke-test.yaml` 保留在 repo，之後階段要重新驗證連通性時可以直接重跑

## 已知限制 / 失敗模式

- `flannel-backend=none` 讓 k3s 完全依賴 Cilium 提供 pod 網路——如果 Cilium 沒裝成功或掛了，節點會卡在 `NotReady`（fail-closed，符合預期，不是要處理的異常）
- kube-system 的系統元件（Cilium agent、Hubble relay/UI、CoreDNS、local-path-provisioner）不受 ResourceQuota 限制，理論上有把資源吃到超出 1C/2Gi workload 預算之外的可能；本階段先靠都用官方 Helm chart 的默認 request/limit 兜底，沒有另外訂 kube-system 的配額
- 宿主機 CPU 只有 4 核心，跟既有 docker 服務（llm、dify 等）共用；k3s + Cilium + Hubble 的常駐開銷疊加上去後，如果觀察到既有服務效能下降，下一步是重新檢視 Hubble UI 是否值得繼續開著（可以只留 CLI/relay），而不是重新設計整個 CNI 選型

## 交棒給 phase B

Phase B（ArgoCD + GitHub Actions CI 骨架）依賴這階段留下的：一個可連通、有 CNI/NetworkPolicy/存儲/配額機制的空叢集，以及 `vps_oracle/k3s/` 這個repo 目錄慣例——B 階段的 ArgoCD 相關非機密配置預期會繼續放在同一個目錄下。
