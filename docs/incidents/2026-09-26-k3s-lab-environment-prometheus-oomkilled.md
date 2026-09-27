# Incident: lab-environment prometheus OOMKilled by its own 192Mi cgroup limit, and the inspection report blamed the wrong machine

Date: 2026-09-26 (OOMKill at 19:00:52 HKT; surfaced by the 2026-09-27 09:00 inspection report, investigated that morning)
Status: resolved (raised three container memory limits and cut jaeger's trace bound; moved the cluster-wide inspector checks out of `vps_oracle/` so this class of finding is attributed correctly)
Environment: k3s cluster spanning two nodes — server `vps_oracle` (4-core ARM, 23.4 GB), agent `vps-oracle2` (2-core ARM, 11.6 GB, tainted `dedicated=lab:NoSchedule`). Workload: namespace `lab-environment`, `prom/prometheus:v2.53.0`, `grafana/promtail:3.1.0`, `jaegertracing/all-in-one:1.60`. All of `lab-environment` is pinned to the agent by the Kyverno mutate policy `lab-environment-on-oracle2`.
Related record: [2026-08-17-k3s-memory-overcommit-io-pressure.md](2026-08-17-k3s-memory-overcommit-io-pressure.md) — the *same class* of fault ("container limit set below what the container needs"), but a different mechanism and a different node: that one was **node-wide** overcommit (limits summing to 110% of allocatable) with cross-workload page-cache thrashing and an IO PSI alert; this one is a **cgroup-local** kill on a node that was never under pressure. That incident's fix — raising jaeger's limit 128Mi→256Mi — is why jaeger appears again below at 97.7% of the new limit: raising the limit was the wrong lever for it.
This record: captures the on-scene data, the sizing measurements, the two independent findings (the container and the report), and the follow-up refactors.

---

## 1. Conclusion first

**The root cause is a memory limit below the container's actual need, not a memory leak and not node exhaustion.**

Three separate facts had to be true at once, and each one alone would have hidden it:

1. **`limits.memory: 192Mi` was below what this Prometheus needs.** Its non-reclaimable `anon` alone was measured at 132.6 MiB, and had reached **187.7 MiB** in the previous container instance. The limit had never been changed in git; the scrape set had grown from ~2 to 20 targets in the two commits immediately before the killed container was created.
2. **The container has no volume, so its TSDB page cache is charged to the same cgroup.** `/prometheus/data` lives on the writable layer, so 55–75 MiB of page cache competed with the Go heap for the same 192 MiB. The effective heap budget was closer to 120 MiB. Every OOMKill also destroyed the entire TSDB — the oldest sample always equalled the last restart.
3. **The kill was cgroup-local.** `constraint=CONSTRAINT_MEMCG` with `oom_memcg` = Prometheus's own pod cgroup. The node was at 65% memory with memory PSI flat at 0. Node-level monitoring could not see this, and neither could any node-level alert rule.

**It was not a leak.** Over 187 samples the RSS slope was **+0.02 MiB/h** and the head series count held flat at ~16.8k. What drives the sizing is *variance*: two container instances at comparable uptime differed by 55 MiB of `anon`, which no trend explains. That is an event-driven spike, and `GOMEMLIMIT` was unset, so the GC pacer was free to run past the cgroup cap before collecting.

**Finding 2, independent of the above: the inspection report named the wrong machine.** Every check that reads the cluster API lived in `vps_oracle/host-native/inspector/checks/`, so the report filed them under the `vps_oracle` block — while every `lab-environment` pod runs on vps-oracle2. The line was correct about the pod and wrong about the host, and only the pod's own `nodeName` revealed it. That is what made this take an investigation at all.

## 2. Evidence chain

### 2.1 What the report said

```
⚠️ vps_oracle — 21 checks, 2 need review
   ⚠️ pod lab-environment/prometheus-74677c47cb-9ld5p container prometheus
      OOMKilled 13h 59m ago (restartCount=1) — container's memory limit was hit ...
```

The check (`k3s-oom-killed-containers.sh`, 24h lookback) was right. Its instance label was not: `inspect.sh` derives the label from the directory a check lives in, and this check lived in `vps_oracle`'s.

### 2.2 The pod is on the other node

```
$ kubectl -n lab-environment get pods -o wide | awk '{print $1, $7}' | sort -k2 | uniq -c -f1
   27 ... vps-oracle2
```

Not one `lab-environment` pod runs on vps_oracle — the Kyverno policy sees to that. `describe pod` confirms `nodeName: vps-oracle2`.

### 2.3 The kill was cgroup-local, not node exhaustion

```
$ sudo dmesg -T | grep -i "Memory cgroup out of memory"
[Sat Sep 26 11:00:52 2026] oom-kill:constraint=CONSTRAINT_MEMCG, ...,
  oom_memcg=/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod74b5445e....slice,
  task=prometheus, pid=3067976
  Memory cgroup out of memory: Killed process 3067976 (prometheus)
  total-vm:1729372kB, anon-rss:192196kB, file-rss:46120kB

$ kubectl top nodes                       # both nodes, at investigation time
instance-20260321-2043   9930Mi  41%      # vps_oracle
vps-oracle2              7858Mi  65%
$ cat /proc/pressure/memory               # on either host
some avg10=0.00 avg60=0.00 avg300=0.00
full avg10=0.00 avg60=0.00 avg300=0.00
```

`vps_oracle` has never had an OOM in 41 days uptime. Node exhaustion is ruled out on both machines.

### 2.4 Where the 192 MiB actually went

Read from the container's cgroup on the node it runs on (the numbers `kubectl top` reports are working set, and under-report badly — it said 118Mi against a cgroup total of 191.7MiB):

```
memory.current  201060352  191.7 MiB   /  memory.max 201326592  192.0 MiB
memory.peak     201326592  192.0 MiB   <- hit the cap exactly
anon            120786944  115.2 MiB   <- NOT reclaimable
file             77893632   74.3 MiB   <- reclaimable page cache for its own TSDB
max watermark events: 77,455   workingset_refault_file: 436,758
```

`file` breathes — it moved 75.2 → 55.0 MiB within one hour while `memory.current` stayed pinned at the cap. That is the mechanism: `anon` is a hard floor, `file` is what the kernel keeps sacrificing, and after ~18h it could no longer free enough.

Cross-checked against the kernel's per-process view: `smaps RssAnon` = 132.6 MiB, matching cgroup `anon` exactly. Prometheus's own `go_memstats_sys_bytes` accounted for only **55.7 MiB**, however; the missing ~74 MiB sits in a 196 MiB anonymous `rw-p` mapping at the Go heap-arena base (`0x4000000000`, followed by a `PROT_NONE` guard page). **This was not reconciled from read-only data** and is the main open question in §6.

### 2.5 Not a leak

Regression over 187 samples / 15.5 h:

| metric | first → last | slope |
|---|---|---|
| `process_resident_memory_bytes` | 122.0 → 122.5 MiB | **+0.02 MiB/h** |
| `go_memstats_heap_inuse_bytes` | 31.2 → 35.1 MiB | −0.08 MiB/h |
| `prometheus_tsdb_head_series` | 16,800 → 16,753 | ~0 |

Only the on-disk footprint grows, in sharp steps of ~8.9 MiB every 2h (`storage.tsdb.min-block-duration`): `tsdb_storage_blocks_bytes` 0 → 53.7 MiB in 7 discrete jumps, steady state 4.45 MiB/h, WAL ~19.9 MiB/h linear.

The `anon` floor itself is flat — but it is *high*, and two instances disagreed by 55 MiB at a 2.5h age difference. `go_gc_gomemlimit_bytes` read `9.223372036854776e+18` (MaxInt64 = unset) with `GOGC=75`, which is precisely the configuration that lets a spike overshoot the cap.

### 2.6 Two others were at their ceilings

| container | limit | `memory.current` | `memory.peak` |
|---|---|---|---|
| prometheus | 192 Mi | 191.7 Mi (100%) | == the limit |
| promtail | 64 Mi | 63.5 Mi (99.2%) | == the limit |
| jaeger | 256 Mi | 250.8 Mi (97.7%) | == the limit |

jaeger had **already** been OOMKilled once, on 2026-09-25 16:55:43Z, at `anon` 254.7 MiB after 2h43m — after its limit was raised 128→256 in the 2026-08-17 incident. It then survived 33h at 243.6 MiB purely because it did not happen to tip over.

### 2.7 Nothing else could have caught this

```
$ curl -s '.../api/v1/label/__name__/values' | tr ',' '\n' | grep -c '"container_\|"kube_'
0
```

The compose Prometheus (which drives Grafana's alerting) has **no pod- or container-level series at all** — no kube-state-metrics, no cAdvisor. So no rule could express "a container is near its limit", and the host-level rules could not have fired anyway: they key on `node_memory_*` and PSI, and neither moved. The inspector's `lastState` check was the only detector that could see it, and it did — twice (the 21:00 and 09:00 reports, both confirmed sent with HTTP 200).

## 3. Root cause

Three compounding design decisions, none of them individually wrong:

1. **A memory limit was chosen without measuring.** 192Mi was inherited and never revisited, while the scrape set grew 10× in the 48h before the kill. The container was not "slowly filling up": it sat near its ceiling from the start and was killed when a spike exceeded what page-cache reclaim could absorb.
2. **Prometheus has no volume.** Because `--storage.tsdb.path` falls back to a path on the container's writable layer, its TSDB page cache is accounted to its own cgroup. This converts "a bit of disk I/O" into "a competitor for the heap budget", and it makes every OOMKill destroy all metric history (the oldest sample always equals the last restart). Whatever retention is configured is theoretical until a volume exists.
3. **`GOMEMLIMIT` is unset on every container here.** Go's default is to target `GOGC`, not the cgroup cap, so the runtime is free to overshoot the limit before collecting. jaeger is the clearest case: `go_memstats_next_gc_bytes` was 323.7 MiB against a 256 MiB cgroup cap — the pacer was configured to exceed the limit by 26%.

The attribution failure has a separate, simpler root cause: **the report's instance label was derived from where a check's file happened to live, and a cluster-wide check was filed under a host.** `vps_oracle/host-native/inspector/checks/` held both "checks about vps_oracle" and "checks about the k3s cluster", and the label rule could only see the former.

## 4. Fix

### 4.1 The containers (k3s GitOps: file → commit → push → ArgoCD sync)

Measured need, then sized for the observed peak rather than the average:

| container | limit | request | added |
|---|---|---|---|
| prometheus | 192Mi → **512Mi** | 128Mi → 256Mi | `GOMEMLIMIT=400MiB`, `--storage.tsdb.retention.size=128MB` |
| promtail | 64Mi → **128Mi** | 32Mi → 64Mi | `GOMEMLIMIT=100MiB` |
| jaeger | 256Mi → **384Mi** | 64Mi → 128Mi | `GOMEMLIMIT=300MiB`, `MEMORY_MAX_TRACES` 5000 → 2000 |

`MEMORY_MAX_TRACES` was cut because jaeger's per-trace cost is now measured at ~41 KiB of heap, so the existing bound of 5000 needed ~202 MiB — most of the old limit. The file's own comment had already argued "bound the store instead of chasing the limit"; the number was simply set without knowing the cost per trace. 2000 traces is ~83 MiB. It is kept as a separate commit from the limit raise, because it changes how many traces are inspectable — a behaviour change, not a sizing one.

`retention.size` does **not** shrink `anon` and does not shrink the WAL; it caps one growth direction. The minimum viable limit is ~320–384 MiB regardless of retention.

**Node arithmetic** (vps-oracle2 is the binding constraint):

```
allocatable           11,927 Mi
limits before         10,848 Mi   91.0%
limits after          11,360 Mi   95.2%
requests after quota   5,552 Mi   67.8% of the 8Gi namespace quota
```

The `ResourceQuota` caps **requests only** — `limits` are not in its spec at all — so the limit increases consumed none of it. Raising all three to 1 Gi would have put the node at 104.9% limits, i.e. the 2026-08-17 failure mode, and was rejected.

### 4.2 The report

Three commits, each replacing a special case with the general rule:

1. `k3s/inspector-checks/` — the seven cluster-wide checks moved out of `vps_oracle/`. No engine change was needed: the existing glob already matched, and the directory-name rule already produced `k3s`.
2. `vps_oracle/inspector-checks/` — vps_oracle's own checks moved out too, leaving `vps_oracle/host-native/inspector/` as the pure engine. This removed the **last** `case` from the attribution rule; the instance name is now unconditionally the directory a check was found in, for all four trees.
3. `inspector/kubeconfig/` — the credential bootstrap was renamed from `inspector/k3s/`, which collided with the repo-root `k3s/`. Not cosmetic: references were written short, so from the new `k3s/inspector-checks/` tree, "points at `k3s/rbac.yaml`" read as a root-level file that does not exist.

## 5. Verification

```bash
# the containers picked up the new values
$ kubectl -n lab-environment get deploy prometheus promtail jaeger \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].resources}{"\n"}{end}'
prometheus  {"limits":{"cpu":"100m","memory":"512Mi"},"requests":{"cpu":"50m","memory":"256Mi"}}
promtail    {"limits":{"cpu":"50m","memory":"128Mi"},"requests":{"cpu":"25m","memory":"64Mi"}}
jaeger      {"limits":{"cpu":"100m","memory":"384Mi"},"requests":{"cpu":"25m","memory":"128Mi"}}

# and the trace bound
$ kubectl -n lab-environment get deploy jaeger -o jsonpath='{...env}'
{"name":"MEMORY_MAX_TRACES","value":"2000"}, {"name":"GOMEMLIMIT","value":"300MiB"}

# attribution: 32 checks, four instances, no hostless-group fallback
$ REPO_ROOT=$(pwd); for c in "$REPO_ROOT"/*/inspector-checks/checks/*.sh; do ...
vps_oracle 14 / k3s 7 / vps_gcp 5 / vps_oracle2 6
```

Everything else: all 22 non-e2e inspector tests pass, the CI pairing check and `check-compose-conventions.py` are clean, and `inspect.sh`'s exact discovery glob was run against the real tree rather than assumed.

**What to watch from here:** `memory.current` against `memory.max` on the three containers. The new limits are sized for the *observed* 187.7 MiB peak, so a recurrence of that spike at 512 MiB is possible but should no longer be fatal. There is still no metric that would alert on it — see §6.

## 6. Leftovers / lessons

**Unresolved**

- **~74 MiB of Prometheus's `anon` is not accounted for.** Go's memstats reports 55.7 MiB; smaps places the rest in a 196 MiB anonymous `rw-p` mapping at the heap-arena base with a guard page. jaeger and promtail both reconcile cleanly, so this is Prometheus-specific. Practical consequence for anyone sizing anything here: `kubectl top` and `go_memstats_*` under-report by roughly 1.5×, so **always size from the cgroup**, not from either of those.
- **The 55 MiB instance-to-instance `anon` variance is unexplained.** A 15.5 h window cannot characterise the event that drove it to 187.7 MiB. If it recurs at 512 MiB, 512 MiB may still be marginal.
- **`GOMEMLIMIT` was never verified to take effect** in these images. It is unset everywhere and the failure mode it addresses is real, but prometheus's `go_gc_gomemlimit_bytes` has not been re-read since the deploy.
- **Retention is still theoretical.** Without a volume, history remains as long as the uptime. `retention.size=128MB` bounds the footprint; it does not preserve anything.

**Detection gap, deliberately left open**

Grafana could not have alerted on this and still cannot: the compose Prometheus scrapes node-exporter, blackbox and the Istio control plane only — zero `container_*` / `kube_*` series. Closing it means adding kube-state-metrics to the cluster and a scrape job, after which the honest rule is not a proxy threshold but the signal itself:

```promql
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
```

That is exactly what the inspector's `lastState` check reads, evaluated every minute instead of twice a day. **Deferred by decision on 2026-09-27, not forgotten.**

There is also a cheaper, earlier signal available to the inspector itself, because the failure had three days of warning: all three containers sat at `memory.peak == memory.max` long before anything died. A check that reads each container's cgroup `memory.current` against `memory.max` and flags ~90% would have said "this limit was never right" days earlier. Its constraint is that it needs the cgroup, not the API: `kubectl top pod` reports working set and under-reports by roughly 1.5× here, so a check built on it would be blind to exactly this case. That means reading `/sys/fs/cgroup/...` on **both** nodes — locally with the `sudo -n` the inspector already has, and over `oracle2_ssh` for the agent. Not implemented; recorded as the option, with that cost stated.

**Lessons**

- **A container that OOMs and self-restarts is invisible by design.** The pod stays `Running`, `restartCount` increments once. It is not `CrashLoopBackOff`, not evicted, not a restart storm — so the eviction check and the restart-storm check both miss it. Only a check that reads `lastState` sees it, and a twice-daily digest means up to 12h of latency.
- **`memory.peak == memory.max` is the signal to look for.** All three containers were sitting exactly on their caps; that is a limit that was never right, not one that regressed.
- **A limit is a sizing decision, and it needs a measurement to be one.** The 2026-08-17 incident "fixed" jaeger by doubling its limit; nine days later jaeger was OOMKilled again against the new number. What was missing both times was the cost per retained trace — a number that was eventually measured in one command.
- **When a report names a machine, check that the thing it names actually lives there.** One `kubectl get pods -o wide` would have short-circuited the whole investigation, and the label that obscured it was the report's own.
