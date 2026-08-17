# 事故記錄:trivy-operator 掃描並發配置失效引發 IO PSI 告警(cilium 自我搶鎖 + 全部 arm64 image 掃描失敗)

日期:2026-08-17
狀態:已解決(修正兩處 Helm values 誤放層級、根治 arm64 掃描失敗;`skipInitContainers` 一度以為解決了 cilium 自我搶鎖,後來證實是 trivy-operator 本身的半成品實作、根本不生效,改用把 cilium 整個 DaemonSet 排除在掃描外才真正解決,而且第一次嘗試又放錯了 chart values 層級,最後改成直接對 live 資源打標籤——確認穩定超過 13 分鐘無復發)。遺留 Kyverno 校驗盲區、`builtInTrivyServer` 是否升級、部分服務是否搬回 compose、dify/hubble-ui 部分 container 原因不明零掃描四項留待後續,見第 7 節。
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

### 3.5 第三個發現:`skipInitContainers` 本身是半成品實作,根本沒生效

`skipInitContainers: true`(commit `a54720b`)加上重啟 trivy-operator 後,一度誤判「約 10 分鐘後舊 job 陸續清空,問題解決」(見 5.3 節原始記錄與下方更正)。事後用更長的時間窗重新檢查,發現 `scan-vulnerabilityreport-c84ff9879`(cilium)在設定生效**超過 25 分鐘後**仍然持續以 6 個 initContainer 的組合重建、失敗、`BackoffLimitExceeded`,間隔跟修復前一樣是 45–80 秒。

先做了一次低風險的假設驗證:cilium 主 container 那份 3 小時前建立的 report,`resource-spec-hash` 標籤會不會跟即時算出來的 hash 對不上,導致 operator 一直誤判「report 不存在、要重掃」?刪掉這份 report 讓 operator 重新建一份(10:56:00 建立成功),結果 `c84ff9879` 在新 report 建立**之後**照樣以 6 個 container 的組合重建並失敗——直接推翻了 hash 不對的猜測,證明是別的原因。

沿著這條線索重新 clone trivy-operator 原始碼往下追,發現問題出在 `pkg/vulnerabilityreport/builder.go` 的 `ScanJobBuilder.Get()`:
- 第 181 行 `kube.GetContainerImagesFromPodSpec(spec, s.skipInitContainers)` 確實正確套用了過濾,但這行的結果**只拿去產生一個 JSON annotation**(記在 Job 物件的 metadata 上),不影響 Job pod 實際要建哪些 container
- 真正決定「Job pod 裡放哪些 container」的是第 152 行 `s.plugin.GetScanJobSpec(...)`(trivy plugin 自己的程式碼,在 `pkg/plugins/trivy/`)——這個呼叫**完全沒有把 `s.skipInitContainers` 傳進去**,它會獨立從原始物件重新算一次容器清單,不知道要排除 initContainer

也就是說:`skipInitContainers: true` 只影響 operator 判斷「現有 report 夠不夠、要不要觸發重掃」這一步的邏輯,不會真的讓實際建出來的掃描 Job 少掉 initContainer。cilium 這種案例特別會卡進死循環,推測是因為縮短後的清單偶爾還是讓 `hasVulnReports`/`hasExposedSecretReports` 其中一項判斷不滿足(例如 secret report 沒對齊),一觸發重掃,`GetScanJobSpec` 又把全部 7 個 container 塞回去,重掃因搶鎖失敗、永遠沒辦法讓判斷條件穩定下來,於是無限循環。**這是 trivy-operator 0.33.0 這個版本本身的實作缺口,不是 values.yaml 配置能修的**,而且順帶造成一個新症狀:因為 `scanJobsConcurrentLimit: 1`,cilium 這個永遠不會成功、卻一直重建的 job 疑似長期佔用唯一的並發名額,導致 `dify` 的 `api`/`worker`/`worker-beat`(三者共用同一個 image)和 `hubble-ui` 的 `backend` container 完全排不到掃描機會——40 分鐘內 log 裡連一次嘗試都沒有。

**真正的修復**:改用已經驗證能用的 `skipResourceByLabels` 機制,直接把 cilium 整個 DaemonSet 排除在掃描範圍外(而不是只排除它的 initContainer)。查到 cilium 不是 ArgoCD 管的資源——`k3s/README.md` 的 Cilium 一節寫明是當初手動 `helm install` 裝的一次性 bootstrap,沒有對應的 ArgoCD Application、也沒有 selfHeal——所以除了在 `vps_oracle/k3s/cilium/values.yaml` 加標籤之外,還必須額外對 live 叢集手動跑一次 `helm upgrade`(commit `249e9ac`)才會生效,跟其他透過 ArgoCD 自動同步的修復不一樣。這個操作會觸發 cilium-agent DaemonSet 重建 pod,單節點叢集意味著重建瞬間全叢集的 pod 網路都有短暫依賴視窗——`helm upgrade` 這類直接對 live CNI 動手的指令,系統的自動模式分類器主動擋下來要求人工確認,確認後才執行。

**第一次用 `podLabels` 還是失敗了,而且是跟 3.3 節相反方向的錯誤**。`podLabels` 只會渲染到 `spec.template.metadata.labels`(pod 本身),但 trivy-operator 的 `SkipProcessing`(`pkg/operator/workload/helper.go`)檢查的是 `resource.GetLabels()`——也就是**被掃描的那個工作負載物件自己的 top-level labels**。DaemonSet 沒有 ReplicaSet 這種中間層,`resource` 直接就是 DaemonSet 本身,所以要看的是 DaemonSet 自己的 `metadata.labels`,不是 pod template。`helm upgrade` 套用後過了幾分鐘,cilium 的 job 一樣持續 `BackoffLimitExceeded`,直接確認標籤沒生效。查 chart 有沒有能精準只加在 DaemonSet 自己 metadata 上的 key:`commonLabels` 可以到達 DaemonSet 自己的 `metadata.labels`,但渲染範圍是**整個 chart**(連 `hubble-relay`、`hubble-ui`、`cilium-operator`、`cilium-envoy` 都會一起中標),排除範圍比預期大太多。最後改成直接對 live 資源打標籤(不透過 chart values):
```bash
kubectl -n kube-system label daemonset cilium trivy-operator.skip=true --overwrite
```
只改 metadata,不動 pod template/spec,不會觸發 rollout(commit `43f97be` 把這個決策和指令記錄進 `values.yaml` 註解,同時移除沒用的 `podLabels`)。代價不變:連 cilium-agent 的**主 container**也不再被掃描(不只 initContainer),但這才是真正停止死循環的辦法。

### 3.6 arm64 掃描失敗的根本解法

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

### 5.3 驗證修復是否真的生效,中間一段誤判(後來證實這個誤判本身也錯了,見 3.5)

重啟後立刻看到 `scan-vulnerabilityreport-c84ff9879`(cilium)又 `BackoffLimitExceeded` 一次,一度以為 `skipInitContainers` 沒生效。當時追查:clone `aquasecurity/trivy-operator` v0.33.0 原始碼確認 `pkg/kube/resources.go` 的 `GetContainerImagesFromPodSpec` 邏輯正確(`if !skipInitContainers { 加入 InitContainers }`),同時確認一個重啟後全新建立的 job(dify `worker-beat`,無 initContainer 干擾)容器數正常,**判定是「重啟前就存在的舊 Job 物件在收尾」,不是修復失效**,約 10 分鐘後不再看到新的多 container job,當時認為問題解決。

**這個結論是錯的**——只查了 `GetContainerImagesFromPodSpec` 本身邏輯對不對,沒有追到底「這個函式算出來的結果有沒有真的被拿去建 Job」。25 分鐘後用更長的觀察窗重新檢查,發現 cilium 那個 job 其實從未真正停過,只是重試間隔（45–80 秒)剛好讓當時 10 分鐘左右的觀察窗看起來像是「收尾完畢」。真正的根因與修復見 3.5 節。

## 6. 結果

| 指標 | 事發時 | 處置後 |
|---|---|---|
| IO PSI full(歷史尖峰) | 最高 77.9%(13:40),多波 25–35% | avg10 回落至 0–0.5% 常態,期間全量重掃觸發過一次 avg10 2% 左右的小波動,遠低於 15% 閾值 |
| trivy scan job 快取鎖失敗(6h 內) | 36 次,集中在 cilium 一個 job(77%) | `scanJobsConcurrentLimit` 修復後跨 job 搶鎖歸零;cilium 自我搶鎖直到把標籤直接打在 DaemonSet 自己的 `metadata.labels`(而非 chart 的 `podLabels`)才真正停止——**確認持續穩定超過 13 分鐘無復發**(見 3.5) |
| cilium DaemonSet 掃描 | 每 45–80s `BackoffLimitExceeded`,永遠沒有成功 report | 整個 DaemonSet(含主 container)已排除在掃描外,不再重試;主 container 漏洞覆蓋率的代價是有意識接受的(見 3.5) |
| homepage/trilium/evidence-os-website/placeholder-hello/vikunja-notify-relay | 100% 掃描失敗(amd64-only 錯誤) | 全部 5 個都已驗證掃描成功(live 環境端到端確認,`kubectl get vulnerabilityreport -A` 逐一核對過);其中 homepage 的 `seed-config` initContainer 後續又因為 3.5 節同一個 `skipInitContainers` 缺口重新被嘗試掃描、重新失敗——規模小(僅 2 個 container 互搶,非 7 個),不會引發 IO 風暴,結果跟原本接受的代價一樣(seed-config 沒有 report),不算新問題 |
| dify `api`/`worker`/`worker-beat`、hubble-ui `backend` | （事發時未特別檢查) | cilium 停止重試後、甚至重啟 trivy-operator 強制全量重掃後,這幾個依然完全沒有被嘗試掃描——**原本「被 cilium 佔住並發名額」的猜測不成立**(cilium 停了以後它們還是沒有被排到),真正原因未查明,列入第 7 節待查 |
| `OPERATOR_CONCURRENT_SCAN_JOBS_LIMIT` | 10(從未生效的 `3` 意圖之外的預設值) | 1,live 確認 |

## 7. 遺留 / 後續(尚未拍板,留給用戶決策)

1. **Kyverno `require-vuln-scan-clean` 的 fail-open 缺口**:目前還是 `Audit` 模式,暫無實際影響,但底層邏輯是「查不到 report 就放行」,而不是「查到 0 個漏洞才放行」。在真正切到 `Enforce` 之前,必須先跑一次 `kubectl get vulnerabilityreports -A` 對照所有 `kubectl get pods -A`,把「零 report」的工作負載列成 punch list——目前已知在此列的:`lab-environment` 的 5 個 `ops-lab/*:dev` image(401 authentication,跟這次修復完全無關)、`dify` 的 `api`/`worker`/`worker-beat`、`hubble-ui` 的 `backend`(原因見 3.5,cilium 修復後待確認是否解除)、以及**現在刻意排除的 cilium-agent 主 container**(3.5 節修復的直接代價,是有意識的取捨,不是缺口,但一樣會讓這條 policy 查不到它)。
2. **`operator.builtInTrivyServer`(ClientServer 模式)未採用**:第 3.4 節的獨立複核明確反對「直接否決」這個選項。這次 3.5 節又發現 `skipInitContainers` 本身是半成品實作、實際上完全沒解決 cilium 的問題,只能用「整個排除」這種更粗的手段收尾——**進一步佐證了複核當時的判斷:現有修復本質上仍然脆弱**,ClientServer 模式是唯一能讓 cilium 主 container 重新被掃描、同時不再需要擔心並發設定被誰調回去的方案。優先順序應該提高,不再只是「近期評估」。
3. **部分工作負載是否搬回 docker-compose**:另一個獨立評估認為 `homepage`/`trilium`/`evidence-os-website`/`placeholder-hello`(架構理由,非因為這次的 arm64 問題)以及 `dify`(最強案例——官方自己就是用 compose 維護,現在跑的是手工翻譯的 k8s 版本)值得考慮遷移;`lab-environment` 命名空間應該留在 k3s(確認是刻意用來練習 k8s 原生模式的 demo 環境)。**這次 arm64 根本解一修,homepage/trilium 原本「順手解決」的急迫性已經消失**,遷移與否純粹回歸架構簡化的長期決策,不必因為這次事故趕著做。
4. **trivy 用的 `--slow` flag 已標記 deprecated**(chart/CLI log 提示改用 `--parallel 1`),目前功能上等效,但未來 chart 升級版本時語意可能改變,值得屆時重新確認並發行為。
5. **`trivyOperator.skipInitContainers` 這個設定本身留著沒有壞處,但不要依賴它**:雖然對 cilium 沒用,但對「initContainer 跟主 container 不同 image、且沒有自我搶鎖問題」的一般情況,理論上仍然有效(只是「有效」僅限於 operator 自己的重掃判斷邏輯,不影響它已經在跑的 Job 內容)。真正想讓某個工作負載完全不被掃,還是要用 `skipResourceByLabels`,不要指望 `skipInitContainers` 能單獨解決同 pod 內多 container 搶鎖的案例。
6. **cilium 的修復方式(手動 `helm upgrade`)跟其他修復不一樣**,原因是 cilium 從裝上去就不是 ArgoCD 管的資源(見 `k3s/README.md`)。`vps_oracle/k3s/cilium/values.yaml` 之後如果再改,記得同樣要手動 `helm upgrade` 才會生效,git commit 本身不會觸發任何自動同步——這點容易跟這個 repo裡其他 k3s 資源的 GitOps 慣例搞混。另外 `trivy-operator.skip` 這個標籤本身**沒有透過 chart values 表達**(chart 沒有能精準只打在單一資源自己 metadata 上的 key),是直接 `kubectl label daemonset` 打上去的,`values.yaml` 只留了註解記錄指令——如果 cilium 的 DaemonSet 未來因為某些原因被整個刪除重建(而不是單純 `helm upgrade`),這個標籤不會自動恢復,要記得重新執行一次。
7. **dify `api`/`worker`/`worker-beat`、hubble-ui `backend` 為什麼完全沒被排到掃描,原因未查明**:一開始懷疑是被 cilium 的死循環佔住 `scanJobsConcurrentLimit: 1` 的唯一並發名額,但 cilium 停止重試後、甚至重啟 trivy-operator 強制做一次全量重新 reconcile 之後,這幾個依然连一次嘗試都沒有——推翻了「被佔用名額」的解釋。不影響這次 IO PSI 的結案判斷(它們只是零掃描,不製造 IO 負載),但要記得feeds into 第 1 點的 Kyverno 稽核清單。之後有空可以用 `kubectl -n trivy-system logs deployment/trivy-operator` 配合手動觸發（例如改動這幾個 Deployment 的一個無害 annotation 逼一次 reconcile)排查。

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

# 判斷「一個持續失敗的 job 是不是修復真的沒生效」,不要只看 10 分鐘就下結論——
# 用固定的 --since-time(而非相對時間)重疊查詢,確認某個現象是「修復生效時間點之後才出現」
kubectl -n trivy-system logs deployment/trivy-operator --since-time=<修復生效的UTC時間戳> | \
  grep -oE '"job":"trivy-system/scan-vulnerabilityreport-<hash>","container":"[a-z-]+"' | sort -u

# 找一個持續失敗的 job 目前正在掃哪些 container(即時,而非查歷史 log)
JOB=<job-hash>
kubectl -n trivy-system get pod -l job-name=scan-vulnerabilityreport-$JOB \
  -o jsonpath='{.items[0].spec.containers[*].name}'

# 找出某個工作負載是 ArgoCD 管的還是手動 bootstrap 的(改法完全不同)
kubectl -n argocd get application -A | grep <關鍵字即可,沒有結果代表是手動裝的>
# 若確認是手動裝的(例如本次的 cilium),改動生效方式是：
helm upgrade <release> <chart> --repo <repo-url> --version <ver> \
  --namespace <ns> -f <values.yaml> --kubeconfig /etc/rancher/k3s/k3s.yaml
```
