# Incident: VS Code remote session accumulation triggers a server resource spike

Date: 2026-08-15
Status: resolved (stock cleanup + added swap; the upstream trigger — the extension+ccr stall bug — was fixed by the previous day's sse-coalesce fix)
Related record: [2026-08-15-ccr-vscode-extension-stall.md](2026-08-15-ccr-vscode-extension-stall.md) (locating and fixing the upstream trigger)
Environment: Oracle VPS, 4-core ARM (aarch64) / 23.4 GB RAM, **no swap at the time of the incident**; same machine runs k3s, llama.cpp (llama-server), about 10 compose stacks, and multiple Java services
This record: captures the on-scene data, investigation chain, causal analysis, and handling process (including detours and misjudgments) in full, for reuse and writing.

---

## 1. Symptoms

11:09 user reported: server CPU near 100%, memory nearly exhausted.

## 2. On-scene snapshot (11:09–11:11 raw output)

### 2.1 Load and memory

```
 11:09:54 up 18 days, 12:46,  5 users,  load average: 11.08, 38.69, 23.59
               total        used        free      shared  buff/cache   available
Mem:            23Gi        20Gi       202Mi        72Mi       3.0Gi       2.8Gi
Swap:             0B          0B          0B
```

Key reading: the machine has only **4 cores**, and the 5-minute average load of 38.69 ≈ 10x overcommit; the 1-minute average of 11.08 → **the peak has passed and is falling**. Memory 20/23 Gi, no swap at all.

### 2.2 Kernel pressure (PSI) — direct evidence for locating the "IO storm"

```
cpu:    some avg10=5.34 avg60=7.36  avg300=8.66
memory: some avg10=0.14 avg60=1.50  avg300=13.23   full avg10=0.10 avg60=1.12 avg300=10.06
io:     some avg10=20.99 avg60=24.79 avg300=45.24  full avg10=17.60 avg60=19.06 avg300=31.92
```

Over the past 5 minutes: **memory full 10%** (real memory stalled, kernel hard-reclaiming) + **io some 45% / full 32%** (severe IO congestion). Concurrently ps caught multiple **D-state** (uninterruptible IO wait) processes: runc, node healthcheck (51% CPU) — **D-state processes count toward load average, and this is the direct mechanism by which load surged to 38**.

### 2.3 Ruled-out items

- `dmesg` / `journalctl -k`: no OOM kill records (the kernel had not started killing processes yet);
- `docker stats --no-stream`: ccr 315 MiB, all other containers <500 MiB, CPU in single digits → **no container-level anomaly**, ruling out the compose stacks;
- `df -h /`: 65%, 70 G remaining → ruled out disk full.

### 2.4 Process layer: the real direction

Top processes sorted by memory:

```
root    2070161  15.8%  3.9G  /llm/llama-server … Hermes-3-Llama-3.2-3B.Q4_K_M   ← steady, normal
root     572152   4.6%  1.1G  /usr/local/bin/k3s server                          ← steady
ubuntu   229131   2.9%  734M  vscode-server … bootstrap-fork --type=extensionHost ← suspicious
ubuntu   221044   2.9%  719M  vscode-server … bootstrap-fork --type=extensionHost ← suspicious (since 11:02, 33% CPU)
root     2059964   2.8%  691M  python3 -m uvicorn open_webui.main:app            ← steady
ubuntu   3177808   2.6%  642M  vscode-server … bootstrap-fork --type=extensionHost ← suspicious (since Aug 14!)
ubuntu    63027   2.4%  594M  vscode-server … bootstrap-fork (another, since 08:26)   ← suspicious
… 5 Java processes 454–528M (steady), pylance 508M, claude(pts/2)505M …
```

Grouped summary:

```
vscode-server: 59 processes, 7.3 GB
claude:        1 process, 0.5 GB (another 6 under the vscode-server tree not counted)
java:          7 processes, 2.3 GB
```

**59 VS Code processes, 7.3 GB** — the steady big consumers (llama 3.9G, k3s 1.1G, java 2.3G) are all normal; the elasticity anomaly is the VS Code sessions.

### 2.5 servers directory

Under `~/.vscode-server/cli/servers/` there are **6 version directories** (Stable-\<commit\>, each 570–656 MB, ~3.8 G total), and `lru.json` records the most-recently-used order (where 8761a5560 is no longer in the lru list).

## 3. Process-tree mapping (the core step of the investigation)

Structure reconstructed after checking PPIDs one by one:

```
Stable-1b6a188 server (started Aug 9 13:34, sh code-server parent process=1, detached from the SSH session)
3707128 → 3707132 (server-main)
├── 3707940 pty host + terminal bash shells
│   └── pts/2 bash(3267223)→ claude 3743504 (since Aug 15 00:21, has burned 7 min CPU) = the terminal session used for the stall-fix investigation
├── 3177808 extension host (since Aug 14 15:17, "old window")★ lingering tree, 17 processes ~3.2G:
│   ├── claude 3180047 (Aug 14 15:18, cwd=~/jerome/plans, 7:06 CPU)← this is the stalled session recorded in stall-fix doc §2.1!
│   ├── claude 3878706 / 3879175 / 3884757 / 3887322 (Aug 15 02:04–02:11, cwd all ~/jerome/plans)← 4 spawned by retries
│   ├── codex 3178556, tsserver/pylance etc. node ×8, pet server
└── 229131 extension host (since Aug 15 11:08, "window of this session")← kept

Stable-df53daab server (started Aug 15 08:26, another device / another version's window)
62624 → 62628 (server-main) → exthost 63027 → claude 66108(cwd=~/bridget/love-bird-op) etc. 13 processes ~1.5G

Also: code CLI agent host (PID 1922, since Jul 27, infrastructure), command-shell ×2 (10:59, 11:06)
```

**Key finding: this session's window and the Aug 14 old window share the same server process started Aug 9** — so when cleaning up, never kill the server itself, only kill the old window's extension host tree. The VS Code Remote-SSH model: one server-main (per client commit) can serve multiple windows, one exthost per window.

## 4. Timeline reconstruction

**Accumulation phase (~20 hours, gradual, unnoticed)**:
- Aug 14 15:17 old window connects; from 15:18 claude 3180047 lingers due to the "extension+ccr per-token SSE stall" (see stall-fix doc);
- Aug 15 00:21 terminal opens an investigation session (3743504); 02:04–02:11 the user retries repeatedly, spawning 4 more claude — **each retry = a new process, old processes don't exit**;
- 08:26 another device connects (love-bird-op window).

**Ignition phase (11 minutes)**:
- 10:59:30 command-shell 217768 (new connection);
- 11:02 exthost 221044 starts (33% CPU, 719 MB; exits on its own later) — the Pylance/tsserver/Copilot family startup is a big CPU+IO consumer;
- 11:06:56 another window's command-shell 225751 reconnects;
- 11:08:44 two new exthosts (a5b5009 temporary server — with `--enable-remote-auto-shutdown`, exits on its own when the connection drops; + this session's 229131);
- 11:09:08 Pylance 231799 starts → **the load peak window (5-minute average 38.69) exactly covers 11:00–11:09**.

## 5. Root-cause chain

```
third-party provider per-token SSE (one delta event per token)
 → extension can't consume it fast enough (JSON parse + postMessage over SSH + full re-render of the long session)
 → claude process stuck on stdout write, session doesn't exit                    ← the stall-fix doc's problem (trigger, fixed the day before)
   → the stuck claude drags the entire exthost tree along so it never dies (17 processes/3.2G)
   → user sees "stall" → reopens a window to retry → old tree lingers, new tree stacks    ← the accumulation engine
     + Remote-SSH server detached from session (ppid=1), lives forever
     + client upgraded multiple times → 6 server version directories coexist (3.8G disk)
       → memory slowly climbs to 85%+ over 20 hours
         → 11:00–11:09 multiple windows reconnect and start language servers simultaneously
           → memory bottoms out and no swap → kernel hard-reclaims page cache → IO storm (PSI io some 45%)
             → many processes stuck in D state → load 38.7                       ← the spike the user saw
```

In one sentence: **the direct root cause of the spike is an IO storm triggered by memory exhaustion on a machine with no swap; the root cause of the memory exhaustion is the VS Code session accumulation caused by the stall bug.** The two records (stall-fix and this one) are the upstream and downstream of the same causal chain — the largest lingering tree killed during this cleanup is exactly the stalled session recorded in the stall-fix doc (PID 3180047 / exthost 3177808) itself.

Layered look at why all defenses failed:
1. Trigger layer: the stall bug (already fixed by sse-coalesce, event rate dropped 1-2 orders of magnitude);
2. Accumulation layer: server lives forever + old clients don't carry auto-shutdown + the reasonable response of "reopen a window" becomes a duplicator;
3. Buffer layer: no swap, memory alerts (80/90) respond too late to gradual accumulation;
4. Capacity layer: running k3s + llama.cpp (3.9G) + 7 Java + 10 compose stacks on 4 cores / 23G, steady-state already ~15G, leaving little headroom for elastic sessions.

## 6. Handling process (with detours, recorded as-is)

### 6.1 Killing processes (11:16)

Keep list: this session's full chain (3707128→3707132→229131→231900), the shared pty host, pts/2's bash, fileWatcher 3177865 (shared tool process, 41M), agent host 1922, command-shell 217768.
Kill list: pts/2 claude 3743504; the old window's exthost 3177808 whole tree (15 processes); the entire df53daab server tree (13 processes); its command-shell 225751; two idle bash shells.

Method: recursively collect descendants (`desc()` function) → verify each root PID's identity first (against PID reuse misfire) → TERM all → after 4 seconds, KILL survivors (two bash need it) → verify the kill list has no intersection with one's own process chain (self-protection, abort on intersection). Result: 59 → 19 VS Code processes.

### 6.2 Adding 4G swap (11:22)

```
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

Effect immediate: available 2.8G → 8.2G (memory released + page cache no longer forcibly reclaimed).

### 6.3 Cleaning the servers directory (11:26)

Kept the in-use 1b6a188 (570M), deleted the other 5 version directories, reclaimed ~3.2G disk.

### 6.4 Detour 1: the in-use check's self-match bug

The "confirm no process references" check before deleting directories was written as `ps -eo args | grep -oE 'Stable-…'` — **ps's output contains my own bash command's command line** (which carries 5 directory names), so all were misjudged as "in use"; found and fixed it by excluding one's own process chain and re-checking — and the corrected ps syntax was wrong once more (`ps -e PID` is invalid syntax, making the check pass on nothing and the directories still deleted). **Immediately afterwards fully re-verified the remaining processes: all 19+3 hang on the kept 1b6a188, no misfire.** Lesson: any check that "greps the process list and then acts on the result" must exclude the checker itself.

### 6.5 Detour 2: automatic reconnect of what was killed (whack-a-mole)

11:28:35, the killed device (df53daab client) **auto-reconnected**: command-shell 252499 → sh code-server → server-main 252554, and because the servers directory had already been deleted, **the CLI re-downloaded a copy on the spot** (~600M); 11:29:18 the old window (same commit) also re-created a new exthost 253578 on the shared server (later exited on its own). Killed the 252499 tree again, observed 4 minutes with no further reconnect, and the re-downloaded directory was cleaned up as the process died.

Conclusion: **as long as the desktop window is not closed, the server will respawn no matter how many times you kill it server-side**; handling this kind of problem must pair "server-side cleanup + client-side window closing".

## 7. Results (before/after)

| Metric | At incident (11:09) | After handling (11:33) |
|---|---|---|
| load 1min | 11.1 (5min peak 38.7) | **0.68** |
| memory used / available | 20Gi / 2.8G | **15Gi / 8.2G** |
| swap | none | **4G (fstab persistent)** |
| IO PSI some (10s/5min) | 21% / 45% | **0.01% / 2.1%** |
| VS Code processes | 59 / 7.3G | **14** (this session's chain only) |
| servers directory | 6 versions / 3.8G | 1 version / 570M |

## 8. Remaining / follow-up

- **Verify sse-coalesce is in effect** (the final judgment): over the next few days observe whether extension sessions show finished on time and processes exit normally (transcript ends with a `result` line); retest per stall doc §6 once the Zhipu quota recovers.
- Keep clients updated: observed that the server pulled up by a new client carries `--enable-remote-auto-shutdown` (exits on its own after disconnect), while older versions (like Aug 9's 1b6a188) do not — upgrading can eliminate the "server lives forever" layer.
- Alerting (handled, see `vps_oracle/compose/monitoring/grafana/provisioning/alerting/host-metrics-rules.yml`): added PSI (io/memory pressure), D-state blocked-process count (`node_procs_blocked > 3`), swap usage and "swap disappearance", plus `predict_linear` memory-trend prediction, 7 rules in total — all four categories are zero infra change (node-exporter's existing metrics already have the data), replacing the originally-conceived "vscode-server process count > 20" app-specific metric with generic signals; the latter requires an extra host cron script + textfile collector + node-exporter mount/flag changes, so it was deferred after evaluation.
- Upstream feedback: the extension should not let slow UI rendering stall the protocol channel (already listed in the stall-fix doc §7).
- Usage habits: close the window when the session ends; on a stall, close the window first, then reopen (should not stall again after the fix).

## 9. Appendix: reusable commands

```bash
# load / memory / kernel pressure (PSI's avg300 is the free history of "what happened in the past 5 minutes")
uptime; free -h; cat /proc/pressure/{cpu,memory,io}

# recursively collect all descendants of a process
desc() { local pids="$1" new; while :; do
  new=$(ps -eo pid,ppid --no-headers | awk -v s="$pids" 'BEGIN{split(s,a," ");for(i in a)S[a[i]]} $2 in S && !($1 in S){print $1}')
  [ -z "$new" ] && break; pids="$pids $new"; done; echo $pids; }
# usage: kill -TERM $(desc <root_pid>); after a few seconds, KILL the survivors
# note: ① verify the root PID's identity (cmdline) before killing, against PID reuse; ② verify no intersection with one's own process chain before killing the tree

# check whether a server version is referenced by a process (must exclude the checker's own process chain, otherwise self-match)
ps -eo pid,ppid,args --no-headers | awk -v e="<one's own pid chain csv>" 'BEGIN{split(e,a,",");for(i in a)X[a[i]]=1} !($1 in X)' \
  | grep -oE 'Stable-[0-9a-f]{40}' | sort -u

# 4G swap
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile

# process-group memory stats
ps -eo rss,args --no-headers | awk '/vscode-server/{v+=$1;n++} END{printf "%d procs %.1fGB\n",n,v/1048576}'
```