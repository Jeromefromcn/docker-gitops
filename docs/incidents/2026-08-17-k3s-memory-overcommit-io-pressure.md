# 事故記錄:k3s 記憶體超賣引發 IO PSI 告警(jaeger / trivy 被 OOM Kill)

日期:2026-08-17
狀態:已解決(調高兩處 container 記憶體 limit;新增巡檢 check 補上偵測缺口;放寬 `io_pressure_warning` 告警窗口降噪)
環境:Oracle VPS,4 核 ARM(aarch64)/ 23.4 GB RAM,4G swap(2026-08-15 事故後補上);同機混跑 docker compose(grafana/prometheus/npm/portainer/ccr/switchboard/plans/3x-ui 等)與 k3s(argocd/dify/headlamp/cilium/kyverno/lab-environment/llm/workloads/trivy-system/sealed-secrets 共 9+ namespace,約 50 個 pod)
關聯文檔:[2026-08-15-vscode-sessions-resource-spike.md](2026-08-15-vscode-sessions-resource-spike.md)(同一台機器上一次「記憶體耗盡 → IO 風暴」的事故。根因完全不同——那次是 VS Code session 洩漏,這次是 k8s workload 的 resource limit 配置問題——但下游機制(page cache 抖動 → IO PSI 飆高)高度相似,本次能快速定位很大程度上是複用了那次補的 PSI 告警規則)
本文檔:完整記錄現場數據、排查鏈、因果分析、處置過程與後續調整,供複用。

---

## 1. 現象

用戶收到 Grafana 告警(規則 `io_pressure_critical`,`host-metrics-rules.yml`,繼承自 2026-08-15 事故後補的 PSI 監控):

```
IO PSI 'full' above 15% for 2 minutes on vps_oracle (processes stalled on IO, load average will follow)
```

## 2. 現場快照

### 2.1 PSI 確認告警屬實

```
$ cat /proc/pressure/io
some avg10=30.57 avg60=30.49 avg300=25.07 total=2942640537
full avg10=24.97 avg60=26.54 avg300=21.99 total=1538669957
```

`full avg10` 近 25%,遠超 15% 閾值,不是誤報,且持續中(`avg300` 同樣高,代表過去 5 分鐘一直如此)。

### 2.2 讀寫方向:vmstat

```
$ vmstat 1 5
procs -----------memory---------- ---swap-- -----io---- -system-- -------cpu-------
 0  1 258476  904956 925076 7596236    4   21   2086   5623 12156   54 10  5 81  3
 0  1 258476  907536 925076 7596200    0    0  90980    200 10696 18025  5  5 69 21
 0  1 258476  909096 925076 7596356    0    0  92016     20 11079 18985  5  5 70 20
 1  0 258472  911784 925076 7596296    8    0  91780    288 13588 23334  5  6 66 22
 2  0 258472  905108 925076 7596288    0    0  87496      0 12516 22253  6  5 66 21
```

`bi`(讀)常年 90000+ 塊/秒(≈90MB/s),`bo`(寫)近乎 0,`wa` 佔 20%+ CPU——確定是**讀**在拖慢系統,不是寫。

### 2.3 排除項

```
$ free -h
               total   used  free  shared  buff/cache  available
Mem:            23Gi    14Gi  1.1Gi   63Mi       8.1Gi        8.9Gi
Swap:          4.0Gi   252Mi  3.8Gi
$ df -h /
/dev/sda1  193G  73G  121G  38%  /
```

磁碟空間充足(38%),排除「磁碟滿」;`iostat` 未安裝,改用 `vmstat` + `/proc` 直接排查。可用記憶體已經偏緊(1.1Gi 真正空閒),留了個伏筆。

## 3. 排查鏈

**第一步,找「誰在讀」**:先以一般用戶身份掃 `/proc/*/io` 算每個進程 2 秒內的讀寫增量,只抓到自己(當前終端會話),說明真正大戶是別的使用者/root 權限進程,改用 `sudo` 重掃,抓到 `all-in-one-linux`(PID 713618),讀速率約 93MB/s,遙遙領先。

**第二步,關鍵轉折點——read_bytes 與 rchar 的矛盾**:去看這個進程實際打開了哪些檔案(`/proc/pid/fd`),結果**只有 socket,沒有一個磁碟檔案**;再看 `/proc/pid/maps` 的檔案映射,也只有它自己的執行檔。但 `/proc/pid/io` 顯示:

```
rchar: 18033040        # 進程主動 read() 拿到的字節數,~18MB
read_bytes: 63512895488 # 內核真實從區塊裝置讀的字節數,~63.5GB
write_bytes: 0
```

兩者差了 3000+ 倍。正常「讀檔案」的進程這兩個數字量級應該接近。這種「區塊裝置讀了很多、但進程自己沒讀那麼多」的特徵,通常只有一種解釋:**這個進程自己的記憶體頁被核心換出去了,現在又換回來**——這個「換回來」的 IO 被計入了它的帳,但不是它主動發起的檔案讀取。

> **教訓**:如果只停在「找到讀 IO 最高的進程」就下結論,直接把矛頭指向這個進程本身的行為,方向就錯了。正是 `read_bytes ≫ rchar` 這個反常比例,把線索從「某進程在讀檔案」重新指向「這是全局記憶體壓力引發的換頁」,後面幾步只是在補齊證據鏈,不是瞎試。

**第三步,驗證「記憶體換頁」猜想**——`/proc/vmstat` 的回收計數器:

```
workingset_refault_file 31460498   # 頁快取被換出後又被要回來的次數,3100 萬+
pgscan_file  118114504              # 核心掃描檔案頁準備回收的次數
pgsteal_file  91629545              # 實際回收掉的檔案頁次數
pswpin       64547
pswpout      343700
pgmajfault   179888
```

這幾個數字一起說明:**整個宿主機都在經歷大規模的頁快取抖動**,不是某一個進程的孤立問題。

**第四步,找抖動的誘因**——`dmesg` 翻出過去 16 小時 **3 次 OOM Kill**:

```
[Sun Aug 16 21:10:59 2026] Memory cgroup out of memory: Killed process 200526 (java) ...
[Mon Aug 17 02:04:03 2026] Memory cgroup out of memory: Killed process 525702 (trivy) total-vm:4100452kB anon-rss:508436kB file-rss:66316kB ...
[Mon Aug 17 05:39:48 2026] Memory cgroup out of memory: Killed process 272623 (all-in-one-linu) total-vm:1342108kB anon-rss:126032kB file-rss:7588kB ...
```

最後一條發生在**7 小時 25 分鐘前**——和可疑進程 713618 的存活時長精確對上(`ps -o etime` = `07:25:53`)。原來 `all-in-one-linux` 就是被 OOM Kill 後自動重啟的 Jaeger(`jaegertracing/all-in-one` 鏡像裡的執行檔名),它自己也是這場記憶體壓力的受害者,重啟後仍在同一壓力下持續抖動。

**第五步,量化「為什麼記憶體這麼緊」**——`kubectl -n lab-environment` 定位到具體是哪個 pod(容器 ID 反查,`jaeger-7c96c7f5bb-pf7d4`,restart 1 次、7h26m 前,與現場完全吻合),再看它的 resource 設定:

```
$ kubectl -n lab-environment get pod jaeger-... -o jsonpath='{.spec.containers[0].resources}'
{"limits":{"cpu":"100m","memory":"128Mi"},"requests":{"cpu":"25m","memory":"64Mi"}}
```

`limits.memory: 128Mi`,而被 Kill 時 `anon-rss` 是 126032kB——**卡在上限邊緣**,任何一點波動都會被 cgroup OOM killer 打掉。

再看節點整體:

```
$ kubectl describe node instance-20260321-2043 | grep -A6 'Allocated resources'
Resource   Requests      Limits
--------   --------      ------
cpu        2700m (67%)   14775m (369%)
memory     9884Mi (41%)  26570Mi (110%)
```

節點記憶體 **limits 總和是節點容量的 110%**——超賣。`requests` 只有 41%,所以調度器認為這個節點還很寬鬆、還會繼續往上塞新 pod;但如果多個服務的實際用量同時走高(這次就是這樣),真實記憶體被擠爆,核心開始瘋狂換頁,即為本次告警的直接機制。

順手查了 trivy(同批 OOM 記錄裡的另一個受害者):`trivy-operator` 每個掃描 Job 的 `limits.memory` 只設了 **500Mi**,被 Kill 時 `anon-rss(508436kB) + file-rss(66316kB)` 已經超出這個上限,和 jaeger 是同一種「limit 卡得比實際用量緊」的模式,只是它是短生命週期 Job,不會像 jaeger 那樣持續抖動。

## 4. 根因鏈

```
k3s 節點 memory limits 總和超賣至節點容量的 110%
  + 同機還跑著 docker compose 的十來個服務(不計入 k8s 的統計)
  → 多服務並發負載同時升高
    → 真實可用記憶體被擠到只剩 1.1Gi
      → 核心大量回收/換頁 page cache(workingset_refault_file 3100 萬+)
        → jaeger(128Mi limit)、trivy 掃描 Job(500Mi limit)先後被各自 cgroup OOM Kill
          → jaeger 重啟後,新進程仍在同一記憶體壓力下持續抖動(read_bytes≫rchar 的換頁特徵)
            → 大量隨機小 IO(換頁的讀回)推高 IO PSI full
              → 15% 閾值持續 2 分鐘 → io_pressure_critical 觸發
```

一句話:**告警的直接根因是記憶體超賣導致的頁快取抖動;超賣的具體病灶是 jaeger/trivy 這兩個 container 的 memory limit 設得比實際需要緊,一撞上整體負載升高就先後被各自的 cgroup OOM Kill,Kill-重啟循環又反過來加劇了抖動。**

## 5. 處置過程

### 5.1 調高兩處 memory limit

比對「被 Kill 時的實際用量」定出保守夠用的新值,只動 limits,不動 requests(避免順手影響調度器的排程判斷):

| 服務 | 檔案 | 原 limit | 被 Kill 時實際用量 | 新 limit |
|---|---|---|---|---|
| jaeger | `vps_oracle/k3s/apps/lab-environment/k8s/jaeger.yaml` | 128Mi | anon-rss 126MB | **256Mi** |
| trivy 掃描 Job | `vps_oracle/k3s/trivy-operator/values.yaml` | 500Mi | anon+file-rss ~561MB | **768Mi** |

兩個改動分別 commit(`6a0079a`、`a4ff067`)、push 到 `main`。兩個 ArgoCD Application(`lab-environment`、`trivy-operator`)都開了 `automated selfHeal`,源是 GitHub `main`——`kubectl` 直接改會被自動糾正回去,必須走 git。push 後手動 `annotate argocd.argoproj.io/refresh=hard` 觸發立即同步(不等預設輪詢週期),確認 jaeger 新 pod(`jaeger-56d969489b-7hcbq`)以新 limit 重啟並 `Running`,兩個 Application 都回到 `Synced`/`Healthy`。

處置後複查:

```
$ cat /proc/pressure/io
some avg10=0.00 avg60=0.79 avg300=13.37
full avg10=0.00 avg60=0.62 avg300=11.37
```

`avg10` 直接歸零,`avg300` 是之前高點的窗口衰減尾巴,持續觀察後也降到個位數。

### 5.2 補巡檢缺口:新增 `k3s-oom-killed-containers.sh`

事後盤點 `vps_oracle/inspector/` 現有 15 個 check,發現**沒有一個能定位到「哪個具體 container 被 OOM Kill」**:

- `k3s-evicted-pods.sh` 只抓 `phase=Failed` 的殘留 pod——jaeger/trivy 被 OOM Kill 後 pod 全程停留 `Running`(只是 container 重啟),從未進入 `Failed`,完全不在這個 check 的偵測範圍。
- `docker-restart-storms.sh` 只查宿主機上的 **docker compose** 容器,不碰 k3s pod;而且閾值是重啟 ≥10 次才算「風暴」,這次 jaeger 只重啟 1 次。
- Grafana 的 PSI/記憶體類規則能看到「資源在惡化」的聚合訊號,但看不到「是哪個具體 pod 被誰 OOM 殺的」這種根因層級的歸因。

新增的 check 讀 `containerStatuses[].lastState.terminated.reason == "OOMKilled"`,回看窗口 24 小時(覆蓋每天兩次的巡檢間隔,即使漏跑一次也不會錯過),`alert` 只告警不自動處理(該不該調 limit 是人的判斷)。6 個測試用例(命中 / 超出窗口 / 非 OOM 原因 / 從未重啟過的容器 / 自訂窗口 / kubeconfig 缺失兜底)全過,對著真實叢集跑過一次 dry-run 驗證無誤判。commit `a0664b4`,同時更新了 `vps_oracle/inspector/README.md` 與 `docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md` 的「只告警」表格。

### 5.3 收尾插曲:`io_pressure_warning` 誤報

事件收尾約 40 分鐘後,又收到一則:

```
IO PSI 'some' above 20% for 3 minutes on vps_oracle (processes waiting on IO)
```

複查 `/proc/pressure/io` 發現已經自行恢復(`some avg10=0`),`MemFree` 也回升到 2.6G+。分析:`some` 只要「至少一個任務在等 IO」就會被推高,門檻遠比 `full`(全體非閒置任務同時卡住)低得多——任何幾個容器湊巧同時做點 IO(ArgoCD reconcile、日誌輪替、trivy 掃描、docker healthcheck 寫檔……)都能讓它短暫越過 20%,3 分鐘後自己回落,這次很可能就是主事件收尾的餘波(新 jaeger pod 預熱、記憶體正在回填 page cache),不是新問題。

調整方向:只拉長 `for`(3m → 10m),閾值 20% 不動——這次的問題是「持續時間」而非「幅度」,拉長確認窗口直接針對「偶發短暫並發 IO」這種噪音模式,同時保留對真正持續性惡化趨勢的偵測能力(真實事故的 `full` 曾持續超過 10 分鐘以上,拉長後不影響及時發現)。改 `vps_oracle/compose/monitoring/grafana/provisioning/alerting/host-metrics-rules.yml`,commit `233cb5c` push 到 main,`docker compose restart grafana` 讓 provisioning 重新載入(bind mount 的檔案改動不會被 `docker compose up -d` 自動感知),日誌確認 `finished to provision alerting` 無錯誤。

## 6. 結果(前後對比)

| 指標 | 事發時 | 處置後 |
|---|---|---|
| IO PSI full avg10 | 24.97%(持續中,`avg300` 同樣 ~22%) | **0%** |
| MemFree | 1.1Gi(其間一度探底到 756Mi) | **2.6G+**,持續回升 |
| jaeger container | 128Mi limit,已被 OOM Kill 1 次、重啟後持續抖動 | 256Mi limit,新 pod 正常 Running |
| trivy 掃描 Job | 500Mi limit,曾被 OOM Kill | 768Mi limit |
| 巡檢對「container 被 OOM Kill」的覆蓋 | 無(15 個 check 均未覆蓋) | 新增 `k3s-oom-killed-containers.sh`,alert 分級 |
| `io_pressure_warning` | `for: 3m`,對短暫並發 IO 敏感 | `for: 10m`,過濾偶發噪音 |

## 7. 遺留 / 後續

- **節點記憶體 110% 超賣本身沒有解決**,這次只是止住 jaeger/trivy 這兩個具體症狀。如果之後其他服務的負載也一起走高,同樣的 page cache 抖動、IO PSI 飆高可能再次發生,下次不一定還是這兩個 container。
- **`lab-environment` 命名空間是後續瘦身的候選**:這是一整套 spring-petclinic 風格的微服務演示環境(consul/jaeger/loki/prometheus/promtail/grafana/postgres/redis + 4 個業務服務),事發時才部署 15 小時,配置的 memory limits 加總最大,且和宿主機上已有的 docker compose 版 grafana/prometheus 功能重複。若非長期需要,縮容能顯著降低超賣比例。
- **`cilium-operator` 有 10 次重啟(`reason=Error`,非 OOM)**,巡檢目前也沒有覆蓋 k3s 層級的「重啟風暴」偵測(`docker-restart-storms.sh` 只看宿主機 docker 容器)——本次沒有深入排查,記錄下來供之後評估是否要補一個 k3s 版的重啟風暴 check。
- Grafana 規則調整只解決了「單次孤立尖峰的噪音」,`some` 指標本身仍然是個低信噪比的訊號;如果之後想做更精準的早期預警,`some` 與記憶體趨勢(`memory_pressure_critical`、`memory_exhaustion_predicted_warning`)疊加判斷會比單獨看 `some` 更可靠——但這需要 Grafana 複合條件查詢,目前評估認為分開兩條獨立規則已經隱含達到同樣效果(真正惡化時兩條會前後腳觸發),暫不加複雜度。

## 8. 附:複用命令

```bash
# PSI 現況與 5 分鐘歷史(avg300 是「過去 5 分鐘發生過什麼」的免費歷史)
cat /proc/pressure/{cpu,memory,io}

# 讀寫方向判斷
vmstat 1 5   # 看 bi(讀)/bo(寫)/wa(io wait)

# 找出誰在讀/寫(需要 sudo 才能看到非本使用者的進程)
sudo python3 - <<'EOF'
import os, time
def read_io():
    out = {}
    for pid in os.listdir('/proc'):
        if not pid.isdigit(): continue
        try:
            with open(f'/proc/{pid}/io') as f: data = f.read()
            with open(f'/proc/{pid}/comm') as f: comm = f.read().strip()
            d = {k.strip(): int(v) for k, v in
                 (line.split(':') for line in data.splitlines())}
            out[pid] = (comm, d.get('read_bytes', 0), d.get('write_bytes', 0))
        except Exception: continue
    return out
before = read_io(); time.sleep(2); after = read_io()
deltas = sorted(
    ((r2 - r1 + w2 - w1, pid, comm, r2 - r1, w2 - w1)
     for pid, (comm, r2, w2) in after.items()
     if pid in before for _, r1, w1 in [before[pid]]),
    reverse=True)
for total, pid, comm, r, w in deltas[:20]:
    if total: print(f"{pid:>7} {comm:<20} read={r/2/1024:.1f}K/s write={w/2/1024:.1f}K/s")
EOF

# 判斷「讀 IO 是不是真的在讀檔案」——關鍵訣竅:比對 rchar 與 read_bytes
sudo cat /proc/<pid>/io   # rchar≪read_bytes 通常代表換頁/refault,不是主動讀檔
sudo ls -la /proc/<pid>/fd     # 有沒有指向磁碟檔案的 fd
sudo cat /proc/<pid>/maps      # 有沒有檔案映射(mmap 可能不留 fd)

# 記憶體回收/換頁計數器(全局抖動的證據)
grep -E 'workingset_refault|pgscan_file|pgsteal_file|pswpin|pswpout|pgmajfault' /proc/vmstat

# OOM Kill 歷史
sudo dmesg -T | grep -iE 'oom|killed process'

# 反查某個容器 ID 屬於哪個 k3s pod
kubectl get pods -A -o json | jq -r '.items[] |
  select(.status.containerStatuses[]?.containerID | contains("<container_id片段>")) |
  .metadata.namespace + "/" + .metadata.name'

# 節點記憶體超賣比例
kubectl describe node <node> | grep -A6 'Allocated resources'

# ArgoCD 立即觸發同步(不等預設輪詢週期)
kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite

# Grafana provisioning 改動後生效(bind mount 檔案改動不會被 `docker compose up -d` 自動感知)
docker compose restart grafana
docker logs grafana --tail 200 | grep -iE 'provisioning.alerting'   # 找 "finished to provision alerting"
```
