# 事故記錄:trivy-operator 掃描並發配置失效引發 IO PSI 告警(cilium 自我搶鎖 + 全部 arm64 image 掃描失敗)

日期:2026-08-17
狀態:已解決(修正兩處 Helm values 誤放層級、關閉 initContainer 掃描、根治 arm64 掃描失敗;移除已失效的 skip 標籤)。遺留 Kyverno 校驗盲區、`builtInTrivyServer` 是否升級、部分服務是否搬回 compose 三項留待後續決策,見第 7 節。
環境:vps_oracle,同一台 4 核 ARM(aarch64)/23.4GB RAM 主機,k3s 單節點叢集,trivy-operator(Helm chart `trivy-operator` 0.35.0,operator 版本 0.33.0,鏡像 `mirror.gcr.io/aquasec/trivy-operator:0.33.0` + 掃描用 `mirror.gcr.io/aquasec/trivy:0.73.0`),GitOps 源 `github.com/Jeromefromcn/docker-gitops`(ArgoCD `automated: {prune:true, selfHeal:true}`)。
關聯文檔:[2026-08-17-k3s-memory-overcommit-io-pressure.md](2026-08-17-k3s-memory-overcommit-io-pressure.md)(同一天稍早的另一起事故,共用同一條 `io_pressure_critical` 告警規則;那次根因是節點記憶體超賣,這次是 trivy-operator 自己的配置問題與內部搶鎖,兩次觸發同一條告警但完全獨立)。
本文檔:完整記錄現場數據、排查鏈(含兩次自己踩到又自己修正的 Helm values 層級錯誤)、根因鏈、處置過程與驗證方法,以及尚未拍板的三項後續決策,供複用。

---

## 1. 現象

用戶再次收到 Grafana 告警:

```
IO PSI 'full' above 15% for 2 minutes on vps_oracle (processes stalled on IO, load average will follow)
```

與同一天稍早的記憶體超賣事故用的是同一條規則(`io_pressure_critical`),但那次的修復(調高 jaeger/trivy 兩處 memory limit)已經上線快一小時,理論上不該再犯——說明是新的、獨立的誘因。

## 2. 現場快照

### 2.1 即時 PSI:已回落,但 avg300 說明剛發生過

```
$ cat /proc/pressure/io
some avg10=0.00 avg60=0.84 avg300=8.16 total=3499161378
full avg10=0.00 avg60=0.63 avg300=6.15 total=1985975762
```

`avg10` 歸零(當下平靜),但 `avg300`(過去 5 分鐘)還有 6%+ 的殘留——說明尖峰剛結束不久,不是即時現行的持續告警,得往回查歷史。

### 2.2 用 Prometheus 拉 PSI 歷史,比對出多波尖峰

叢集裡本來就有 node-exporter + Prometheus(容器 `prometheus`,無對外 port,需 `docker exec` 進容器內部查 `localhost:9090`)。用 `rate(node_pressure_io_stalled_seconds_total[2m])*100` 拉過去 3 小時的 `full` 曲線,抓到至少 5 波明顯尖峰:

| 時間(HKT) | 峰值 |
|---|---|
| 12:56–13:21(持續 25 分鐘) | ~25–30% |
| 13:40 | **77.9%**(全天最高) |
| 13:48–13:49 | ~31–33% |
| 14:41–14:42 | ~10–11% |
| 14:59–15:01 | ~18–35% |

不是單次孤立尖峰,是反覆出現、間隔不規律的模式——排除「一次性事件」,轉向找「週期性/事件驅動的重複誘因」。

### 2.3 時間關聯:每一波都對上 trivy scan pod 建立

`journalctl` 翻出 `Observed pod startup duration`,篩 `trivy-system` namespace 的 `scan-vulnerabilityreport-*` pod,啟動時間精準對上每一波尖峰(13:20:45、13:49:06×3、14:41:33/14:42:18、15:00:03×4/15:00:48/15:01:33)。同時查 `docker` 側的 3x-ui 容器 log 出現 `database is locked`——一開始以為是獨立線索,後來確認時間點跟 trivy 尖峰重疊,是磁碟被 trivy 佔滿後 3x-ui 自己的 SQLite 寫入跟著卡住的**連帶症狀**,不是另一個病灶。

## 3. 排查鏈

### 3.1 第一個誤放層級的 Helm values(`scanJobsConcurrentLimit`)

查 `trivy-operator-config` ConfigMap 的 `OPERATOR_CONCURRENT_SCAN_JOBS_LIMIT`,live 值是 **10**。但 git 裡 `vps_oracle/k3s/trivy-operator/values.yaml` 明明寫著 `scanJobsConcurrentLimit: 3`。用 `helm show values trivy-operator --repo https://aquasecurity.github.io/helm-charts/ --version 0.35.0` 對照官方 chart schema,發現正確 key 要巢狀在 `operator:` 底下,而 repo 裡這個設定放在**頂層**——Helm 對不認得的 key 直接靜默忽略,這個設定從沒生效過,實際套用的是 chart 內建預設值 10。

10 個並發 scan job 共用同一個本地檔案系統快取目錄(`trivy.filesystemScanCacheDir`),這個快取用檔案鎖、不支援並發存取——查 6 小時內的 trivy-operator log,`Failed to acquire cache or database lock ... cache may be in use by another process: timeout` 出現 36 次,對應的 Job 事件裡有多筆 `BackoffLimitExceeded`(重試耗盡直接放棄)。每次失敗前都已經完整拉過一次 image layer,失敗了才發現搶不到鎖——並發掃描不但沒加速,反而讓同一批 image 被重複拉取、重複部分掃描,是這次 IO 尖峰的核心放大器。

### 3.2 為什麼是「每天固定時段的一波風暴」而不是隨機

查 `kubectl get vulnerabilityreports -A` 的 `creationTimestamp`,幾乎所有 report(30+ 個工作負載)都集中建立在**前一天**(08-16)14:01–18:10 這個窗口——也就是 trivy-operator 剛裝上去時做的初始全叢集掃描。配上 `OPERATOR_SCANNER_REPORT_TTL: 24h`,這批 report 隔天在同一相對窗口集體到期,觸發重掃風暴。而初始掃描本身因為上述並發鎖競爭花了將近 4 小時才排隊做完(14:01→18:10),這個「拖長」的時間分佈原封不動複製到隔天的到期時間上,於是重掃風暴也拖了 4 小時——**TTL 機制本身合理(用來抓「image 沒變但新 CVE 被揭露」這種 drift),真正的問題是並發鎖 bug 把「一天一次的例行重掃」拖成了跨 4 小時、還一路失敗重試的風暴**,而且只要 bug 不修,這個模式會每天在差不多時段重演。

### 3.3 修完並發限制,cilium 那個 job 還是持續失敗——第二個根因

把 `scanJobsConcurrentLimit` 移到正確位置並設成 1(commit `f666e29`)、驗證 live 生效後,`scan-vulnerabilityreport-c84ff9879`(對應 `kube-system/cilium` DaemonSet)仍然每 45–80 秒 `BackoffLimitExceeded` 一次,錯誤訊息一樣是 cache lock timeout。查這個 job 的 pod spec:cilium 的 DaemonSet 有 6 個 initContainer(`config`/`mount-cgroup`/`apply-sysctl-overwrites`/`mount-bpf-fs`/`clean-cilium-state`/`install-cni-binaries`)+ 1 個主 container,trivy-operator 幫它建 scan job 時,把這 7 個全部塞進**同一個 job pod**,而且是用一般 `containers:`(不是 K8s 的 `initContainers:`,那個才會循序執行)——Kubernetes 對一個 pod 裡的一般 container 預設同時啟動,所以這 7 個 trivy 掃描行程還是會同時搶同一把快取鎖,**跟 `scanJobsConcurrentLimit`(管跨 job 並發)完全無關,它管不到同一個 job 內部的並發**。

比對 `kubectl get daemonset cilium -o json`,確認這 6 個 initContainer 用的跟主 container 是**完全相同的 image digest**(`quay.io/cilium/cilium:v1.20.0@sha256:383968cd...`)——分開掃是純粹浪費。順手把全叢集所有 pod 的 initContainer image 跟主 container image 逐一比對,只有兩處是真的不同 image:`kyverno-admission-controller` 的 `kyverno-pre`(`kyvernopre:v1.18.2`)和 `homepage` 的 `seed-config`(`busybox:1.36`)。

### 3.4 獨立資深 SRE 複核

修完上述兩點後,另外拉一個獨立 agent(隔離 worktree,直接查 live 叢集,不看之前的推理過程)重新審視整件事,結果:
- 根因判斷成立,而且找到更扎實的證據——cilium 那個 job 在並發修好**之前**失敗 7 次、修好**之後**又失敗 4 次,間隔完全一樣,直接證明並發限制對它無效,問題純粹是同 pod 內部搶鎖
- 兩個已修的 nesting bug 都在 live ConfigMap 重新驗證過,確認生效
- **新發現一個更大的盲區**:不只 homepage,`hubble-relay`(後來查證是誤判,實際是 vikunja-notify-relay 的 container 剛好也叫 `relay`)、`trilium`、`evidence-os-website`、`placeholder-hello` 都因為同一個 arm64 問題掃描失敗;另外 `lab-environment` 的 5 個 `ops-lab/*:dev` image(本地建置、從沒推過 registry)因為 401 authentication 失敗,完全是另一個不相關的病因。合計叢集裡有 **10+ 個工作負載完全沒有 VulnerabilityReport**
- 查了 `kyverno/policies/require-vuln-scan-clean.yaml` 的邏輯:目前 `validationFailureAction: Audit`,以 `trivy-operator.resource.name` label 查該 owner 底下所有 report,若「CRITICAL 且有修復版本」的漏洞數 > 0 才 deny。**當一個工作負載完全沒有 report 時,查詢回傳空清單,`length > 0` 恆為 false,等於自動放行**——這不是「兩個 initContainer 覆蓋率變小」這種小問題,是「任何原因導致的掃描失敗都會讓對應工作負載永久繞過這條 policy」,而且沒有 deny 事件可供事後稽核,一旦切到 Enforce 會是無聲的漏洞
- 對「`builtInTrivyServer`(常駐 trivy-server,ClientServer 模式)當時被否掉」提出異議:實測記憶體 requests 只用 41%(9.9Gi/24Gi),之前引用的「111% limits 超賣」是軟性上限、不影響排程;而且 Standalone 模式下 cilium 那個 job 一次炸開 7 個 container、每個 768Mi limit,瞬間曝險反而衝到 5.4Gi,比一個穩定吃 1Gi limit 的常駐 trivy-server 更誇張。建議列入近期 roadmap 而非否決,因為這是唯一能同時根治「跨 job」和「同一 job 內部」搶鎖問題的方案。

### 3.5 arm64 掃描失敗的根本解法

Trivy CLI 掃描 multi-arch/單一架構 image 時,預設假設 `linux/amd64`,沒指定 `--platform` 就直接報錯「By default, only Linux amd64 images are supported for scanning」——這台節點是 Oracle Ampere(arm64),而 homepage/trilium/evidence-os-website/placeholder-hello/vikunja-notify-relay 都是這個 repo 自己 CI(`.github/workflows/patched-images.yml` 等)用 `platforms: linux/arm64` 建的**單一架構**image,沒有 amd64 變體可退,必然全滅。

另拉一個 agent 專門查有沒有 chart 層級的根本解:查了 chart 模板(`templates/configmaps/trivy.yaml`)沒有直接的 `trivy.platform` key,但有一個原樣透傳的 `trivy.configFile`;查 trivy-operator Go 原始碼(`pkg/plugins/trivy/image.go`)確認這個 ConfigMap key 真的會被掛載成 `/etc/trivy/trivy-config.yaml` 並傳給 trivy 執行檔的 `--config`;查 trivy CLI 原始碼(`pkg/flag/image_flags.go`)確認 config 檔案格式支援 `image.platform`。**實際端到端測試**:在 `trivy-system` 開一個獨立測試 pod(用叢集裡真正在用的 trivy image+tag),掛上 `image:\n  platform: linux/arm64` 的測試設定檔,直接對真正失敗的 homepage image 跑 `trivy image --config ...`——成功解析出 Alpine 3.24.1、跑完漏洞掃描、吐出正常 JSON,測完把測試 pod 和 ConfigMap 清掉,repo 和叢集都沒留痕跡。確認全域套用安全:節點 100% arm64,凡是能跑起來的 image 本來就一定是 arm64 相容的。

## 4. 根因鏈

```
values.yaml 的 scanJobsConcurrentLimit 放在錯誤的 YAML 層級(頂層,非 operator: 底下)
  → Helm 靜默忽略,實際套用 chart 預設值 10(而非意圖的 3)
    → 10 個 scan job 共用一個不支援並發的本地檔案鎖快取
      → 大量 "cache may be in use by another process: timeout"、重試、部分 BackoffLimitExceeded
        → 每次失敗前已完整拉過 image layer,純粹浪費磁碟 IO
          → 初始全叢集掃描被拖成近 4 小時
            → 24h TTL 到期時間繼承同樣的 4 小時拖延分佈
              → 每天在同一時段重演「重掃風暴」
                → 疊加 cilium DaemonSet 的 6 個 initContainer(與主 container 同 image)
                  → 被當成 7 個獨立 container 塞進同一 job pod、Kubernetes 預設同時啟動
                    → 即使跨 job 並發已限制為 1,同 job 內部仍然自我搶鎖,持續失敗
                      → 疊加多個工作負載因單一架構 arm64 image 而全數掃描失敗、不斷重試
                        → 大量小 IO(重試 + 部分完成的 image 拉取)推高 IO PSI full
                          → 15% 閾值持續 2 分鐘 → io_pressure_critical 反覆觸發
```

一句話:**兩個各自獨立的 Helm values 誤放層級(從未生效的 bug),疊加 trivy-operator 對「同一 job 內多 container」和「單一架構 image」這兩種情境處理不當,共同把「一天一次的例行安全掃描」變成了每天固定時段、持續數小時、還一路失敗重試的 IO 風暴。**

## 5. 處置過程

### 5.1 修復清單(按提交順序)

| commit | 內容 | 驗證方式 |
|---|---|---|
| `f666e29` | `scanJobsConcurrentLimit` 移到 `operator:` 底下,設為 1 | live ConfigMap 確認 `OPERATOR_CONCURRENT_SCAN_JOBS_LIMIT=1` |
| `2817e63` | 幫 homepage 貼 `trivy-operator.skip` 標籤(當時方案,後來發現無效) | 見下方「兩次自己踩到的層級錯誤」 |
| `86e53ea` | 修正 `skipResourceByLabels` 也放錯層級(誤放 `operator:`,應為 `trivyOperator:`) | **先跑 `helm template` 確認渲染結果,再 commit**——這是踩過第一次坑後改的流程 |
| `a54720b` | `trivyOperator.skipInitContainers: true` + `trivy.configFile: {image: {platform: linux/arm64}}` | `helm template` 驗證渲染 + push 後 live ConfigMap 二次確認 |
| `ab2e15f` | 移除 homepage 上已經沒用的 `trivy-operator.skip` 標籤 | 該標籤本來就放在 Deployment 自己的 `metadata.labels`,不會傳給實際被掃描的 ReplicaSet(只有 `spec.template.metadata.labels` 才會傳),從沒生效過;配上 arm64 根本解已經不需要跳過 |

**兩次自己踩到又自己修正的層級錯誤**,記錄下來避免下次重犯:
1. `scanJobsConcurrentLimit` 該放 `operator:` 底下,一開始放頂層
2. `skipResourceByLabels` 該放 `trivyOperator:` 底下(chart 把 operator 控制器設定和 scan-job/report 行為拆成兩個不同的頂層 key),一開始沿用上一次學到的教訓放進 `operator:`,結果放錯了另一個 block

從第二次開始改流程:**任何 values.yaml 改動先跑 `helm template <chart> --repo <url> --version <ver> -f values.yaml | grep <目標key>`,確認渲染結果非空、內容正確,再 commit push**——chart 對不認得的 key 完全靜默不報錯,單靠肉眼看 values.yaml 或看 git diff 看不出層級錯了。

### 5.2 ArgoCD 同步與 live 驗證

`automated selfHeal` 開著,push 後照例 `annotate argocd.argoproj.io/refresh=hard` 立即觸發同步而非等預設輪詢。有個容易漏掉的細節:trivy-operator 的三個 ConfigMap(`trivy-operator-config`、`trivy-operator`、`trivy-operator-trivy-config`)裡,只有 `trivy-operator-config` 的內容變化會透過 pod template 的 `checksum/config` annotation 自動觸發 rollout;另外兩個 ConfigMap 改了之後,即使 live 內容已經更新,**controller pod 不會自動重啟**(這些設定是啟動時讀一次,不是即時監看),必須手動 `kubectl rollout restart deployment/trivy-operator` 才會真正套用——第一次改 `skipResourceByLabels` 時漏了這步,靠 `kubectl exec ... env` 檢查發現新 pod 沒有對應的值才補上。

### 5.3 驗證修復是否真的生效,中間一段誤判

重啟後立刻看到 `scan-vulnerabilityreport-c84ff9879`(cilium)又 `BackoffLimitExceeded` 一次,一度以為 `skipInitContainers` 沒生效。追查發現:**這是重啟前就已經存在的舊 Job 物件**還在按自己建立當下(修復生效前)的 pod spec 內部重試——K8s Job 一旦建立,pod template 不可變,新設定救不了已存在的 job,只能等它自然把 backoff 次數用完、被清掉。clone `aquasecurity/trivy-operator` v0.33.0 原始碼確認 `pkg/kube/resources.go` 的 `GetContainerImagesFromPodSpec` 邏輯正確(`if !skipInitContainers { 加入 InitContainers }`),同時確認一個重啟後全新建立的 job(dify `worker-beat`,無 initContainer 干擾)容器數正常,判定是「舊 job 收尾」而非「修復失效」。約 10 分鐘後舊 job 陸續清空,不再有新的多 container job 出現。

## 6. 結果

| 指標 | 事發時 | 處置後 |
|---|---|---|
| IO PSI full(歷史尖峰) | 最高 77.9%(13:40),多波 25–35% | avg10 回落至 0.48 左右,無新尖峰 |
| trivy scan job 快取鎖失敗(6h 內) | 36 次,集中在 cilium 一個 job(77%) | 0(新建立的 job 不再出現) |
| cilium DaemonSet 掃描 | 每 45–80s `BackoffLimitExceeded`,永遠沒有成功 report | initContainer 不再被獨立掃描,主 container report 正常保留 |
| homepage/trilium/evidence-os-website/placeholder-hello/vikunja-notify-relay | 100% 掃描失敗(amd64-only 錯誤) | homepage 主 container 已驗證掃描成功(live 環境端到端確認);其餘 4 個同一設定生效,理論同步修復 |
| `OPERATOR_CONCURRENT_SCAN_JOBS_LIMIT` | 10(從未生效的 `3` 意圖之外的預設值) | 1,live 確認 |

## 7. 遺留 / 後續(尚未拍板,留給用戶決策)

1. **Kyverno `require-vuln-scan-clean` 的 fail-open 缺口**:目前還是 `Audit` 模式,暫無實際影響,但底層邏輯是「查不到 report 就放行」,而不是「查到 0 個漏洞才放行」。在真正切到 `Enforce` 之前,必須先跑一次 `kubectl get vulnerabilityreports -A` 對照所有 `kubectl get pods -A`,把「零 report」的工作負載列成 punch list——目前已知 `lab-environment` 的 5 個 `ops-lab/*:dev` image(401 authentication,跟這次修復完全無關)仍在此列。
2. **`operator.builtInTrivyServer`(ClientServer 模式)未採用**:第 3.4 節的獨立複核明確反對「直接否決」這個選項,認為現有修復(`skipInitContainers` + `scanJobsConcurrentLimit: 1`)本質上仍然脆弱——依賴並發數永遠停在 1,一旦之後有人調回去,搶鎖問題會立刻復發。ClientServer 模式是 trivy 官方對這類情境的建議做法,能同時根治跨 job 與同 job 內部的搶鎖,但要多開一個常駐 StatefulSet + 5Gi PVC。建議列入近期 roadmap 評估,不是本次事故的必要修復項。
3. **部分工作負載是否搬回 docker-compose**:另一個獨立評估認為 `homepage`/`trilium`/`evidence-os-website`/`placeholder-hello`(架構理由,非因為這次的 arm64 問題)以及 `dify`(最強案例——官方自己就是用 compose 維護,現在跑的是手工翻譯的 k8s 版本)值得考慮遷移;`lab-environment` 命名空間應該留在 k3s(確認是刻意用來練習 k8s 原生模式的 demo 環境)。**這次 arm64 根本解一修,homepage/trilium 原本「順手解決」的急迫性已經消失**,遷移與否純粹回歸架構簡化的長期決策,不必因為這次事故趕著做。
4. **trivy 用的 `--slow` flag 已標記 deprecated**(chart/CLI log 提示改用 `--parallel 1`),目前功能上等效,但未來 chart 升級版本時語意可能改變,值得屆時重新確認並發行為。

## 8. 附:複用命令

```bash
# 從容器內部查 Prometheus(容器沒對外開 port)
docker exec prometheus wget -qO- "http://localhost:9090/api/v1/query_range?query=rate(node_pressure_io_stalled_seconds_total%5B2m%5D)*100&start=<unix>&end=<unix>&step=60"

# 查某個 trivy scan job 各 container 的實際失敗訊息(pod 通常已被清掉,只能查 operator 自己的 log)
kubectl -n trivy-system logs deployment/trivy-operator --since=6h | grep '"job":"trivy-system/scan-vulnerabilityreport-<hash>"'

# 任何 Helm values 改動,commit 前先驗證渲染結果,不要只憑肉眼看 YAML 縮排
helm template <release> --repo <repo-url> --version <ver> -f values.yaml | grep -A3 <目標key>

# ArgoCD 立即觸發同步(不等預設輪詢週期),多個 app 一起 annotate
kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite

# ConfigMap 改了但 controller pod 沒有 checksum annotation 覆蓋時,手動重啟讓它重新讀取
kubectl -n <ns> rollout restart deployment/<controller>
kubectl -n <ns> rollout status deployment/<controller> --timeout=60s

# 判斷「一個一直失敗的 scan job 是不是舊物件在收尾」而非修復沒生效
kubectl -n trivy-system get job <job-name> -o jsonpath='{.metadata.creationTimestamp}'  # 對比修復生效的時間點

# 全叢集比對 initContainer image 跟主 container image 是否重複(評估 skipInitContainers 代價)
kubectl get pods -A -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    spec = item['spec']
    main_images = set(c['image'] for c in spec.get('containers', []))
    for ic in spec.get('initContainers', []):
        status = 'SAME' if ic['image'] in main_images else 'DIFFERENT'
        print(status, item['metadata']['namespace']+'/'+item['metadata']['name'], ic['name'], ic['image'])
"

# 端到端驗證 trivy config 是否真的生效(不動 live 環境,獨立測試 pod)
kubectl -n trivy-system run trivy-test --rm -it --image=mirror.gcr.io/aquasec/trivy:0.73.0 \
  --overrides='{"spec":{"containers":[{"name":"trivy-test","image":"mirror.gcr.io/aquasec/trivy:0.73.0","command":["sleep","3600"],"volumeMounts":[{"name":"cfg","mountPath":"/etc/trivy"}]}],"volumes":[{"name":"cfg","configMap":{"name":"<test-configmap>"}}]}}' \
  -- trivy image --config /etc/trivy/trivy-config.yaml <目標image引用>
```
