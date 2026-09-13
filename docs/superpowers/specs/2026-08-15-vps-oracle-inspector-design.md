# vps_oracle Inspection Script Design

Date: 2026-08-15

## Background

Two incident docs record the upstream and downstream of one causal chain:

- [2026-08-15-ccr-vscode-extension-stall.md](../../incidents/2026-08-15-ccr-vscode-extension-stall.md): under the VS Code extension + ccr third-party provider combination, per-token SSE events caused the CLI to stall writing to stdout and the session not to exit (the trigger, already fixed by the sse-coalesce middleware).
- [2026-08-15-vscode-sessions-resource-spike.md](../../incidents/2026-08-15-vscode-sessions-resource-spike.md): the stalled session kept its whole exthost tree alive; the user reopening a window and retrying stacked more trees on top, plus the Remote-SSH server surviving forever after detachment and multiple server-version directories piling up, progressively ate all memory over 20 hours, finally triggering an IO storm under simultaneous multi-window reconnects, with load spiking to 38.7. Resolved by manual process killing + adding 4G swap + cleaning up server-version directories, and 7 Grafana alert rules (PSI/swap/D-state/memory-trend) were added to `host-metrics-rules.yml`.

These alert rules can see "resources are degrading", but not "which specific process/container/session is consuming them and whether it can be cleaned up" — that's exactly the gap this design fills: an inspection mechanism that **runs periodically, identifies concrete targets, and automatically cleans up or alerts by rule**.

## Goals and scope

- Detect and (tiered by rule) clean up host-level orphaned VS Code session trees, detached Remote-SSH server trees, and piled-up server-version directories.
- Detect and clean up disk-occupying orphan resources at both the docker layer and the k3s layer (stopped containers, dangling images, build cache, unused networks/volumes, Evicted pods, piled-up Completed Jobs, unused containerd images, Released PVs).
- Send a Telegram report at the end of every run (via the existing `apprise` container), regardless of anomalies, so that "is the inspection running at all" is itself observable.
- Extensible: adding an inspection item later means adding a new check script, no change to the main flow.

**Non-goals**: don't duplicate the aggregated-metric alerts already covered by Prometheus/Grafana (CPU/memory/disk usage, PSI, swap liveness, memory-trend prediction); don't do config changes like "automatically edit compose/k8s config files" — only resource cleanup and alerting.

## Architecture: host scripts, not docker

**Why not make it a container** (full discussion in the conversation record; conclusions here):

1. **Privilege model**: cleaning host processes (VS Code exthost/claude/codex session trees) requires host PID visibility and kill permission. The only containerized way is `pid: host`, stacked with a `docker.sock` mount for docker resources, making it the most-privileged container in this fleet — one layer above portainer (only `docker.sock`), which the README already flags as a "known high-risk exception". Under `pid: host`, root inside the container equals host root, so this containerization gains nothing in real isolation.
2. **Maintenance cost**: containerization doesn't remove the host-level scheduling config — cron inside the container needs an extra dep, and without it you still need host cron/systemd to trigger `docker compose run`; none of the host-side steps go away. Plus the extra Dockerfile/image maintenance and the "edited the script, forgot `--build`" gotcha vikunja-notify-relay already hit.
3. **Existing repo convention**: `CLAUDE.md` explicitly allows non-compose infrastructure directories under `<host>/` (`k3s/` is precedent), and the host inspection scripts fit right into this convention.

**Directory layout**(`vps_oracle/inspector/`):

```
vps_oracle/inspector/
├── inspect.sh              # main entry: run all scripts under checks/ in order, aggregate results, send Telegram
├── checks/                 # one independent executable script per check item
│   ├── stray-vscode-sessions.sh
│   ├── vscode-server-versions.sh
│   ├── docker-stopped-containers.sh
│   ├── docker-dangling-images.sh
│   ├── docker-build-cache.sh
│   ├── docker-unused-networks.sh
│   ├── docker-restart-storms.sh
│   ├── docker-unused-volumes.sh
│   ├── docker-compose-logging-drift.sh
│   ├── docker-oversized-logs.sh
│   ├── k3s-evicted-pods.sh
│   ├── k3s-completed-jobs.sh
│   ├── k3s-containerd-images.sh
│   ├── k3s-released-pvs.sh
│   └── k3s-stuck-terminating.sh
├── lib/
│   └── common.sh            # shared functions: self process-chain computation, PID identity re-check, two-stage kill(TERM→wait→KILL), send apprise
├── systemd/
│   ├── docker-gitops-inspector.service
│   └── docker-gitops-inspector.timer
├── state/                   # gitignored, runtime state(dedup / previous-result comparison)
└── README.md
```

**Extensibility mechanism**: a new check = drop a new script in `checks/`; `inspect.sh` auto-discovers and runs them via glob, no main-logic change. Each check script is an independent executable emitting a structured result in a fixed format (one JSON per line: `{"tier":"auto"|"alert","action":"killed"|"would-kill"|"flagged","target":"...","detail":"..."}`); `inspect.sh` collects all output and aggregates it into one Telegram message.

## Check list and tiering rules

Tiering logic: rules that are deterministically decidable, controllable-risk, reversible or rebuildable → **auto-handle**; rules whose conditions are fuzzy, or whose misjudgment cost is asymmetrically high (e.g. deleting still-useful data) → **alert only**, leaving it to human judgment. Thresholds start as defaults, all made into variables at the top of the script, tuned later based on actual inspection reports.

### Auto-handle

| Check | Condition | Action | Corresponding incident |
|---|---|---|---|
| Stray VS Code session tree | the session transcript's last line is a complete `result` (ended normally) and the process is still alive past the threshold (default 30 minutes) | TERM the whole subtree, wait 4 seconds, then KILL the survivors | direct match: the stall bug left sessions not exiting; this is the safety net — even if a different cause stalls later, it won't silently pile up for 20 hours again before being noticed |
| Detached server-main tree | ppid=1 (detached from terminal) and no active exthost underneath past the threshold (default 2 hours no CPU activity) | same as above | direct match: Remote-SSH server surviving forever after detachment |
| VS Code server-version directory pile-up | not among `lru.json`'s recently used versions, no process references it, retained count exceeds N (default keep 2) | delete the directory | direct match: the manual cleanup of 6 version directories/3.8G |
| Docker stopped containers | `status=exited` and exited more than N days ago (default 7 days) | `docker rm` | extension |
| Docker dangling images | created more than N days ago (default 7 days) | `docker image prune` | extension |
| Docker build cache | candidates older than N days (default 7 days) | `docker builder prune` | extension, disk-occupation type |
| Docker unused networks | custom networks with no attached containers | `docker network prune` | extension, rebuild cost near zero |
| k3s Evicted/Failed pods | leftover pods with `status.phase=Failed` | `kubectl delete pod` | extension, a k8s-recognized standard hygiene operation |
| k3s Completed Job pile-up | completed Jobs exceeding N count or N days | `kubectl delete job` | extension |
| k3s unused containerd images | the containerd counterpart of `docker image prune` | `crictl rmi --prune` | extension |

### Alert only

| Check | Condition | Report contents | Rationale |
|---|---|---|---|
| Suspiciously stalled session | transcript has no `result` (in interactive mode this line never exists, confirmed), further split into two tiers: ① last line is assistant with an unresolved `tool_use` and the process is confirmed idle (state=S, not actively running) → likely an unresponded pending question, alert if alive past 30 minutes; ② all other cases (just idle waiting for the next line) → alert only when alive past 25 hours, aligned with this host's `reconnectionGraceTime=86400`, the duration the process is legitimately allowed to live | PID, cwd, session id, alive duration, whether it's an unresponded pending question | can't distinguish "long task" from "stuck"; early warning — addresses the "20-hour accumulation went unnoticed" problem from the incident; a single threshold once fought with the deliberately-lengthened 24-hour grace time, split into two tiers on 2026-08-17 to resolve |
| Docker restart storm | RestartCount abnormally high or persistently `Restarting` | container name, restart count | auto-restart doesn't fix the root cause, may mask a config error |
| Docker unused volumes | exists but not mounted by any container | volume name | may hold data, asymmetric misdeletion risk (containers/images are rebuildable, volume data may not be) |
| compose-file logging config drift | scan `<host>/compose/*/docker-compose.yml` for services missing `logging.options.max-size` | file path, service name | this is "finding a config gap", not for the inspection script to edit compose files itself |
| Abnormally large container log file | `/var/lib/docker/containers/*/*-json.log` actual size is abnormal | container name, file size | may be a logging config that isn't taking effect, needs human investigation |
| k3s Released PV | no longer bound but still occupying disk | PV name | may hold data, same reasoning as docker volumes |
| k3s stuck Terminating pod | still stuck in Terminating past the threshold | pod name, namespace | usually indicates a finalizer/node issue, needs human judgment on whether to force-delete |
| k3s container OOM-killed | `containerStatuses[].lastState.terminated.reason=OOMKilled` and within the lookback window (default 24 hours) | pod/namespace/container name, restart count, time since | whether to raise the limit or shrink the workload is human judgment; the `k3s Evicted/Failed pod` check can't catch this — after a container is OOM-killed the pod usually stays `Running` (just restarts), never reaching `Failed`. Added after the 2026-08-17 `io_pressure_critical` incident (both jaeger 128Mi and a trivy scan job 500Mi were OOM-killed due to too-tight limits; at the time the inspection had no check that could pinpoint "who killed whom") |
| Any target that hits the "self process chain" | see self-protection rules below | `skipped: self-chain overlap` | never touch |

## Self-protection rules

Directly correspond to the gotchas hit in the incident docs, written into `lib/common.sh`:

1. Before acting, compute the own process chain (script PID + parent chain + systemd cgroup); every grep/ps comparison must exclude this chain — the incident docs hit the "`ps -eo args | grep` searched its own command line in" self-match bug.
2. Re-check the target PID's identity (cmdline + start time) before killing, guarding against PID-reuse misfiring.
3. Two-stage: TERM first, only KILL survivors after waiting, never start with `-9`.
4. Before killing a tree, verify the "to-kill list" has no overlap with the "own process chain"; on overlap, abort the whole batch and flag it as an anomaly (rather than just skipping that one item).

These functions are the part of the whole project least able to afford mistakes — a wrong one could have the inspection script kill the session it's running in. They need a minimal verification script, not just a manual pass (see the testing approach below).

## Notification format

Via the existing `apprise` service (`http://localhost:30085/notify/inspector-tg`), HTML format, reusing vikunja-notify-relay's established pattern. **Note**: apprise was already migrated into k3s in phase D (`workloads` namespace, NodePort `30085`) and is no longer a container on the docker `proxy` network, so it's reached via the host's local NodePort, not container-name DNS. Add a new apprise target `inspector-tg` pointing at the Telegram group "OCI System inspection" (bot token / chat id don't go into git, only as runtime data in the apprise store, same usage as the existing `vikunja-tg-<username>` targets; registered and tested on 2026-08-16, reusing the same bot token).

**Notification language is always English** (required by the user at 2026-08-16 launch; repo docs stay Chinese). Section headers, the empty report, and the title are all fixed English; the `detail` text produced by check scripts is also all English; `tests/test-inspect.sh` has an automated "payload has no CJK characters" assertion locking down this rule.

Example (consistent with `inspect.sh`'s actual output format):

```
🔍 Inspection report vps_oracle · 2026-08-16 09:00

Auto-handled
✅ killed: claude PID 3177808
   session <id> (cwd=/home/ubuntu/jerome/foo) finished 2880s ago, still alive past 1800s threshold
✅ deleted: Stable-df53daabb18cd157bdb08c7f01c34df936cf12f4
   not in top 2 lru.json entries, no active process, size=656M

Needs manual review
⚠️ claude PID 5521
   session <id> (cwd=/home/ubuntu/jerome/foo) alive 25920s with no transcript result yet -- may be a long task or stuck

Run took 4.2s
```

If nothing is anomalous, send just one line "✅ All clear — nothing needed attention" — ensuring that whether the inspection is running at all is observable.

## Deployment

- The systemd service runs as the `ubuntu` user (not root) — the processes it kills already run as `ubuntu`; docker operations rely on `ubuntu` being in the `docker` group; k3s operations rely on a read-only kubeconfig copy. If some operation later turns out to genuinely need root, wrap just that small piece in `sudo`, don't elevate the whole service.
- `ExecStart` points directly at the `inspect.sh` path inside the repo checkout, no separate `install.sh` copy — editing code and `git pull`/`git commit` leaves it in effect immediately, avoiding the claude-code-notify "forgot to run install.sh" gotcha. Manual `systemctl daemon-reload` is only needed for first install or changes to the unit file structure.
- timer: two lines `OnCalendar=*-*-* 09:00:00` / `OnCalendar=*-*-* 21:00:00` (note: must not be written as a single line `OnCalendar=09:00,21:00` — systemd parses that as 09:00 and 09:21, never triggering at 21:00; a gotcha hit on 2026-08-16, see commit 517e025), `Persistent=true` (won't miss after a machine reboot).
- Manual trigger: `systemctl start docker-gitops-inspector.service`.
- apprise target registration (copying vikunja's existing pattern; token/chat id not persisted to disk, passed as a one-time command argument; since apprise is now a k3s NodePort rather than a docker `proxy`-network container, send directly to the host's local NodePort, no `docker run --network proxy` wrapper needed):
  ```bash
  curl -s -X POST \
    --data-urlencode "urls=tgram://<bot_token>/<chat_id>/" \
    http://localhost:30085/add/inspector-tg
  ```
  Executed on 2026-08-16: the bot token reuses the existing vikunja bot (read from the already-persisted `vikunja-tg-jerome.cfg` in the apprise PVC), and the chat id was found via that bot's Telegram `getUpdates` API (the "OCI System inspection" group already pulled the bot in). The `inspector-tg` target has been created and a test message sent and verified.

## Testing approach

1. `INSPECTOR_DRY_RUN=1` mode — the auto tier only prints "would kill/would delete" without actually acting; run a few rounds first to check the report matches reality.
2. Write a minimal verification script for `lib/common.sh`'s self-protection functions (self process-chain computation, PID identity re-check) to ensure this logic itself has no bugs.
3. After dry-run, switch to production mode and observe a few days of Telegram reports, only considering it stable once no misfires are seen — don't trust auto-kill on day one.

## Future extensions(not in this version)

The following are directions mentioned in the discussion but deferred to keep the first version's scope in check; adding them later simply means a new check script each: disk hot-spot scanning (large files/large directories), zombie (Z-state) process counting, `systemctl --failed` scanning, detection of the NPM reverse-proxy SSL toggle silently resetting (the README known gotcha).