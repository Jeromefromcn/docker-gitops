# 事故記錄:VS Code 遠程會話堆積引發服務器資源尖峰

日期:2026-08-15
狀態:已解決(存量清理 + 加 swap;上游觸發器——擴展+ccr 卡死 bug——由前一天的 sse-coalesce 修復解決)
關聯文檔:[2026-08-15-ccr-vscode-extension-stall.md](2026-08-15-ccr-vscode-extension-stall.md)(上游觸發器的定位與修復記錄)
環境:Oracle VPS,4 核 ARM(aarch64)/ 23.4 GB RAM,**事發時完全無 swap**;同機跑 k3s、llama.cpp(llama-server)、約 10 個 compose 棧、多個 Java 服務
本文檔:完整記錄現場數據、排查鏈、因果分析、處置過程(含插曲與誤判),供複用與寫作。

---

## 1. 現象

11:09 用戶回報:服務器 CPU 接近 100%,內存所剩無幾。

## 2. 現場快照(11:09–11:11 原始輸出)

### 2.1 負載與內存

```
 11:09:54 up 18 days, 12:46,  5 users,  load average: 11.08, 38.69, 23.59
               total        used        free      shared  buff/cache   available
Mem:            23Gi        20Gi       202Mi        72Mi       3.0Gi       2.8Gi
Swap:             0B          0B          0B
```

關鍵判讀:機器只有 **4 核**,5 分鐘平均負載 38.69 ≈ 超載 10 倍;1 分鐘均值 11.08 → **峰值已過,正在回落**。內存 20/23 Gi,無任何 swap。

### 2.2 內核壓力(PSI)——定位「IO 風暴」的直接證據

```
cpu:    some avg10=5.34 avg60=7.36  avg300=8.66
memory: some avg10=0.14 avg60=1.50  avg300=13.23   full avg10=0.10 avg60=1.12 avg300=10.06
io:     some avg10=20.99 avg60=24.79 avg300=45.24  full avg10=17.60 avg60=19.06 avg300=31.92
```

過去 5 分鐘:**memory full 10%**(真實內存停滯、內核在硬回收)+ **io some 45% / full 32%**(嚴重 IO 擁堵)。同期 ps 抓到多個 **D 狀態**(不可中斷 IO 等待)進程:runc、node healthcheck(51% CPU)——**D 狀態進程計入 load average,這就是負載衝上 38 的直接機制**。

### 2.3 排除項

- `dmesg` / `journalctl -k`:無 OOM kill 記錄(內核還沒開始殺進程);
- `docker stats --no-stream`:ccr 315 MiB、其餘容器均 <500 MiB、CPU 個位數 → **容器層無異常**,排除 compose 棧;
- `df -h /`:65%、餘 70 G → 排除磁盤滿。

### 2.4 進程層:真正的方向

按內存排序的頭部:

```
root    2070161  15.8%  3.9G  /llm/llama-server … Hermes-3-Llama-3.2-3B.Q4_K_M   ← 穩態,屬正常
root     572152   4.6%  1.1G  /usr/local/bin/k3s server                          ← 穩態
ubuntu   229131   2.9%  734M  vscode-server … bootstrap-fork --type=extensionHost ← 疑點
ubuntu   221044   2.9%  719M  vscode-server … bootstrap-fork --type=extensionHost ← 疑點(11:02 起,33% CPU)
root     2059964   2.8%  691M  python3 -m uvicorn open_webui.main:app            ← 穩態
ubuntu   3177808   2.6%  642M  vscode-server … bootstrap-fork --type=extensionHost ← 疑點(Aug 14 起!)
ubuntu    63027   2.4%  594M  vscode-server … bootstrap-fork(另一個,08:26 起)   ← 疑點
… 5 個 Java 進程 454–528M(穩態)、pylance 508M、claude(pts/2)505M …
```

分組統計:

```
vscode-server: 59 個進程, 7.3 GB
claude:        1 個進程, 0.5 GB(另有 6 個掛在 vscode-server 樹下未計入)
java:          7 個進程, 2.3 GB
```

**59 個 VS Code 進程、7.3 GB**——穩態大頭(llama 3.9G、k3s 1.1G、java 2.3G)都正常,彈性異常的是 VS Code 會話。

### 2.5 servers 目錄

`~/.vscode-server/cli/servers/` 下 **6 個版本目錄**(Stable-\<commit\>,每個 570–656 MB,共 ~3.8 G),`lru.json` 記錄最近使用順序(其中 8761a5560 已不在 lru 列表)。

## 3. 進程樹映射(排查的核心一步)

逐一核對 PPID 後還原出的結構:

```
Stable-1b6a188 server(Aug 9 13:34 啟動,sh code-server 父進程=1,已脫離 SSH 會話)
3707128 → 3707132 (server-main)
├── 3707940 pty host + 終端 bash 們
│   └── pts/2 bash(3267223)→ claude 3743504(Aug 15 00:21 起,已燒 7 分 CPU)= stall-fix 排查用的終端會話
├── 3177808 extension host(Aug 14 15:17 起,「舊窗口」)★ 滯留樹,17 個進程 ~3.2G:
│   ├── claude 3180047(Aug 14 15:18,cwd=~/jerome/plans,7:06 CPU)← 就是 stall-fix 文檔 §2.1 記錄的那個卡死會話!
│   ├── claude 3878706 / 3879175 / 3884757 / 3887322(Aug 15 02:04–02:11,cwd 全是 ~/jerome/plans)← 重試再生的 4 個
│   ├── codex 3178556、tsserver/pylance 等 node ×8、pet server
└── 229131 extension host(Aug 15 11:08 起,「本次會話所在窗口」)← 保留

Stable-df53daab server(Aug 15 08:26 啟動,另一台設備/另一版本的窗口)
62624 → 62628 (server-main) → exthost 63027 → claude 66108(cwd=~/bridget/love-bird-op)等 13 個進程 ~1.5G

另:code CLI agent host(PID 1922,Jul 27 起,基礎設施)、command-shell ×2(10:59、11:06)
```

**關鍵發現:本次會話的窗口和 Aug 14 的舊窗口共用同一個 Aug 9 啟動的 server 進程**——所以清理時絕不能殺 server 本身,只能殺舊窗口的 extension host 樹。VS Code Remote-SSH 的模型:一個 server-main(按客戶端 commit 分)可服務多個窗口,每窗口一個 exthost。

## 4. 時間線重建

**積累期(~20 小時,漸進,無人察覺)**:
- Aug 14 15:17 舊窗口連入;15:18 起 claude 3180047 因「擴展+ccr 逐 token SSE 卡死」滯留(見 stall-fix 文檔);
- Aug 15 00:21 終端開排查會話(3743504);02:04–02:11 用戶反覆重試,再生 4 個 claude——**每次重試 = 新進程,舊進程不退**;
- 08:26 另一台設備連入(love-bird-op 窗口)。

**點火期(11 分鐘)**:
- 10:59:30 command-shell 217768(新連接);
- 11:02 exthost 221044 啟動(33% CPU、719 MB;後自行退出)——Pylance/tsserver/Copilot 全家啟動是 CPU+IO 大戶;
- 11:06:56 另一窗口 command-shell 225751 重連;
- 11:08:44 兩個新 exthost(a5b5009 臨時 server——帶 `--enable-remote-auto-shutdown`,連接斷後自行退出;+ 本次會話的 229131);
- 11:09:08 Pylance 231799 啟動 → **負載峰值窗口(5 分鐘均值 38.69)正好覆蓋 11:00–11:09**。

## 5. 根因鏈

```
第三方 provider 逐 token SSE(每 token 一個 delta 事件)
 → 擴展消費不過來(JSON parse + postMessage 過 SSH + 長會話整段重渲染)
 → claude 進程卡在 stdout 寫入、會話不退出                    ← stall-fix 文檔的問題(觸發器,前一天已修)
   → 卡住的 claude 拖著 exthost 整樹不死(17 進程/3.2G)
   → 用戶看到「卡死」→ 重開窗口重試 → 舊樹滯留、新樹疊加        ← 積累引擎
     + Remote-SSH server 脫離會話(ppid=1)永久存活
     + 客戶端多次升級 → 6 個 server 版本目錄並存(3.8G 磁盤)
       → 內存 20 小時內慢慢吃到 85%+
         → 11:00–11:09 多窗口重連同時啟動語言服務器
           → 內存見底且無 swap → 內核硬回收 page cache → IO 風暴(PSI io some 45%)
             → 大量進程卡 D 狀態 → 負載 38.7                     ← 用戶看到的尖峰
```

一句話:**尖峰的直接根因是無 swap 的機器上內存耗盡引發 IO 風暴;內存耗盡的根因是卡死 bug 造成的 VS Code 會話堆積。** 兩份記錄(stall-fix 與本文)是同一條因果鏈的上下游——本次清理時殺掉的最大滯留樹,正是 stall-fix 文檔裡記錄的那個卡死會話(PID 3180047 / exthost 3177808)本身。

分層看防線為什麼全失守:
1. 觸發層:卡死 bug(已由 sse-coalesce 修復,事件率降 1–2 個數量級);
2. 積累層:server 永活 + 舊客戶端不帶 auto-shutdown + 「重開窗口」的合理應對變成複製器;
3. 緩衝層:無 swap、內存告警(80/90)對漸進堆積反應太晚;
4. 容量層:4 核 23G 上同時跑 k3s + llama.cpp(3.9G)+ 7 個 Java + 10 個 compose 棧,穩態已 ~15G,留給彈性會話的餘量本就小。

## 6. 處置過程(含插曲,如實記錄)

### 6.1 殺進程(11:16)

保留清單:本次會話全鏈路(3707128→3707132→229131→231900)、共享 pty host、pts/2 的 bash、fileWatcher 3177865(共享工具進程,41M)、agent host 1922、command-shell 217768。
殺掉清單:pts/2 claude 3743504;舊窗口 exthost 3177808 全樹(15 進程);df53daab 整棵 server 樹(13 進程);其 command-shell 225751;兩個空閒 bash。

方法:遞歸收集後代(`desc()` 函數)→ 每個根 PID 先核對身份(防 PID 複用誤殺)→ 全部 TERM → 4 秒後對倖存者補 KILL(兩個 bash 需要)→ 校驗殺掉名單與自身進程鏈無交集(自保護,有交集即中止)。結果:59 → 19 個 VS Code 進程。

### 6.2 加 4G swap(11:22)

```
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

效果立竿見影:available 2.8G → 8.2G(內存釋放 + page cache 不再被硬搶)。

### 6.3 清理 servers 目錄(11:26)

保留正在使用的 1b6a188(570M),刪除其餘 5 個版本目錄,回收 ~3.2G 磁盤。

### 6.4 插曲一:in-use 檢查的自匹配 bug

刪目錄前的「確認無進程引用」檢查寫成 `ps -eo args | grep -oE 'Stable-…'`——**ps 的輸出裡包含了我自己這條 bash 命令的命令行**(裡面帶著 5 個目錄名),於是全部被誤判「在使用」;發現後修正,排除自身進程鏈重查——修正後的 ps 語法又錯了一次(`ps -e PID` 無效語法導致檢查空過、目錄照刪)。**事後立即完整核對剩餘進程:19+3 個全部掛在保留的 1b6a188 上,無誤傷。** 教訓:凡是「grep 進程列表再據此採取行動」的檢查,必須排除檢查者自身。

### 6.5 插曲二:殺掉的自動重連(whack-a-mole)

11:28:35,被殺的那台設備(df53daab 客戶端)**自動重連**:command-shell 252499 → sh code-server → server-main 252554,且因 servers 目錄已被刪,**CLI 現場重新下載了一份**(~600M);11:29:18 舊窗口(commit 相同)也向共享 server 重連出一個新 exthost 253578(後自行退出)。再次殺掉 252499 樹,觀察 4 分鐘無再重連,重下載的目錄隨進程死亡已清理。
結論:**桌面端窗口不關,服務端殺多少次都會重生**;處置這類問題必須「服務端清理 + 客戶端關窗」兩頭配合。

## 7. 結果(前後對比)

| 指標 | 事發時(11:09) | 處置後(11:33) |
|---|---|---|
| 負載 1min | 11.1(5min 峰值 38.7) | **0.68** |
| 內存 used / available | 20Gi / 2.8G | **15Gi / 8.2G** |
| swap | 無 | **4G(fstab 持久)** |
| IO PSI some(10s/5min) | 21% / 45% | **0.01% / 2.1%** |
| VS Code 進程 | 59 個 / 7.3G | **14 個**(僅本次會話鏈路) |
| servers 目錄 | 6 版本 / 3.8G | 1 版本 / 570M |

## 8. 遺留 / 後續

- **驗證 sse-coalesce 生效**(最終判據):今後幾天觀察擴展會話是否準時顯示結束、進程正常退出(transcript 末尾出現 `result` 行);Zhipu 配額恢復後按 stall 文檔 §6 復測;
- 客戶端保持更新:觀察到新版客戶端拉起的 server 自帶 `--enable-remote-auto-shutdown`(斷連後自行退出),舊版(如 Aug 9 的 1b6a188)無此行為——升級可消掉「server 永活」這層;
- 可選告警:node-exporter 基礎上加「vscode-server 進程數 > 20 或 extension host > 2」的檢查,比內存 80% 告警更早發現堆積;
- 上游反饋:擴展不應讓 UI 渲染慢拖死協議通道(stall-fix 文檔 §7 已列);
- 使用習慣:會話結束關窗口;遇卡死先關窗再重開(修復後不應再卡)。

## 9. 附:複用命令

```bash
# 負載/內存/內核壓力(PSI 的 avg300 是「過去 5 分鐘發生過什麼」的免費歷史)
uptime; free -h; cat /proc/pressure/{cpu,memory,io}

# 遞歸收集某進程的全部後代
desc() { local pids="$1" new; while :; do
  new=$(ps -eo pid,ppid --no-headers | awk -v s="$pids" 'BEGIN{split(s,a," ");for(i in a)S[a[i]]} $2 in S && !($1 in S){print $1}')
  [ -z "$new" ] && break; pids="$pids $new"; done; echo $pids; }
# 用法:kill -TERM $(desc <root_pid>);數秒後對倖存者補 KILL
# 注意:①殺前核對根 PID 身份(cmdline),防 PID 複用;②殺樹前校驗與自身進程鏈無交集

# 查 server 版本是否被進程引用(務必排除檢查者自身的進程鏈,否則自匹配)
ps -eo pid,ppid,args --no-headers | awk -v e="<自己的pid鏈csv>" 'BEGIN{split(e,a,",");for(i in a)X[a[i]]=1} !($1 in X)' \
  | grep -oE 'Stable-[0-9a-f]{40}' | sort -u

# 4G swap
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile

# 進程分組內存統計
ps -eo rss,args --no-headers | awk '/vscode-server/{v+=$1;n++} END{printf "%d procs %.1fGB\n",n,v/1048576}'
```
