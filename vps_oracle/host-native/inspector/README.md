# vps_oracle/host-native/inspector

Host-level inspection script, not managed by docker compose (like `vps_oracle/host-native/host-firewall/` and `vps_oracle/host-native/npm-nodeport-relay/`, it's a systemd service that runs directly on the host under `<host>/host-native/`; see the repo root README's "Directory structure" section). For the design background, tiering rules, and self-protection rules, see
[`docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md`](../../../docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md).

**This directory is the engine, and it owns no checks.** `inspect.sh`, `lib/common.sh`, `systemd/` and `state/` live here; every check lives in a `<repo>/<x>/inspector-checks/` tree, including the ones about vps_oracle itself ([`vps_oracle/inspector-checks/`](../../../vps_oracle/inspector-checks/README.md)). One glob finds all four trees, and a finding's instance name is just the directory its check was found in — so "the directory says what the check inspects" holds with no exception, and there is no per-host special case to keep in sync. Only the engine's own tests (`tests/test-common.sh`, `tests/test-inspect.sh`, `tests/lib.sh`, `tests/fixtures/`) and the systemd units stay here.

**Notification language**: the Telegram report title and body are English only (2026-08-16 user request; the repo docs remain Chinese). `tests/test-inspect.sh` has a corresponding assertion (title, section headers, no CJK characters). The title carries no host name: a report is one logical inspection, and the `Inspected` section names the instances covered.

**Report layout**: one logical inspection, grouped by instance — the instance is simply the `inspector-checks/` directory a check lives in, so today's four are `vps_oracle`, `vps_oracle2`, `vps_gcp` and `k3s`. It never says which machine ran the scripts (all of them run here). Sections appear in the order the discovery glob returns the trees, i.e. alphabetically by tree name — there is no special case promoting the local host to the top, because there is no special case anywhere in the attribution.

Because the directory *is* the attribution, filing a check in the wrong tree is not a naming problem to paper over: a check about the cluster belongs under `k3s/` — which spans two nodes and so has no host to live under — and a check about another host under that host. The 2026-09-27 lab OOM was reported under `vps_oracle` for exactly this reason, while every pod it concerned runs on vps-oracle2. Adding a tree is cheap and needs no engine change: create `<repo>/<x>/inspector-checks/checks/`, and the glob and the instance name both follow.

Every instance always gets a header — `✅ … all clear`, `✅ … N auto-handled` or `⚠️ … N need review` — so a healthy run visibly covers remote hosts too, and any auto/alert lines sit under their instance's header. The test-only override `INSPECTOR_REPO_ROOT` points the remote-check glob at a fake tree.

**Sizes and ages in detail lines**: a check never prints a raw byte count or a raw second count — `human_bytes` / `human_duration` in `lib/common.sh` turn them into `57.2 MiB` and `7d 1h` (two units at most). Both are covered by `tests/test-common.sh`; use them for any new size/age a check reports.

```
🔍 Inspection report · 2026-09-27 21:00

✅ k3s — 7 checks, all clear
✅ vps_gcp — 5 checks, 1 auto-handled
⚠️ vps_oracle — 14 checks, 1 need review
   Needs manual review
   ⚠️ docker container foo
      restart count 12, state running …
✅ vps_oracle2 — 6 checks, all clear

Run took 6.7s
```

## Status (phase 2)

Filenames below are relative to the `checks/` directory of the tree named in the heading. Unless a heading says otherwise, that tree is [`vps_oracle/inspector-checks/`](../../../vps_oracle/inspector-checks/) — the checks about this host.

Implemented (phase 1):
- `stray-vscode-sessions.sh` — stray/stuck claude sessions, disconnected server-main trees
- `vscode-server-versions.sh` — piled-up `.vscode-server/cli/servers/*` version directories

Implemented (phase 2, docker layer):
- `docker-stopped-containers.sh` (auto) — containers exited for more than 7 days
- `docker-dangling-images.sh` (auto) — images dangling for more than 7 days
- `docker-build-cache.sh` (auto) — build cache older than 7 days
- `docker-unused-networks.sh` (auto) — custom networks with no containers attached
- `docker-restart-storms.sh` (alert) — abnormally high RestartCount / stuck in Restarting
- vps-oracle2's checks (run here, inspect vps-oracle2) live in [`vps_oracle2/inspector-checks/`](../../../vps_oracle2/inspector-checks/README.md): mirrors of these docker auto/alert checks, including real cleanup. The engine triggers them and supplies the shared `lib/common.sh` they source — no logic about oracle2 lives under `vps_oracle/`
- `docker-unused-volumes.sh` (alert) — volumes with no containers attached (anonymous aggregated into one line, named listed one per line)
- `docker-compose-logging-drift.sh` (alert) — compose services missing `logging.options.max-size`
- `docker-oversized-logs.sh` (alert) — `*-json.log` files over 50MiB each

Implemented (phase 2, k3s layer) — all but one in [`k3s/inspector-checks/checks/`](../../../k3s/inspector-checks/), because they read the cluster API rather than any one host and so report under the `k3s` instance; see that directory's README:
- `k3s-evicted-pods.sh` (auto) — Failed leftover pods
- `k3s-completed-jobs.sh` (auto) — Jobs completed for more than 3 days
- `k3s-containerd-images.sh` (auto) — containerd images with no container referencing them (`sudo crictl`). **Not** in `k3s/`: it reads *vps_oracle's* containerd, so it is node-local — it lives in `vps_oracle/inspector-checks/checks/` and reports under `vps_oracle`, despite the shared `k3s-` prefix
- `k3s-released-pvs.sh` (alert) — Released PVs
- `k3s-stuck-terminating.sh` (alert) — Terminating pods stuck for more than 15 minutes
- `k3s-node-not-ready.sh` (alert) — any Node whose Ready condition isn't True (added with the vps-oracle2 agent node; needs `nodes` get/list in `k3s/rbac.yaml`)
- `k3s-oom-killed-containers.sh` (alert) — `lastState.terminated.reason=OOMKilled` within the last 24 hours; the finding names the pod's `nodeName`, since this reads the whole cluster and the instance header is `k3s`, not a host. `k3s-evicted-pods.sh` can't catch this case (the pod stays `Running` the whole time, only the container is killed and restarted), added after the 2026-08-17 io_pressure_critical incident (jaeger/trivy were both OOM-killed because their limits were too tight)
- `k3s-capacity-pressure.sh` (alert) — the three ways a workload stops being able to run in the lab namespace: a ResourceQuota used at or above `INSPECTOR_QUOTA_USED_PCT` (default 90) of a hard limit, a ReplicaSet whose pods were refused at admission (`FailedCreate`), or a pod Pending past `INSPECTOR_PENDING_MINUTES` (default 5). Needs `resourcequotas` and `replicasets` get+list in `k3s/rbac.yaml` — and needs them *necessarily*, not conveniently: quota usage is invisible on a pod object, and a pod refused at admission never exists as one, so neither signal can be derived from the `pods` grant. Scoped to `lab-environment` deliberately (`INSPECTOR_LAB_NAMESPACE`) — the same signals cluster-wide would flag PR lanes legitimately waiting for capacity, and a check that cries wolf twice a day stops being read. Added after the 2026-09-25 incident where the quota could not admit a release plus its PreSync hook: every signal above was present for ~10 minutes before anyone noticed, and it was noticed only because pods began `CrashLoopBackOff`.

Implemented (NPM reverse proxy layer):
- `direnv-envrc-trust.sh` (alert) — runs `direnv export bash` from each group dir (`~/jerome`, `~/bridget`, `~/evidence`) and flags any whose `.envrc` reports "is blocked", i.e. whose direnv trust was revoked because the file's content changed since it was last `direnv allow`ed. It is alert-only and never auto-allows: `direnv allow` is itself the trust mechanism, and a revoked `.envrc` must be human-reviewed before re-trusting (the file is arbitrary shell, and the symlinked `shell-env/*.envrc` changes take effect on the live system immediately). Added after the 2026-09-13 incident where a comment-only translation sweep revoked trust and silently froze group provider/account switching (full story in [`docs/incidents/2026-09-13-switchboard-direnv-envrc-trust-revoked.md`](../../../docs/incidents/2026-09-13-switchboard-direnv-envrc-trust-revoked.md)).
- `npm-nginx-config.sh` (alert) — runs `nginx -t` inside the npm container. It catches the invisible "config works now, but the next cold start won't come up" state: NPM's Custom Location bakes the upstream hostname into `proxy_pass` (normal forwarding uses variables + Docker DNS, resolved per request), so once that backend container disappears, nginx refuses to start with an `emerg` on its next config load — and **all** reverse-proxy sites go down together, not just that one. The running nginx keeps going on the previously resolved address, so you can't see it from monitoring, the panel, or logs until restart. `nginx -t` uses the same resolution but runs in a separate process, so it doesn't affect the serving nginx. Added after the 2026-08-21 incident where the dify container was stopped for 45 hours and only blew up during an npm upgrade (full story in [`vps_oracle/compose/npm/README.md`](../../compose/npm/README.md)).

Implemented (ccr gateway layer):
- `ccr-tool-schema-rejections.sh` (alert) — reads ccr's `request-logs.sqlite` and flags requests the upstream provider refused because of a tool schema. It is deliberately narrow: it matches the schema-rejection signatures only, never the general non-2xx rate, because a bad request, an expired key and a context-length overflow all legitimately produce 4xx and a general alert would be noise — whereas a schema rejection is never transient and never something the caller asked for. The database is `700 root:root` inside ccr's data volume and this host has no sqlite3, so the query runs in the container's own node (`docker exec -i ccr node`, with `NODE_OPTIONS` cleared so ccr's own preload middleware does not run for a read-only read). Added after the 2026-09-25 incident where switching a group to DeepSeek silently broke every older session in it, one 400 per turn, and nothing outside ccr's own request log recorded why (full story in [`docs/incidents/2026-09-25-ccr-deepseek-artifact-schema-400.md`](../../../docs/incidents/2026-09-25-ccr-deepseek-artifact-schema-400.md)).

Thresholds are env vars at the top of each script, overridable from the systemd unit's `Environment=` or when running manually.

**Scope boundary**: `vscode-server-versions.sh` only cleans the large `cli/servers/<version>/` directories (each in the 500-650M range), and leaves `~/.vscode-server/code-<commit>` — the much smaller CLI tunnel binaries (~27M each) — alone; the spec didn't list them in scope. Add a new check later if there's a desire to expand.

## Running

```bash
cd vps_oracle/host-native/inspector
./inspect.sh                    # a real run, sends Telegram
INSPECTOR_DRY_RUN=1 ./inspect.sh  # only prints would-kill/would-delete, acts on nothing
```

## Testing

The engine's own tests are the only ones in this directory — every check's test sits beside that check, in the same tree.

```bash
cd vps_oracle/host-native/inspector
./tests/test-common.sh     # the kill-tree safety rules themselves
./tests/test-inspect.sh    # NOT hermetic on its last leg: it runs the real inspect.sh and posts to the real apprise instance, so the Telegram group must be reachable

# every check tree, the way CI does it:
cd "$(git rev-parse --show-toplevel)"
for t in vps_oracle/host-native/inspector/tests/test-*.sh */inspector-checks/tests/test-*.sh; do
  case "$(basename "$t")" in test-common.sh|test-inspect.sh) continue ;; esac
  ./"$t" >/dev/null || echo "FAIL $t"
done
```

`tests/test-common.sh` is the most important test in the whole project — it verifies the "never mistakenly kill yourself" rule itself, which can't be left to eyeballing the code; see the spec's "self-protection rules" section.

Check tests live next to their checks in all four trees: `vps_oracle/inspector-checks/tests/`, `vps_oracle2/inspector-checks/tests/`, `vps_gcp/inspector-checks/tests/` and `k3s/inspector-checks/tests/`. CI runs every one of them with the glob above.

## Deploy

```bash
sudo ln -sf $(pwd)/systemd/docker-gitops-inspector.service /etc/systemd/system/
sudo ln -sf $(pwd)/systemd/docker-gitops-inspector.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now docker-gitops-inspector.timer
```

Use symlinks, not copies — after editing code and `git pull`/`git commit`, it's live without running a separate install.sh (see the claude-code-notify lesson: a separate install step is easy to forget to run). You only need to re-`daemon-reload` when the unit file structure itself changes (not the contents of `inspect.sh`).

Trigger once manually: `sudo systemctl start docker-gitops-inspector.service`; see the result: `sudo systemctl status docker-gitops-inspector.service` / `journalctl -u docker-gitops-inspector.service -n 50`.

## k3s access (one-time setup for phase 2)

The k3s checks don't use the admin kubeconfig; they use a least-privilege SA (`inspector/docker-gitops-inspector`: pods/jobs get+list+delete, PV/nodes/resourcequotas/replicasets get+list, everything else denied — notably secrets and configmaps, which `setup-kubeconfig.sh` asserts stay unreadable):

```bash
cd vps_oracle/host-native/inspector
./k3s/setup-kubeconfig.sh     # apply RBAC + write state/kubeconfig (gitignored, 600)
```

The script is idempotent and safe to rerun. The RBAC manifest is at `k3s/rbac.yaml` — not under `k3s/manifests/` (that's ArgoCD territory, see k3s/README). The `inspector` namespace where the SA lives is managed by ArgoCD (`manifests/namespace-inspector.yaml`), so on a brand-new machine you must wait for ArgoCD to sync the namespace before running this script.

**2026-08-21 migration**: the SA used to live in `workloads` (borrowing its quota). It has moved to a dedicated `inspector` namespace; the old `workloads/docker-gitops-inspector` SA will be deleted by hand after ArgoCD syncs. The token already embedded in state/kubeconfig belongs to the pre-migration SA and still works — rerunning the setup script switches to the new SA.

Two checks use passwordless `sudo -n` (both read-only enumeration or a single cleanup command): `docker-oversized-logs.sh` (reads `/var/lib/docker/containers`) and `k3s-containerd-images.sh` (the `crictl` socket is root-only). If NOPASSWD is ever revoked, these two checks will emit an alert in the report saying they were skipped, rather than hanging.

## apprise target

`inspector-tg` was registered on 2026-08-16 (reusing vikunja's existing bot token, pointed at the Telegram group "OCI System inspection"). apprise was migrated back to docker compose on 2026-08-18 (`vps_oracle/compose/apprise`), exposed to other containers only by container name inside the `proxy` network; the inspector is a host-native script not on any docker network, so the apprise compose additionally bound `127.0.0.1:8000:8000` for it, and the default `APPRISE_URL` changed to `http://localhost:8000` (see `lib/common.sh`).

## Go-live discipline

1. Run `INSPECTOR_DRY_RUN=1` a few rounds first, and check the report matches the actual state (especially: `stray-vscode-sessions.sh` must not judge a still-interactive session as stray).
2. After going live in real mode, watch the Telegram reports for a few days and confirm there are no mistaken kills before considering it stable — don't trust auto-kill the moment it goes live.
