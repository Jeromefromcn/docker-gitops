# K3s Phase B — GitOps 啟動設計

日期：2026-08-07

對應 [K3s 雲原生實驗平台路線圖](2026-08-05-k3s-cloud-native-platform-roadmap.md) 的 B 階段：ArgoCD（app-of-apps）+ GitHub Actions CI 骨架（build→Trivy→Cosign）。交付物：之後所有部署都走 GitOps，不手動 `kubectl apply`。

前置：[Phase A 叢集基礎層設計](2026-08-05-k3s-phase-a-cluster-foundation-design.md) 已完成並驗證通過（見其驗證清單），叢集現況：`workloads` 命名空間為空、Cilium/Hubble/local-path-provisioner 皆 `Running`，`kubectl get ciliumnode` 顯示 pod CIDR `10.42.0.0/16` 已鎖定。

## 範圍

**這階段要做的：**
- 用 Helm 安裝 ArgoCD，單副本、關閉不需要的元件
- 建 app-of-apps 結構：一個 root Application 管三個子 Application ——ArgoCD 自身、phase A 留下的 `namespace/resourcequota/limitrange`（目前是手動 `kubectl apply` 的，這階段收編進 GitOps）、新增的 `placeholder-hello` 佔位服務
- 新增 `placeholder-hello`：一個沒有實際用途、專門給 CI 練手的最小容器（例如回傳固定文字的 nginx），連同它的 Dockerfile 一起進 repo
- GitHub Actions workflow：偵測 `placeholder-hello` 原始碼變更 → build（x64 runner + QEMU 模擬 arm64）→ Trivy 掃描（CRITICAL 擋下）→ Cosign keyless 簽章 → push 到 GHCR
- 驗證「no manual kubectl apply」真的成立：手動改壞一個 ArgoCD 管的資源，確認 self-heal 自動改回來
- 把 ArgoCD UI 經 NPM 發布到公網，套 `self-only` access list（跟現有服務同款）

**這階段不做的（留給後續階段）：**
- 真正服務遷移（homepage、trilium 等）——phase C
- 從 image push 到部署的全自動化（Argo CD Image Updater 或類似機制）——這階段部署仍是「CI 簽好 image → 人工改 YAML 裡的 tag → commit → ArgoCD sync」，全流程走 git commit，符合「不手動 kubectl apply」的目標，但沒有做到 image push 觸發自動改 tag。這是刻意的範圍縮減，不是遺漏
- Trivy 准入門禁（cluster 端擋非法 image 部署）、Sealed Secrets、Kyverno——phase E
- ApplicationSet PR-generator 泳道——phase F；這階段裝的 ApplicationSet controller 只是 Helm chart 預設元件，先裝著但不使用
- homepage dashboard 卡片——ArgoCD 能對叢集做任何部署，比照 3x-ui 的先例歸類為安全敏感服務，不上卡片

## 現狀約束（延續路線圖與 phase A）

單機 4C/24G，`free -h` 實測目前 13Gi available（buff/cache 可回收）；docker-gitops 這個 repo 本身是 **private** GitHub repo，且就是要拿來當 ArgoCD 的 GitOps 來源 repo——不用另建 repo；宿主機是 aarch64（Ampere Altra），但 GitHub-hosted runner 預設 x86_64，需要 QEMU 跨架構建置；GHCR（`ghcr.io`）已是現有慣例（homepage、llm、3x-ui 都從那拉 image）。

## 架構

```
開發者 git push (main)
        │
        ▼
GitHub Actions（ubuntu-latest, x64 + QEMU）
  1. buildx build --platform linux/arm64
  2. Trivy image scan（CRITICAL → 讓 job 失敗）
  3. push → ghcr.io/jeromefromcn/placeholder-hello:<tag>
  4. cosign sign --yes（keyless，GitHub OIDC → Fulcio 憑證 → Rekor 透明日誌）
        │
        │（人工步驟：改 apps/placeholder-hello/k8s/deployment.yaml 的 image tag，git commit + push）
        ▼
ArgoCD（叢集內，argocd 命名空間）
  root Application（app-of-apps）
    ├─ argocd（自我管理的 Helm Application）
    ├─ phase-a-foundation（namespace + resourcequota + limitrange）
    └─ placeholder-hello（Deployment + Service，部署進 workloads 命名空間）
  ── selfHeal: true, prune: true，任何手動改動會被自動改回 git 狀態
        │
        ▼
ArgoCD Server（NodePort）
        │
        ▼
NPM（access list: self-only）──▶ argocd.jerome.cloudns.asia
```

## 元件與設定

| 項目 | 決定 | 理由 |
|---|---|---|
| 安裝方式 | Helm（`argo/argo-cd` chart），沿用 phase A 裝 Cilium 的模式 | 版本可鎖定、升級路徑清楚，跟現有慣例一致；安裝時查 chart 實際最新穩定版本號，鎖定後寫回 `vps_oracle/k3s/README.md`（設計文件寫作於 2026-08，具體版本號留到安裝當下再確認，避免寫死過期版本） |
| 拓撲 | 單副本（不開 HA） | 單節點叢集，HA 模式的多副本 repo-server/application-controller 沒有實際容錯收益，純粹多佔資源 |
| Dex（SSO） | 關閉 | 不接外部身份提供者；認證靠 ArgoCD 內建 local admin 帳號 + NPM access list 兩層 |
| Notifications controller | 關閉 | 這階段沒有告警通道整合需求，先不裝省資源，需要時再開 |
| ApplicationSet controller | 保留（chart 預設值） | Phase F 的 PR 泳道需要它；資源開銷小，現在先裝著不用，比屆時再升級 chart 簡單 |
| selfHeal / prune | 開啟，root 及所有子 Application 都套用 | 這是本階段的驗收核心——「之後所有部署都走 GitOps」若沒有 self-heal，手動 kubectl 改動不會被糾正，等於名不副實 |
| ArgoCD Server 對外協定 | `--insecure`（明文 HTTP），TLS 終止在 NPM | 跟 repo 現有其他服務同款模式（NPM 統一做 TLS termination，容器內部走明文），不用額外簽 ArgoCD 自己的憑證 |
| CI runner | `ubuntu-latest`（x64）+ `docker/setup-qemu-action` + `buildx` 模擬編譯 `linux/arm64` | 不佔宿主機資源、不用維護 self-hosted runner 的執行任意 workflow 程式碼風險；private repo 的 x64 runner 分鐘數在免費額度內，單一佔位 app 建置成本可忽略。日後若真的需要原生編譯速度，只需把 `runs-on` 換成 self-hosted，其餘 pipeline 不用動 |
| Trivy 掃描 | 掃 CI 建出的 image，CRITICAL 嚴重度讓 job 失敗 | CI 端擋下已知嚴重漏洞是基本供應鏈衛生；跟 phase E 的 cluster 端准入門禁不重複——CI 擋的是「經過這條 pipeline」的 image，cluster 端擋的是「任何被部署」的 image（例如繞過 CI 手動 push 的），兩層互補 |
| Cosign 簽章 | Keyless（GitHub OIDC → Sigstore Fulcio/Rekor） | 不用管理任何私鑰、不怕金鑰外洩或輪替問題；簽章與驗證都留公開可查的 Rekor 記錄，符合供應鏈透明度的業界作法 |
| Image tag 更新方式 | 人工改 `apps/placeholder-hello/k8s/deployment.yaml` 後 git commit | 刻意不做 CI 自動改 tag 回寫 repo（需要額外的 repo 寫入權杖與自動 commit 機制）；手動改 YAML + commit 已經滿足「部署走 git，不走 kubectl apply」的目標，自動化留給未來視需要再加 |

## Repo 佈局

新增內容，延續 phase A 建立的 `vps_oracle/k3s/` 慣例：

```
vps_oracle/k3s/
  argocd/
    values.yaml                    # Helm values（非機密）：Dex/notifications 關閉等設定
    apps/
      root.yaml                     # app-of-apps 根 Application，指向本目錄
      argocd.yaml                    # 子 Application：自我管理 argocd 這個 Helm release
      phase-a-foundation.yaml         # 子 Application：指向 ../../manifests/（phase A 留下的 namespace/quota/limitrange）
      placeholder-hello.yaml           # 子 Application：指向 ../../apps/placeholder-hello/k8s/
  apps/
    placeholder-hello/
      Dockerfile                    # 最小 nginx 佔位頁面
      k8s/
        deployment.yaml              # image tag 由人工改動觸發部署
        service.yaml

.github/
  workflows/
    placeholder-hello.yml           # build→Trivy→Cosign，push 到 GHCR
```

`vps_oracle/k3s/argocd/` 底下不放 ArgoCD admin 密碼、GitHub OIDC 相關設定以外的任何機密——Cosign keyless 簽章不需要在 repo 或 GitHub secrets 裡放任何金鑰材料；ArgoCD admin 初始密碼照 Helm chart 預設行為產生在叢集內的 Secret，不進 repo。

## NPM 橋接

沿用 phase A 驗證過的模式（NodePort → NPM 轉發到宿主機 IP:port）：ArgoCD Server 的 Service 開一個固定 NodePort，NPM 建一條 proxy host：

| 字段 | 值 |
|---|---|
| Domain Names | `argocd.jerome.cloudns.asia` |
| Scheme | `http` |
| Forward Hostname / IP | 宿主機內網 IP（目前 `10.0.0.95`，見 phase A README 的 DHCP 漂移提醒） |
| Forward Port | ArgoCD Server 的 NodePort |
| Access List | `self-only`（跟其餘服務同款，ArgoCD 敏感度更高，沒有理由放寬） |
| Websockets Support | 開啟（ArgoCD UI 用到） |

其餘 SSL 分頁設定跟 README「給服務接入 NPM 反代」章節一致，包含 Force SSL/HTTP2 開啟後要重新打開複查的已知坑。

## 驗證清單（phase B 過關標準）

1. `kubectl -n argocd get pods` 全部 `Running`，`kubectl -n argocd get application root -o jsonpath='{.status.sync.status}'` → `Synced`，`.status.health.status` → `Healthy`
2. 三個子 Application（argocd / phase-a-foundation / placeholder-hello）皆 `Synced` + `Healthy`
3. `kubectl get resourcequota,limitrange -n workloads` 顯示的內容跟 git 裡 `vps_oracle/k3s/manifests/` 一致（證明 phase A 資源已被 ArgoCD 接管，不再是手動 apply 的殘留狀態）
4. **Self-heal 實測**：`kubectl scale deployment placeholder-hello -n workloads --replicas=0`，等待數十秒，確認 ArgoCD 自動改回 git 裡宣告的副本數——這是本階段「不再手動 kubectl apply」宣稱成立的直接證據，不能只看 sync 按鈕能不能點
5. Push 一個 `apps/placeholder-hello/` 底下的改動，確認 GitHub Actions 全部 job（build/Trivy/Cosign/push）綠燈，`ghcr.io` 上出現新 tag
6. `cosign verify` 該 image（keyless，指定 GitHub Actions 的 OIDC issuer/identity），確認簽章驗證通過、能在 Rekor 查到對應記錄
7. 手動改 `k8s/deployment.yaml` 的 image tag 並 commit + push，確認 ArgoCD 自動 sync、`kubectl -n workloads get pods -l app=placeholder-hello` 跑起新 image
8. 經 NPM 從外網 `curl https://argocd.jerome.cloudns.asia`，確認能連到 ArgoCD 登入頁；確認 access list 生效（非白名單 IP 連不進來，如果有第二個網路環境可測）
9. 把安裝時鎖定的 ArgoCD/Cilium-同級版本號寫回 `vps_oracle/k3s/README.md`

## 已知限制 / 失敗模式

- QEMU 模擬編譯比原生慢，`placeholder-hello` 這種極小 image 影響可忽略；之後 phase C/D 若拿真正的服務（例如 llm 推理棧）走同一條 pipeline，建置時間可能明顯拉長，屆時要重新評估是否換 self-hosted runner，而不是現在就先做這個決定
- Image tag 更新是人工步驟，代表部署速度受限於人的反應時間，不是即時的；這是刻意的範圍縮減（見上方「這階段不做的」），不是要修的缺陷
- ArgoCD self-heal 會在數十秒的 reconcile 週期內回復手動改動，這段空窗期內叢集狀態短暫偏離 git；單節點實驗環境可接受，不是需要調小 reconcile 間隔的問題
- ArgoCD 對叢集有完整部署權限，NPM 層的 `self-only` access list 是目前唯一的存取控制；沒有另外開 ArgoCD RBAC 細分角色（單人維運，chart 預設的 admin 帳號已足夠），如果之後有多人協作需求要重新評估

## 交棒給 phase C

Phase C（挑 1~2 個低風險無狀態服務跑通遷移範本）依賴這階段留下的：一個能正常 sync/self-heal 的 ArgoCD、`vps_oracle/k3s/argocd/apps/` 下 app-of-apps 的既定寫法（複製 `placeholder-hello.yaml` 的模式，改成指向真正服務的 manifests 即可）、以及 CI pipeline 的骨架（`placeholder-hello.yml` 可以直接複製改 build context/image 名稱，套用到第一個真正遷移的服務）。
