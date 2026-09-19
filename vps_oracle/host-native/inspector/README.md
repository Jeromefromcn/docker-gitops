# vps_oracle/host-native/inspector

Host-level inspection script, not managed by docker compose (like `vps_oracle/host-native/host-firewall/` and `vps_oracle/host-native/npm-nodeport-relay/`, it's a systemd service that runs directly on the host under `<host>/host-native/`; see the repo root README's "Directory structure" section). For the design background, tiering rules, and self-protection rules, see
[`docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md`](../../../docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md).

**Notification language**: the Telegram report title and body are English only (2026-08-16 user request; the repo docs remain Chinese). `tests/test-inspect.sh` has a corresponding assertion (title, section headers, no CJK characters).

## Status (phase 2)

Implemented (phase 1):
- `checks/stray-vscode-sessions.sh` — stray/stuck claude sessions, disconnected server-main trees
- `checks/vscode-server-versions.sh` — piled-up `.vscode-server/cli/servers/*` version directories

Implemented (phase 2, docker layer):
- `checks/docker-stopped-containers.sh` (auto) — containers exited for more than 7 days
- `checks/docker-dangling-images.sh` (auto) — images dangling for more than 7 days
- `checks/docker-build-cache.sh` (auto) — build cache older than 7 days
- `checks/docker-unused-networks.sh` (auto) — custom networks with no containers attached
- `checks/docker-restart-storms.sh` (alert) — abnormally high RestartCount / stuck in Restarting
- `checks/oracle2-docker-restart-storms.sh` (alert) — the same check run against vps-oracle2's docker daemon over SSH (`DOCKER_HOST=ssh://ubuntu@vps-oracle2`, override with `INSPECTOR_ORACLE2_DOCKER_HOST`). Alert targets are prefixed `[vps-oracle2]` (the report title only says vps_oracle), and an unreachable host raises `[vps-oracle2] check:docker-restart-storms.sh … docker daemon unreachable`, which doubles as a liveness check. Remote checks reuse a local script by setting `INSPECTOR_INSTANCE` + `DOCKER_HOST` and `exec`ing it
- `checks/docker-unused-volumes.sh` (alert) — volumes with no containers attached (anonymous aggregated into one line, named listed one per line)
- `checks/docker-compose-logging-drift.sh` (alert) — compose services missing `logging.options.max-size`
- `checks/docker-oversized-logs.sh` (alert) — `*-json.log` files over 50MiB each

Implemented (phase 2, k3s layer):
- `checks/k3s-evicted-pods.sh` (auto) — Failed leftover pods
- `checks/k3s-completed-jobs.sh` (auto) — Jobs completed for more than 3 days
- `checks/k3s-containerd-images.sh` (auto) — containerd images with no container referencing them (`sudo crictl`)
- `checks/k3s-released-pvs.sh` (alert) — Released PVs
- `checks/k3s-stuck-terminating.sh` (alert) — Terminating pods stuck for more than 15 minutes
- `checks/k3s-oom-killed-containers.sh` (alert) — `lastState.terminated.reason=OOMKilled` within the last 24 hours; `k3s-evicted-pods.sh` can't catch this case (the pod stays `Running` the whole time, only the container is killed and restarted), added after the 2026-08-17 io_pressure_critical incident (jaeger/trivy were both OOM-killed because their limits were too tight)

Implemented (NPM reverse proxy layer):
- `checks/direnv-envrc-trust.sh` (alert) — runs `direnv export bash` from each group dir (`~/jerome`, `~/bridget`, `~/evidence`) and flags any whose `.envrc` reports "is blocked", i.e. whose direnv trust was revoked because the file's content changed since it was last `direnv allow`ed. It is alert-only and never auto-allows: `direnv allow` is itself the trust mechanism, and a revoked `.envrc` must be human-reviewed before re-trusting (the file is arbitrary shell, and the symlinked `shell-env/*.envrc` changes take effect on the live system immediately). Added after the 2026-09-13 incident where a comment-only translation sweep revoked trust and silently froze group provider/account switching (full story in [`docs/incidents/2026-09-13-switchboard-direnv-envrc-trust-revoked.md`](../../../docs/incidents/2026-09-13-switchboard-direnv-envrc-trust-revoked.md)).
- `checks/npm-nginx-config.sh` (alert) — runs `nginx -t` inside the npm container. It catches the invisible "config works now, but the next cold start won't come up" state: NPM's Custom Location bakes the upstream hostname into `proxy_pass` (normal forwarding uses variables + Docker DNS, resolved per request), so once that backend container disappears, nginx refuses to start with an `emerg` on its next config load — and **all** reverse-proxy sites go down together, not just that one. The running nginx keeps going on the previously resolved address, so you can't see it from monitoring, the panel, or logs until restart. `nginx -t` uses the same resolution but runs in a separate process, so it doesn't affect the serving nginx. Added after the 2026-08-21 incident where the dify container was stopped for 45 hours and only blew up during an npm upgrade (full story in [`vps_oracle/compose/npm/README.md`](../../compose/npm/README.md)).

Thresholds are env vars at the top of each script, overridable from the systemd unit's `Environment=` or when running manually.

**Scope boundary**: `vscode-server-versions.sh` only cleans the large `cli/servers/<version>/` directories (each in the 500-650M range), and leaves `~/.vscode-server/code-<commit>` — the much smaller CLI tunnel binaries (~27M each) — alone; the spec didn't list them in scope. Add a new check later if there's a desire to expand.

## Running

```bash
cd vps_oracle/host-native/inspector
./inspect.sh                    # a real run, sends Telegram
INSPECTOR_DRY_RUN=1 ./inspect.sh  # only prints would-kill/would-delete, acts on nothing
```

## Testing

```bash
cd vps_oracle/host-native/inspector
./tests/test-common.sh
./tests/test-stray-vscode-sessions.sh
./tests/test-vscode-server-versions.sh
./tests/test-inspect.sh        # the last part actually hits apprise inspector-tg; the Telegram group must be reachable
./tests/test-docker-stopped-containers.sh
./tests/test-docker-dangling-images.sh
./tests/test-docker-build-cache.sh
./tests/test-docker-unused-networks.sh
./tests/test-docker-restart-storms.sh
./tests/test-docker-unused-volumes.sh
./tests/test-oracle2-docker-restart-storms.sh
./tests/test-docker-compose-logging-drift.sh
./tests/test-docker-oversized-logs.sh
./tests/test-k3s-evicted-pods.sh
./tests/test-k3s-completed-jobs.sh
./tests/test-k3s-containerd-images.sh
./tests/test-k3s-alerts.sh
./tests/test-k3s-oom-killed-containers.sh
./tests/test-npm-nginx-config.sh
./tests/test-direnv-envrc-trust.sh
```

`tests/test-common.sh` is the most important test in the whole project — it verifies the "never mistakenly kill yourself" rule itself, which can't be left to eyeballing the code; see the spec's "self-protection rules" section.

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

The k3s checks don't use the admin kubeconfig; they use a least-privilege SA (`inspector/docker-gitops-inspector`: pods/jobs get+list+delete, PV get+list, everything else denied):

```bash
cd vps_oracle/host-native/inspector
./k3s/setup-kubeconfig.sh     # apply RBAC + write state/kubeconfig (gitignored, 600)
```

The script is idempotent and safe to rerun. The RBAC manifest is at `k3s/rbac.yaml` — not under `vps_oracle/k3s/manifests/` (that's ArgoCD territory, see k3s/README). The `inspector` namespace where the SA lives is managed by ArgoCD (`manifests/namespace-inspector.yaml`), so on a brand-new machine you must wait for ArgoCD to sync the namespace before running this script.

**2026-08-21 migration**: the SA used to live in `workloads` (borrowing its quota). It has moved to a dedicated `inspector` namespace; the old `workloads/docker-gitops-inspector` SA will be deleted by hand after ArgoCD syncs. The token already embedded in state/kubeconfig belongs to the pre-migration SA and still works — rerunning the setup script switches to the new SA.

Two checks use passwordless `sudo -n` (both read-only enumeration or a single cleanup command): `docker-oversized-logs.sh` (reads `/var/lib/docker/containers`) and `k3s-containerd-images.sh` (the `crictl` socket is root-only). If NOPASSWD is ever revoked, these two checks will emit an alert in the report saying they were skipped, rather than hanging.

## apprise target

`inspector-tg` was registered on 2026-08-16 (reusing vikunja's existing bot token, pointed at the Telegram group "OCI System inspection"). apprise was migrated back to docker compose on 2026-08-18 (`vps_oracle/compose/apprise`), exposed to other containers only by container name inside the `proxy` network; the inspector is a host-native script not on any docker network, so the apprise compose additionally bound `127.0.0.1:8000:8000` for it, and the default `APPRISE_URL` changed to `http://localhost:8000` (see `lib/common.sh`).

## Go-live discipline

1. Run `INSPECTOR_DRY_RUN=1` a few rounds first, and check the report matches the actual state (especially: `stray-vscode-sessions.sh` must not judge a still-interactive session as stray).
2. After going live in real mode, watch the Telegram reports for a few days and confirm there are no mistaken kills before considering it stable — don't trust auto-kill the moment it goes live.
