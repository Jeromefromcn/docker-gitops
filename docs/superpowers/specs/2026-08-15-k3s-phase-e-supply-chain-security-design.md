# K3s Phase E — 供應鏈安全加固設計

日期：2026-08-15

對應 [K3s 雲原生實驗平台路線圖](2026-08-05-k3s-cloud-native-platform-roadmap.md) 的 E 階段：Trivy 准入門禁、Cosign 驗簽、Sealed Secrets、Kyverno。交付物：鏡像/部署有政策把關。

前置：Phase B（GitOps）與 Phase D（剩餘服務遷移）已完成並驗證通過。叢集現況（2026-08-15 實測）：13 個 Application 皆 `Synced`/`Healthy`（argocd、phase-a-foundation、placeholder-hello、homepage、trilium、evidence-os-website、vikunja、apprise、dify、llm、headlamp、lab-environment、root）；節點 4C/24G，CPU 使用 13%、記憶體實際使用 78%（18.7Gi），requests 僅用 41%（10Gi）——記憶體 headroom 以「實際使用」計約 5.3Gi。

Phase D 交棒的具體待辦（見其設計文件「交棒給 phase E」章節）：
- Sealed Secrets 要接管 D 階段的帶外手動 Secret（`workloads/vikunja`、`dify/dify-secrets`、`llm/open-webui`、`llm/sillytavern`）
- Kyverno/PSS 基線要處理已知衝突：trilium 沒有 `runAsUser`

## 範圍

**這階段要做的：**
- 裝 Sealed Secrets controller，接管 D 階段遺留的 4 個帶外 Secret，建立往後 Secret 一律進 git（加密後）的慣例
- 裝 Kyverno（僅 admission-controller），實作三條 policy：
  1. Cosign imageVerify——只驗自建鏡像（`ghcr.io/jeromefromcn/*`）
  2. restricted-equivalent 安全基線——只匹配自建的兩個 Deployment（`placeholder-hello`、`vikunja-notify-relay`）
  3. Trivy CVE 門禁——全叢集所有 workload，CRITICAL 且有修復版本就擋
- 裝 Trivy Operator（Job-only 模式），為上述第 3 條 policy 提供 `VulnerabilityReport`
- 用 Kubernetes 內建 Pod Security Admission（PSA）幫本 repo 管理的 namespace（`argocd`、`workloads`、`dify`、`llm`、`headlamp`，以及本階段新建的 `kyverno`、`trivy-system`、`sealed-secrets`）掛 `baseline` 標籤
- 修正兩個自建 workload 的 securityContext，讓它們能通過 restricted-equivalent policy：
  - `vikunja-notify-relay`：補 `securityContext`（image 已是 `USER nobody`，只是沒宣告）
  - `placeholder-hello`：換 `nginxinc/nginx-unprivileged` base image（現在的 `nginx:alpine` 沒設 `USER`，實際用 root 跑），containerPort 改 8080
- 三條 Kyverno policy 先 `Audit` 模式觀察一段時間，確認無誤傷後才切 `Enforce`

**這階段不做的（留給後續階段或明確排除）：**
- 第三方鏡像的簽章/重簽（image promotion）——評估過工作量與現階段規模不成比例，見設計討論
- `lab-environment`（不屬本 repo 管理的專案）不掛 PSA 標籤，範圍只圈本 repo 管理的 namespace
- restricted 等級不對第三方鏡像 workload（trilium、vikunja、apprise、dify、llm 全家桶）強制——這些留在 baseline，phase D 交棒文件提到的 trilium `runAsUser` 衝突因此不需要處理
- Sealed Secrets 不處理 3x-ui（compose 保留，不在 k3s 範圍內）
- Trivy Server 快取模式（常駐 pod 存漏洞庫）——先用 Job-only 模式，省一個 ~512Mi 常駐 pod；若日後掃描頻率高到成本不划算再評估

## 現狀約束

延續路線圖與 phase A-D：單機 4C/24G，記憶體是比 CPU 更早見底的資源（CPU 13% vs 記憶體實測 78%）。`workloads` namespace 是混合的——自建鏡像（`placeholder-hello`、`vikunja-notify-relay`）跟第三方鏡像（`trilium`、`vikunja`、`apprise`、`homepage`、`evidence-os-website`）共用同一個 namespace，因此凡是「只想對自建鏡像生效」的政策，範圍必須用 workload/image reference 匹配，不能用 namespace 級別的機制（PSA 就是 namespace 級別，這是選擇「PSA 只做 baseline、restricted 交給 Kyverno per-workload」的直接原因）。

## 架構

```
                              ┌─ PSA label（K8s 內建，免費）
                              │   namespace: argocd/workloads/dify/llm/headlamp/kyverno/trivy-system/sealed-secrets → baseline
                              │
git push（policy YAML / values.yaml 變更）
        │
        ▼
ArgoCD（既有）
  root Application
    ├─ sealed-secrets（新增，Helm，獨立 `sealed-secrets` ns）──▶ controller pod
    ├─ trivy-operator（新增，Helm，獨立 `trivy-system` ns，Job-only values）──▶ operator pod + 觸發式 scan Job → VulnerabilityReport CRD
    └─ kyverno（新增，Helm，獨立 `kyverno` ns，只開 admission-controller）
          └─ policies/（新增，Kyverno ClusterPolicy manifests，validationFailureAction: Audit）
                ├─ restrict-image-registry.yaml   （Cosign verify，match: ghcr.io/jeromefromcn/*）
                ├─ require-vuln-scan-clean.yaml    （查 VulnerabilityReport，match: 全部 workload）
                └─ restricted-self-built.yaml      （restricted 基線，match: placeholder-hello / vikunja-notify-relay）
        │
        ▼
（部署任何新 Pod 時）
  admission webhook 依序過三條 policy → Audit 模式只記錄不擋 → 觀察期後改 Enforce
```

Sealed Secrets 是獨立子系統，不依賴 Kyverno/Trivy，可以先做、先驗證。

## 元件與設定

| 項目 | 決定 | 理由 |
|---|---|---|
| 三個新元件的 namespace | 各自獨立 ns：`kyverno`、`trivy-system`、`sealed-secrets`（皆為對應 Helm chart 預設值） | 比照 `headlamp` 已有的獨立 ns 慣例；三者都是叢集級元件，不寄生在 `workloads` 或其他業務 namespace 底下，PSA/資源配額範圍才好圈定 |
| Kyverno 安裝範圍 | 只裝 `admission-controller`（1 replica），關閉 `background-controller`/`reports-controller`/`cleanup-controller` | 這三個分別對應「背景複查既有資源」「PolicyReport 可視化」「TTL 資源清理」，本階段都不需要；關閉後省 3-6 個 pod，符合路線圖「組件可選省資源版本」原則 |
| Trivy Operator 模式 | Job-only，不開 `trivy-server` 常駐快取 pod | 省一個 ~512Mi 的常駐 pod；13 個鏡像的規模，重複下載漏洞庫資料庫的成本可接受，日後規模擴大再評估 |
| Cosign 驗簽範圍 | 只匹配 `ghcr.io/jeromefromcn/*`（`imageReferences`/`skipImageReferences`） | 第三方鏡像本來就沒有經過這條簽章 pipeline，無差別強制驗簽等於直接擋下現有服務；按 image reference pattern 限定範圍是 Kyverno/Sigstore policy-controller 官方文件的標準用法，不是權宜之計 |
| restricted 基線範圍 | 只匹配 `placeholder-hello`、`vikunja-notify-relay` 兩個 Deployment（per-workload，不是 per-namespace） | `workloads` namespace 混合自建與第三方鏡像，PSA 的 namespace 級別標籤做不到「只挑 namespace 裡兩個 workload」；改用 Kyverno per-workload policy，範圍邏輯與 Cosign 驗簽一致 |
| Trivy CVE 門禁範圍 | 全叢集所有 workload，不分自建/第三方 | 這條刻意不縮範圍——第三方鏡像才是真正未知風險所在，自建鏡像在 CI 端已經被 Trivy 擋過一次，這裡是雙保險，不是重複勞動 |
| PSA baseline 範圍 | `argocd`、`workloads`、`dify`、`llm`、`headlamp`、`kyverno`、`trivy-system`、`sealed-secrets`（本 repo 管理的 namespace，含本階段新建的三個） | `lab-environment` 不屬本 repo 管理，不動它的安全設定；`kube-system` 等系統 namespace 本就需要特權，不掛標籤 |
| Policy 上線節奏 | 先 `validationFailureAction: Audit` 觀察，確認無誤傷後改 `Enforce` | 標準 policy-as-code 上線節奏；Trivy CVE 門禁範圍最廣、風險最高，尤其需要這段觀察期抓第三方鏡像（dify/postgres/trilium 等）現有的 CVE 現狀，避免切 Enforce 瞬間卡死整批部署 |
| Trivy 掃描結果未就緒時的 admission 行為 | fail-closed（查無 `VulnerabilityReport` 就擋） | Trivy Operator 對全新鏡像是非同步掃描（觸發式 Job），admission 當下報告可能還沒生成。Fail-closed 較安全，代價是全新鏡像第一次部署會等 Operator 掃完才 sync 成功；ArgoCD 本就會自動重試，不需要人工介入，只是首次部署多花幾分鐘 |
| Sealed Secrets 私鑰備份 | controller 產生的 TLS 私鑰（`sealed-secrets-key` Secret）需額外匯出、加密後存到叢集外 | 單節點叢集沒有 etcd 多副本保底，私鑰是解密唯一憑證，丟失等於所有 SealedSecret 永久不可解；這是之前沒有的維運程序，本階段補上 |
| 現有 4 個帶外 Secret 遷移 | 用 `kubeseal` 逐一加密現有值，寫成 `SealedSecret` manifest 進 repo，取代原本手動建的 Secret | 接管 phase D 交棒表列的 `workloads/vikunja`、`dify/dify-secrets`、`llm/open-webui`、`llm/sillytavern`；之後新服務的 Secret 一律走這條路 |
| `vikunja-notify-relay` securityContext | Deployment 補 `runAsNonRoot: true` + `allowPrivilegeEscalation: false` + drop `ALL` capabilities + `seccompProfile: RuntimeDefault` | image 已用 `USER nobody`，只是沒有在 manifest 宣告；restricted 檢查的是宣告本身，不是實際執行身份 |
| `placeholder-hello` base image | 換成 `nginxinc/nginx-unprivileged`，containerPort 從 80 改 8080 | 現有 `nginx:1.31.3-alpine3.24` 沒有 `USER` 指令，容器實際以 root 執行，無法通過 restricted；這個 Service 沒有 NodePort/外部曝露，只是 CI 練手用途，改動風險低 |

## Repo 佈局

延續 phase A-D 建立的 `vps_oracle/k3s/` 慣例；Kyverno/Trivy Operator/Sealed Secrets 是叢集級元件，跟 `cilium/`、`argocd/` 同層，不放進 `apps/`：

```
vps_oracle/k3s/
  kyverno/
    values.yaml                       # Helm values：只開 admission-controller
    policies/
      restrict-image-registry.yaml    # Cosign imageVerify，match ghcr.io/jeromefromcn/*
      require-vuln-scan-clean.yaml    # 查 VulnerabilityReport，match 全部 workload
      restricted-self-built.yaml      # restricted 基線，match placeholder-hello / vikunja-notify-relay
  trivy-operator/
    values.yaml                       # Job-only 模式
  sealed-secrets/
    values.yaml
    secrets/
      vikunja.sealed.yaml             # kubeseal 加密後的產物，可安全進 git
      dify-secrets.sealed.yaml
      open-webui.sealed.yaml
      sillytavern.sealed.yaml
  manifests/
    pod-security-labels.yaml          # 新增：argocd/workloads/dify/llm/headlamp/kyverno/trivy-system/sealed-secrets 的 PSA baseline 標籤（用 kubectl label 或併入既有 namespace manifest）
  argocd/apps/
    kyverno.yaml                      # 子 Application：chart + values + policies/
    trivy-operator.yaml
    sealed-secrets.yaml
  apps/
    vikunja/k8s/relay-deployment.yaml # 修改：補 securityContext
    placeholder-hello/
      Dockerfile                      # 修改：base image 換 nginx-unprivileged
      k8s/deployment.yaml             # 修改：containerPort 80 → 8080
      k8s/service.yaml                # 修改：targetPort 同步改 8080
```

三個新 Application 沿用 `argocd.yaml` 的三來源模式（`chart` + values ref + `policies/`/`secrets/` manifests path），不是單一服務常見的 `apps/<name>/k8s/` 單來源模式。

## 驗證清單（phase E 過關標準）

**Sealed Secrets：**
1. `kubectl -n argocd get application sealed-secrets` → `Synced` + `Healthy`
2. 4 個既有 Secret（`workloads/vikunja`、`dify/dify-secrets`、`llm/open-webui`、`llm/sillytavern`）改由 `SealedSecret` 產生，`kubectl get secret <name> -o yaml` 內容與遷移前一致（值不變，只是來源換了）
3. 刪掉其中一個 Secret，確認 controller 從 `SealedSecret` 自動重建（證明真的接管了，不是只是加密存起來沒接上）
4. 私鑰已匯出備份到叢集外，備份檔案存在且加密

**Kyverno + Trivy：**
5. `kubectl -n argocd get application kyverno,trivy-operator` → 皆 `Synced` + `Healthy`
6. `kubectl get vulnerabilityreports -A` 有資料，涵蓋現有全部 workload 的鏡像
7. 三條 policy 先以 `Audit` 跑：`kubectl get events` 或 policy report 顯示的違規記錄裡，逐一確認「範圍設計是否符合預期」——尤其是 Trivy CVE 門禁對第三方鏡像（dify/postgres/trilium 等）的掃描結果，若有 CRITICAL+有修復版本的項目，先處理（升版或記錄例外）才能切 Enforce
8. `placeholder-hello`、`vikunja-notify-relay` 的 securityContext 修正後，手動觸發一次 sync，確認兩者仍正常 `Running`（不因為改了 base image/port 而掛掉）
9. 切到 `Enforce` 後：故意 apply 一個違規 manifest（例如指向未簽名的 `ghcr.io/jeromefromcn/*` 鏡像、或明知有 CRITICAL CVE 的鏡像），確認被 admission 擋下且錯誤訊息可讀
10. 切到 `Enforce` 後，複查所有既有 Application 仍 `Synced` + `Healthy`（證明沒有誤傷任何現存服務）

**PSA：**
11. `kubectl get ns argocd workloads dify llm headlamp kyverno trivy-system sealed-secrets -o jsonpath='{.items[*].metadata.labels}'` 確認 `pod-security.kubernetes.io/enforce=baseline` 都掛上
12. 複查這 8 個 namespace 底下所有 pod 仍 `Running`（baseline 不該擋到任何現有服務，若有意外要查原因）

## 已知限制 / 失敗模式

- **PSA baseline 對第三方鏡像沒有非 root 保護**：trilium 等第三方 workload 停在 baseline，仍可能以 root 執行——這是刻意的範圍縮減（見「這階段不做的」），不是遺漏；若日後想收緊，要先個別探測每個第三方鏡像的實際執行 UID
- **Trivy Job-only 模式重複下載漏洞庫**：每次觸發式掃描都要重新拉一次漏洞資料庫，掃描延遲比 trivy-server 快取模式高；13 個鏡像的規模可接受
- **Sealed Secrets 私鑰是單點故障**：叢集本身沒有 HA，私鑰備份是唯一救援手段，備份流程若沒做確實，等於這階段做的事白做
- **Audit → Enforce 的切換是人工判斷，不是自動化**：需要人工看過 Audit 期間的違規記錄，決定哪些要處理、哪些要加例外，才能切 Enforce；沒有自動化的「N 天後自動切換」機制，這是刻意的（供應鏈政策不該無人值守就自動收緊）
- **Trivy CVE 門禁 Enforce 後，既有服務若被新披露的 CVE 命中會擋新部署，不影響已運行的 pod**：admission 只管「新建」，不會因為背景掃描發現新 CVE 就砍掉正在跑的 pod；只有下次該 workload 觸發重新部署（改 tag、scale 等）時才會被擋，這是 admission 機制的本質限制，不是本設計的疏漏
- **`nginx-unprivileged` 換底之後 placeholder-hello 的 CI workflow 不需要改**：Dockerfile 換 base image、containerPort 改 8080，`.github/workflows/placeholder-hello.yml` 的 build/scan/sign 邏輯不受影響，不用碰

## 交棒給 phase F

Phase F（ApplicationSet PR Generator 泳道）依賴本階段留下的：Kyverno 的 per-workload 範圍匹配寫法（`restricted-self-built.yaml` 的 selector 模式，可複製給泳道環境用）、Sealed Secrets 的 `SealedSecret` 慣例（PR 泳道複製出的 namespace 也需要 Secret，沿用同一套 kubeseal 流程，不會重蹈 phase D 帶外 Secret 的覆轍）。

本階段同時是 phase G（服務網格）的前置：三條 Kyverno policy 目前用 `ValidatingAdmissionPolicy`/`ClusterPolicy` 的 match 邏輯（image reference / workload name），G 階段 Istio Ambient 若要對特定 namespace 選擇性啟用，可以參考同一套「per-workload 而非 per-namespace」的範圍圈定思路。
