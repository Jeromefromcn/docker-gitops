# Incident: k3s memory overcommit triggers an IO PSI alert (jaeger / trivy OOM-killed)

Date: 2026-08-17
Status: resolved (raised two container memory limits; added an inspector check to fill the detection gap; loosened the `io_pressure_warning` alert window to reduce noise)
Environment: Oracle VPS, 4-core ARM (aarch64) / 23.4 GB RAM, 4G swap (added after the 2026-08-15 incident); same machine mixes docker compose (grafana/prometheus/npm/portainer/ccr/switchboard/plans/3x-ui etc.) and k3s (argocd/dify/headlamp/cilium/kyverno/lab-environment/llm/workloads/trivy-system/sealed-secrets, 9+ namespaces, ~50 pods)
Related record: [2026-08-15-vscode-sessions-resource-spike.md](2026-08-15-vscode-sessions-resource-spike.md) (the previous "memory exhaustion → IO storm" incident on the same machine. The root cause is completely different — that one was VS Code session leakage, this one is a k8s workload resource-limit config problem — but the downstream mechanism (page-cache thrashing → IO PSI spike) is highly similar; the fast localization this time largely reused the PSI alert rules added after that incident)
This record: captures the on-scene data, investigation chain, causal analysis, handling process, and follow-up adjustments in full, for reuse.

---

## 1. Symptoms

User received a Grafana alert (rule `io_pressure_critical`, `host-metrics-rules.yml`, inherited from the PSI monitoring added after the 2026-08-15 incident):

```
IO PSI 'full' above 15% for 2 minutes on vps_oracle (processes stalled on IO, load average will follow)
```

## 2. On-scene snapshot

### 2.1 PSI confirms the alert is real

```
$ cat /proc/pressure/io
some avg10=30.57 avg60=30.49 avg300=25.07 total=2942640537
full avg10=24.97 avg60=26.54 avg300=21.99 total=1538669957
```

`full avg10` near 25%, far above the 15% threshold — not a false positive, and ongoing (`avg300` also high, meaning the past 5 minutes have been this way).

### 2.2 Read/write direction: vmstat

```
$ vmstat 1 5
procs -----------memory---------- ---swap-- -----io---- -system-- -------cpu-------
 0  1 258476  904956 925076 7596236    4   21   2086   5623 12156   54 10  5 81  3
 0  1 258476  907536 925076 7596200    0    0  90980    200 10696 18025  5  5 69 21
 0  1 258476  909096 925076 7596356    0    0  92016     20 11079 18985  5  5 70 20
 1  0 258472  911784 925076 7596296    8    0  91780    288 13588 23334  5  6 66 22
 2  0 258472  905108 925076 7596288    0    0  87496      0 12516 22253  6  5 66 21
```

`bi` (read) is routinely 90000+ blocks/sec (≈90MB/s), `bo` (write) near 0, `wa` at 20%+ CPU — confirming it is **read** slowing the system, not write.

### 2.3 Ruled-out items

```
$ free -h
               total   used  free  shared  buff/cache  available
Mem:            23Gi    14Gi  1.1Gi   63Mi       8.1Gi        8.9Gi
Swap:          4.0Gi   252Mi  3.8Gi
$ df -h /
/dev/sda1  193G  73G  121G  38%  /
```

Disk space is sufficient (38%), ruling out "disk full"; `iostat` not installed, so used `vmstat` + `/proc` to investigate directly. Available memory was already tight (1.1Gi truly free), foreshadowing the later issue.

## 3. Investigation chain

**Step 1, find "who is reading"**: first scanned `/proc/*/io` as a normal user to compute each process's read/write deltas over 2 seconds, but only caught myself (the current terminal session), meaning the real heavy consumer is a different user / root-privileged process; re-scanned with `sudo` and caught `all-in-one-linux` (PID 713618), read rate ~93MB/s, far ahead of everything else.

**Step 2, the key turning point — the contradiction between read_bytes and rchar**: looked at which files this process actually opened (`/proc/pid/fd`) and found **only sockets, not a single disk file**; looked at `/proc/pid/maps` file mappings, and only its own executable. But `/proc/pid/io` shows:

```
rchar: 18033040        # bytes the process itself read() , ~18MB
read_bytes: 63512895488 # bytes the kernel actually read from the block device, ~63.5GB
write_bytes: 0
```

The two differ by 3000+ times. A normal "file-reading" process should have these two numbers in a similar order of magnitude. This signature — "the block device read a lot, but the process itself did not read that much" — usually has only one explanation: **this process's own memory pages were swapped out by the kernel and are now being swapped back** — and this "swap back" IO is counted against its account, but is not a file read it actively initiated.

> **Lesson**: if you stop at "found the process with the highest read IO" and conclude, pointing the finger directly at that process's own behavior, the direction is wrong. It was precisely the anomalous `read_bytes ≫ rchar` ratio that re-pointed the clue from "some process reading a file" to "global memory-pressure-induced paging"; the following steps only fill in the evidence chain, not blind guessing.

**Step 3, verify the "memory paging" hypothesis** — `/proc/vmstat` reclaim counters:

```
workingset_refault_file 31460498   # times a page-cache page was swapped out and demanded back, 31M+
pgscan_file  118114504              # times the kernel scanned file pages for reclaim
pgsteal_file  91629545              # file pages actually reclaimed
pswpin       64547
pswpout      343700
pgmajfault   179888
```

Together these numbers show: **the entire host is undergoing large-scale page-cache thrashing**, not an isolated problem of one process.

**Step 4, find the trigger of the thrashing** — `dmesg` turned up **3 OOM kills in the past 16 hours**:

```
[Sun Aug 16 21:10:59 2026] Memory cgroup out of memory: Killed process 200526 (java) ...
[Mon Aug 17 02:04:03 2026] Memory cgroup out of memory: Killed process 525702 (trivy) total-vm:4100452kB anon-rss:508436kB file-rss:66316kB ...
[Mon Aug 17 05:39:48 2026] Memory cgroup out of memory: Killed process 272623 (all-in-one-linu) total-vm:1342108kB anon-rss:126032kB file-rss:7588kB ...
```

The last one happened **7 hours 25 minutes ago** — precisely matching the suspicious process 713618's uptime (`ps -o etime` = `07:25:53`). So `all-in-one-linux` is Jaeger (the executable name inside the `jaegertracing/all-in-one` image), auto-restarted after an OOM kill, itself a victim of this memory pressure, still thrashing after restart under the same pressure.

**Step 5, quantify "why memory is so tight"** — `kubectl -n lab-environment` located the specific pod (container ID reverse lookup, `jaeger-7c96c7f5bb-pf7d4`, restart 1 time, 7h26m ago, matching the scene exactly), and looked at its resource settings:

```
$ kubectl -n lab-environment get pod jaeger-... -o jsonpath='{.spec.containers[0].resources}'
{"limits":{"cpu":"100m","memory":"128Mi"},"requests":{"cpu":"25m","memory":"64Mi"}}
```

`limits.memory: 128Mi`, and when killed `anon-rss` was 126032kB — **right at the limit's edge**, any small fluctuation knocks it over the cgroup OOM killer.

Then looked at the node overall:

```
$ kubectl describe node instance-20260321-2043 | grep -A6 'Allocated resources'
Resource   Requests      Limits
--------   --------      ------
cpu        2700m (67%)   14775m (369%)
memory     9884Mi (41%)  26570Mi (110%)
```

Node memory **limits sum to 110% of node capacity** — overcommit. `requests` are only 41%, so the scheduler thinks this node is still loose and will keep packing in new pods; but if several services' actual usage rises simultaneously (as happened here), real memory gets squeezed out, the kernel starts frantic paging, and that is the direct mechanism of this alert.

Along the way also checked trivy (the other victim in the same batch of OOM records): each `trivy-operator` scan Job's `limits.memory` is set to only **500Mi**, and when killed `anon-rss(508436kB) + file-rss(66316kB)` already exceeded that cap — the same "limit set tighter than actual usage" pattern as jaeger, except it is a short-lived Job and won't thrash continuously like jaeger.

## 4. Root-cause chain

```
k3s node memory limits sum overcommitted to 110% of node capacity
  + the same machine also runs a dozen-plus docker compose services (not counted in k8s stats)
  → concurrent load of multiple services rises together
    → real available memory squeezed to only 1.1Gi
      → kernel massively reclaims/pages page cache (workingset_refault_file 31M+)
        → jaeger (128Mi limit), trivy scan Job (500Mi limit) each OOM-killed by their cgroups in turn
          → after jaeger restarts, the new process still thrash-continues under the same memory pressure (the read_bytes≫rchar paging signature)
            → many small random IOs (paging read-back) push up IO PSI full
              → 15% threshold sustained 2 minutes → io_pressure_critical triggered
```

In one sentence: **the alert's direct root cause is page-cache thrashing caused by memory overcommit; the specific culprits of the overcommit are jaeger/trivy's two containers' memory limits set tighter than actual need — when overall load rises they each get OOM-killed by their cgroups in turn, and the kill-restart loop in turn worsens the thrashing.**

## 5. Handling process

### 5.1 Raise the two memory limits

Compared against "actual usage when killed" to pick conservatively-sufficient new values, only touching limits, not requests (avoid incidental impact on the scheduler's placement judgment):

| Service | File | old limit | actual usage when killed | new limit |
|---|---|---|---|---|
| jaeger | `vps_oracle/k3s/apps/lab-environment/k8s/jaeger.yaml` | 128Mi | anon-rss 126MB | **256Mi** |
| trivy scan Job | `vps_oracle/k3s/trivy-operator/values.yaml` | 500Mi | anon+file-rss ~561MB | **768Mi** |

The two changes committed separately (`6a0079a`, `a4ff067`), pushed to `main`. Both ArgoCD Applications (`lab-environment`, `trivy-operator`) have `automated selfHeal` enabled and source from GitHub `main` — a direct `kubectl` edit would be auto-corrected back, must go through git. After push, manually `annotate argocd.argoproj.io/refresh=hard` to trigger immediate sync (not waiting for the default polling cycle), confirmed jaeger's new pod (`jaeger-56d969489b-7hcbq`) restarted with the new limit and `Running`, and both Applications returned to `Synced`/`Healthy`.

Post-handling re-check:

```
$ cat /proc/pressure/io
some avg10=0.00 avg60=0.79 avg300=13.37
full avg10=0.00 avg60=0.62 avg300=11.37
```

`avg10` went straight to zero; `avg300` is the decaying tail of the earlier high window, and after continued observation dropped to single digits.

### 5.2 Fill the inspector gap: new `k3s-oom-killed-containers.sh`

An after-the-fact review of the existing 15 checks under `vps_oracle/inspector/` found that **none of them can pinpoint "which specific container was OOM-killed"**:

- `k3s-evicted-pods.sh` only catches residual pods with `phase=Failed` — jaeger/trivy, after OOM kill, stay `Running` the whole time (just the container restarted) and never enter `Failed`, so they are entirely outside this check's detection range.
- `docker-restart-storms.sh` only checks **docker compose** containers on the host, not k3s pods; and its threshold is restart ≥10 times to count as a "storm", while this time jaeger only restarted once.
- Grafana's PSI/memory rules can see the aggregate signal of "resources are deteriorating", but cannot see the root-cause-level attribution of "which specific pod was OOM-killed by whom".

The new check reads `containerStatuses[].lastState.terminated.reason == "OOMKilled"`, with a lookback window of 24 hours (covering the twice-daily inspection interval, so even skipping one run won't miss it), and `alert` only alerts without auto-remediation (whether to adjust the limit is a human judgment). 6 test cases (hit / beyond-window / non-OOM reason / never-restarted container / custom window / kubeconfig-missing fallback) all pass, and a dry-run against the real cluster verified no false positives. Commit `a0664b4`, also updated `vps_oracle/inspector/README.md` and the "alert-only" table in `docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md`.

### 5.3 Wrap-up detour: the `io_pressure_warning` false positive

About 40 minutes after wrap-up, another one arrived:

```
IO PSI 'some' above 20% for 3 minutes on vps_oracle (processes waiting on IO)
```

Re-checking `/proc/pressure/io` found it had already self-recovered (`some avg10=0`), and `MemFree` had climbed back to 2.6G+. Analysis: `some` is pushed up as long as "at least one task is waiting on IO", a much lower bar than `full` (all non-idle tasks stuck simultaneously) — any few containers coincidentally doing some IO (ArgoCD reconcile, log rotation, trivy scan, docker healthcheck writing a file...) can briefly cross 20% and fall back on its own after 3 minutes; this time it was very likely the tail-end of the main event (the new jaeger pod warming up, memory refilling page cache), not a new problem.

Adjustment direction: only lengthened `for` (3m → 10m), left the 20% threshold unchanged — this time's problem is "duration" rather than "magnitude", and lengthening the confirmation window directly targets the "occasional brief concurrent IO" noise pattern while preserving the ability to detect genuinely sustained deterioration (a real incident's `full` had persisted over 10 minutes, so lengthening does not affect timely detection). Edited `vps_oracle/compose/monitoring/grafana/provisioning/alerting/host-metrics-rules.yml`, commit `233cb5c` pushed to main, `docker compose restart grafana` to reload provisioning (file changes on a bind mount are not auto-sensed by `docker compose up -d`), and logs confirm `finished to provision alerting` with no errors.

## 6. Results (before/after)

| Metric | At incident | After handling |
|---|---|---|
| IO PSI full avg10 | 24.97% (ongoing, `avg300` also ~22%) | **0%** |
| MemFree | 1.1Gi (at one point dipped to 756Mi) | **2.6G+**, continuing to climb |
| jaeger container | 128Mi limit, already OOM-killed 1 time, thrashing after restart | 256Mi limit, new pod `Running` normally |
| trivy scan Job | 500Mi limit, had been OOM-killed | 768Mi limit |
| inspector coverage of "container OOM-killed" | none (none of the 15 checks covered it) | new `k3s-oom-killed-containers.sh`, with alert leveling |
| `io_pressure_warning` | `for: 3m`, sensitive to brief concurrent IO | `for: 10m`, filters occasional noise |

## 7. Remaining / follow-up

- **The 110% node memory overcommit itself was not resolved** — this time only stopped the two specific symptoms jaeger/trivy. If other services' load also rises together later, the same page-cache thrashing and IO PSI spike may recur, and next time it may not be these two containers.
- **The `lab-environment` namespace is a candidate for later slimming**: it is a whole set of spring-petclinic-style microservice demo environments (consul/jaeger/loki/prometheus/promtail/grafana/postgres/redis + 4 business services), deployed only 15 hours before the incident, with the largest summed memory limits, and functionally duplicating the docker compose grafana/prometheus already on the host. If not needed long-term, scaling it down would significantly lower the overcommit ratio.
- **`cilium-operator` has 10 restarts (`reason=Error`, not OOM)**, and the inspector currently also does not cover "restart storm" detection at the k3s layer (`docker-restart-storms.sh` only looks at host docker containers) — not investigated deeply this time, recorded for later evaluation of whether to add a k3s-version restart-storm check.
- The Grafana rule adjustment only solved the "single isolated spike noise"; the `some` metric itself remains a low signal-to-noise signal. If more precise early warning is wanted later, combining `some` with memory trends (`memory_pressure_critical`, `memory_exhaustion_predicted_warning`) would be more reliable than `some` alone — but that requires a Grafana compound-condition query; the current evaluation is that keeping two separate independent rules implicitly achieves the same effect (on genuine deterioration the two trigger back-to-back), so no added complexity for now.

## 8. Appendix: reusable commands

```bash
# PSI current state and 5-minute history (avg300 is the free history of "what happened in the past 5 minutes")
cat /proc/pressure/{cpu,memory,io}

# read/write direction judgment
vmstat 1 5   # watch bi(read)/bo(write)/wa(io wait)

# find who is reading/writing (needs sudo to see processes of other users)
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

# judge whether the read IO is really reading files — key trick: compare rchar against read_bytes
sudo cat /proc/<pid>/io   # rchar≪read_bytes usually means paging/refault, not active file read
sudo ls -la /proc/<pid>/fd     # any fd pointing to a disk file
sudo cat /proc/<pid>/maps      # any file mapping (mmap may leave no fd)

# memory reclaim/paging counters (evidence of global thrashing)
grep -E 'workingset_refault|pgscan_file|pgsteal_file|pswpin|pswpout|pgmajfault' /proc/vmstat

# OOM kill history
sudo dmesg -T | grep -iE 'oom|killed process'

# reverse-lookup which k3s pod a container ID belongs to
kubectl get pods -A -o json | jq -r '.items[] |
  select(.status.containerStatuses[]?.containerID | contains("<container_id_fragment>")) |
  .metadata.namespace + "/" + .metadata.name'

# node memory overcommit ratio
kubectl describe node <node> | grep -A6 'Allocated resources'

# ArgoCD immediate sync (not waiting for the default polling cycle)
kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite

# make Grafana provisioning changes take effect (bind mount file changes are not auto-sensed by `docker compose up -d`)
docker compose restart grafana
docker logs grafana --tail 200 | grep -iE 'provisioning.alerting'   # find "finished to provision alerting"
```