# vps_oracle/host-native/cc-window

Host-native service, not managed by docker compose (like `vps_oracle/host-native/inspector/` and `vps_oracle/host-native/host-firewall/`, it's a systemd service that runs directly on the host under `<host>/host-native/`; see the repo root README's "Directory structure" section).

## What this is

[cc-window](https://github.com/pickjason/cc-windows) (npm package name `cc-window`) is a third-party local web dashboard for Claude Code multi-session management: monitor every `claude` CLI session on the machine from one screen, create new sessions from the web UI, and operate each session's interactive terminal. The source is not vendored into this repo — only a pinned version is installed via `npm install -g`; this directory only manages the systemd residency + deployment config.

## Why not docker

Its core mechanism means containerizing it fights its own design directly, not just a "can we package it" question:

- It polls `claude agents --json` to get the whole-machine session roster, so the `claude` CLI must be installed on the same environment's `PATH` and already logged in
- Session state comes from `~/.claude/projects/**/*.jsonl`, `~/.claude/monitor/events.jsonl` (written by hooks), and `~/.claude/settings.json`, all under the host user's home
- Sessions themselves are launched via `node-pty` and bridged to a dedicated tmux socket (`ccwindow`) — if you want to manage sessions you open directly in the host shell, it must share the same tmux socket as the host, which means giving up container isolation

So the whole thing runs in the host's native environment: `node`/`npm`, `tmux`, and the logged-in `claude` CLI are all already on this machine (see "Environment check" below).

## Security: no built-in auth, must sit behind an access list

cc-window states this plainly in its own docs: **there is no built-in auth token — any process that can reach the port can control your sessions**. Therefore:

- `CC_HOST` is not pinned to the official default `127.0.0.1`, for the reason in "Why `CC_HOST` is `172.19.0.1` not `127.0.0.1`" below — but it similarly **only** listens on an address unreachable from the public internet, never exposed externally
- External access goes only through NPM reverse proxy, and the proxy host's Access List is **`self-only-and-auth`** (id 2, which allows the same source IPs as `self-only` while additionally requiring Basic Auth — the four existing "no-built-in-auth management panels" in this repo all use it), not the default `self-only`
- Never set `CC_HOST` to `0.0.0.0` or the host's public network interface (`10.0.0.95`)

### Why `CC_HOST` is `172.19.0.1` not `127.0.0.1`

cc-window runs in the host's native environment, where `127.0.0.1` is the host's own loopback. NPM runs as a container on the `proxy` docker bridge network; its network namespace **does not have** the host's loopback, so it can't reach a service bound to `127.0.0.1` — the same class of problem as the "container can't reach a host service" case recorded in `vps_oracle/host-native/npm-nodeport-relay/README.md`.

The `proxy` network is a manually created `external: true` network (`docker network create proxy`, see `vps_oracle/compose/npm/docker-compose.yml`), with a gateway fixed at `172.19.0.1` (verifiable via `docker network inspect proxy`; it's bound to the host's `br-99f461e27ed6` interface — an address the host itself really owns, not some container's IP). cc-window binds this address directly:

- The NPM container is itself on the `proxy` network, so the gateway address is natively reachable, no extra relay needed
- This address is not a public interface; Oracle's public traffic can't reach it, so the exposure surface is effectively equivalent to binding `127.0.0.1` — just a different address that's "internal-only reachable"
- It uses the same manually created network (which doesn't get recreated by any single compose run) as `3x-ui` (`172.19.0.2`) and `npm` (`172.19.0.3`), so stability has precedent

The risk note is the same as the two pinned-IP entries (3x-ui/npm) in the npm README: if the `proxy` network is ever deleted and recreated, the gateway address could in theory change (usually it won't, because it's a manually created `external` network unaffected by any single compose's `up`/`down`) — keep it in mind.

## Environment check (2026-08-24)

| Dependency | Version | Notes |
|---|---|---|
| Node.js | v20.20.2 | Meets cc-window's `>=20` requirement |
| tmux | 3.4 | Supports local terminal handoff and sessions surviving service restarts; without it, it degrades to direct `node-pty` (stopping the service ends the session) |
| `claude` CLI | `/home/ubuntu/.local/bin/claude`, logged in | `claude agents --json` verified working |
| npm global prefix | `/usr` | `npm install -g` needs `sudo`; the binary lands at `/usr/bin/cc-window` |

The "open local terminal in one click" handoff depends on `osascript` + Terminal.app, macOS-only; this is a Linux VPS, so that feature degrades to copying a `tmux attach` command, with everything else unaffected.

## Install

Pin a version, don't use `npx`/`latest` — same rationale as this repo's "image version pinning" convention: avoid the systemd service silently changing behavior because upstream shipped a new version.

```bash
sudo npm install -g cc-window@0.2.1
```

To upgrade: change the version number in this README + rerun the command above, then `sudo systemctl restart cc-window.service`, run a few rounds and confirm it's healthy before considering it done.

## Deploy

Two units: `cc-window.service` (the service itself) + `cc-window-tmux.service` (a separate tmux server, the PTY backend). `ExecStart` points at the globally installed binary path (`/usr/bin/cc-window`), not a file in this repo, so copy rather than symlink:

```bash
sudo cp cc-window.service cc-window-tmux.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cc-window-tmux.service   # start the tmux server first
sudo systemctl enable --now cc-window.service
```

**Why tmux has to be its own service (fixed 2026-08-24)**: cc-window's tmux backend needs a persistent tmux server on the `ccwindow` socket. If tmux is started via `ExecStartPre` inside `cc-window.service`, systemd treats the `ExecStartPre` tmux server as a left-over process of the main service's cgroup and cleans it up after `ExecStart` runs (observed in logs as `Found left-over process (tmux: server)`, the server vanishing after restart) — so when the web UI "new session" tries `tmux new-session`, it can't create an interactive terminal and can't approve/answer. A separate `cc-window-tmux.service` lets the tmux server live in its own cgroup, unaffected by cc-window restarts; the `cc-window-guard` session inside keeps the server alive so it doesn't self-terminate when idle. `cc-window.service` uses `After/Wants=cc-window-tmux.service` to guarantee ordering.

## Verify

```bash
systemctl status cc-window.service cc-window-tmux.service
tmux -L ccwindow ls                                    # expect to see cc-window-guard (the resident server)
curl -sS -o /dev/null -w '%{http_code}\n' http://172.19.0.1:4317/   # expect 200
# after a web "new session", you should see a ccw_<uuid> tmux session with claude running in its pane
tmux -L ccwindow ls
```

## NPM reverse proxy + homepage

Use the standard fields from the repo root README's "Connect a service to the NPM reverse proxy" section for the proxy config, with Access List `self-only-and-auth` (see the "Security" section above, not the default `self-only`):

| Field | Value |
|---|---|
| Domain Names | `cc-window.jerome.cloudns.asia` |
| Forward Hostname / IP | `172.19.0.1` (the `proxy` network gateway address cc-window binds, see "Why `CC_HOST` is `172.19.0.1`" above; it's not a container, so you can't fill in a service name and rely on Docker DNS) |
| Forward Port | `4317` |
| Access List | `self-only-and-auth` |

The homepage card is in `vps_oracle/compose/homepage/config/services.yaml`.

## Live status (2026-08-24)

| Item | Value |
|---|---|
| NPM proxy host | id **32**, `cc-window.jerome.cloudns.asia` |
| Certificate | Let's Encrypt (HTTP-01), id **35**, `/etc/letsencrypt/live/npm-35/`, expires 2026-11-22 |
| Access List | `self-only-and-auth` (id 2, includes Basic Auth account `jerome`) |
| host firewall | `-s 172.19.0.3/32 -p tcp --dport 4317 -j ACCEPT` (see [`host-firewall.sh`](../host-firewall/host-firewall.sh), added 2026-08-24) |

**Verification** (full chain, from the NPM container's perspective):

```bash
docker exec npm curl -sS -o /dev/null -w '%{http_code}\n' https://cc-window.jerome.cloudns.asia/        # 401 (no Basic Auth -> blocked by access list)
docker exec npm curl -sS -o /dev/null -w '%{http_code}\n' -u jerome:<password> https://cc-window.jerome.cloudns.asia/   # 200 (HTTP/2, x-powered-by: Express)
```

New-domain certificate: in the NPM panel → SSL Certificates → Add → Let's Encrypt, fill Domain Names with `cc-window.jerome.cloudns.asia` (wildcard DNS already covers it, no new A record needed; auto-renewal runs via NPM's certbot).
