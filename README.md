# docker-gitops

Central management of the Docker Compose configurations running on all servers, as the single source of truth.

## Directory structure

```
docker-gitops/
└── <host>/                # grouped by server, e.g. vps_oracle
    ├── compose/            # all docker compose stacks on that server
    │   └── <compose>/      # one directory per compose stack (may contain multiple services)
    │       └── docker-compose.yml
    └── host-native/        # systemd services running directly on the host (not containers)
        └── <service>/      # one directory per service: README + systemd unit
```

Besides `compose/`, a `<host>/` may also contain other subdirectories that are not managed by docker compose: `k3s/` (a cluster managed by ArgoCD GitOps — changes go through git push + ArgoCD sync, not manual commands; see `vps_oracle/k3s/README.md`), `dotfiles/` (symlinked local-machine configuration; see `vps_oracle/dotfiles/README.md`), and `host-native/` (explained below). Each follows its own conventions; see the corresponding subdirectory's README.

## host-native (systemd services running directly on the host)

Each subdirectory under `vps_oracle/host-native/` corresponds to a service that doesn't fit in docker compose — it needs to touch the host namespace, a user home such as `~/.claude`, iptables, or similar — so it runs as a persistent systemd unit, and the unit file plus the source code (or a third-party package's deploy config) are checked into this repo:

| Subdirectory | What it is |
|---|---|
| [`inspector/`](vps_oracle/host-native/inspector/README.md) | host-native bash inspection scripts, triggered by a systemd timer daily at 09:00/21:00, that detect and clean up stray VS Code/Claude session process trees and accumulated `.vscode-server` version directories, and send one English Telegram report per run. See the [design doc](docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md) for the background (self-protection rules, auto/alert tiers) |
| [`host-firewall/`](vps_oracle/host-native/host-firewall/README.md) | the single source of truth for the hand-written iptables rules, applied as a systemd oneshot at boot |
| [`npm-nodeport-relay/`](vps_oracle/host-native/npm-nodeport-relay/README.md) | a TCP relay in the host netns that lets NPM (a docker container) reach the k3s NodePort that only the host can reach |
| [`cc-window/`](vps_oracle/host-native/cc-window/README.md) | a third-party Claude Code multi-session management console (`npm install -g cc-window`), a local web dashboard |

## k3s (cloud-native experiment platform, in progress)

`vps_oracle/k3s/` is a multi-phase project that replicates a cloud-native dev/ops experiment platform on the same machine using K3s — the goal is to migrate compose stacks to k8s **service by service**, keeping the public domain/port unchanged and deciding per-service whether the compose deployment stays or goes, not to replace the whole existing architecture. See the [K3s cloud-native platform roadmap](docs/superpowers/specs/2026-08-05-k3s-cloud-native-platform-roadmap.md) for the full background and the phase breakdown (A cluster foundation → B GitOps bootstrap → C migration template → D remaining services migration → E supply chain security → F multi-environment lanes → G service mesh → H compose decommission assessment), and [`vps_oracle/k3s/README.md`](vps_oracle/k3s/README.md) for each phase's install/ops details.

As of now (phase F+G complete, H not started): the cluster foundation (K3s + Cilium + local-path storage) and the ArgoCD app-of-apps GitOps loop remain on k3s; `homepage`/`trilium`/`dify`/`vikunja`/`apprise`/`llm` (llama-cpp/open-webui) — i.e. every service migrated in phase C+D — were assessed on 2026-08-18 and migrated back to compose (see [migration plan one](docs/superpowers/plans/2026-08-18-k3s-to-compose-migration.md) and [migration plan two](docs/superpowers/plans/2026-08-18-k3s-to-compose-migration-part2.md)); `evidence-os-website` (originally k3s-native, with no compose predecessor) moved into compose the same day. Only two k3s-native services stay on k3s: `lab-environment` and `headlamp` (see their sections below), plus the `pr-lanes` namespace added in phase F+G and driven by the Istio Ambient service mesh (`hello-frontend`/`hello-backend`, a PR-preview-lane practice environment that replaces the retired `placeholder-hello`; see the "Istio Ambient / PR Lanes" section of [`vps_oracle/k3s/README.md`](vps_oracle/k3s/README.md) for the mechanism). Every other service still runs under `<host>/compose/`; see "Services that will not migrate to k3s" below.

### Services that will not migrate to k3s

The following services were assessed and decided to stay on compose, not queued for any migration phase:

| Service | Why it stays |
|---|---|
| `npm` | It is the anchor for the "public domain/port stay unchanged" migration promise — every A~D migration is "get it working on k3s first, then change the NPM forwarding rule", so NPM itself can't be changing at the same time, or you'd be moving the anchor and the thing it pins simultaneously, compounding the risk. And NPM's "migration" might in practice mean replacing it with a k8s-native ingress + cert-manager rather than containerizing NPM itself — but that judgement only has a basis after phase D is fully migrated and stable. Deliberately left for phase H assessment |
| `portainer` | it manages **all** docker containers on the host by reading/writing the docker socket (including two projects not managed by this repo). k3s uses containerd, not docker, so portainer can't see pods — moving this container into k3s is pointless; an equivalent visual panel on the k8s side should use a k8s-native solution (the ArgoCD UI already is one) rather than migrating portainer itself |
| `monitoring` (prometheus/node-exporter/blackbox-exporter/grafana) | node-exporter reads the host's `/proc`/`/sys` via a bind mount and monitors **the host itself**; blackbox-exporter probes the liveness of external endpoints. If this monitoring system were moved into k3s, an outage of the cluster itself would take the monitoring down with it, violating the observability principle that monitoring must be independent of what it monitors |
| `ccr` / `switchboard` | CCR's consumer is the `claude` CLI process running on **the host itself** (not a container), which can't use the docker network, so CCR exceptionally publishes its port and deliberately binds `127.0.0.1` to avoid external exposure (see `docs/superpowers/specs/2026-08-09-claude-provider-group-switch-design.md`). The same logic holds under k3s: k3s's pod network is equally "external" to a host process, so you'd either expose a NodePort and give up the `127.0.0.1`-only isolation or stay on the host layer — architecturally it doesn't suit migration, independent of any risk assessment. switchboard is CCR's companion switch (now generalized into a config-driven switch framework, of which jerome-ccr/bridget-ccr are just two switches), same reasoning |
| `3x-ui` | 39876 is a raw VLESS+Reality TCP that clients connect to directly, not over an HTTP reverse proxy, and it has a real fault history (see `docs/incidents/2026-07-24-3x-ui-vless-unreachable.md`). The compose deployment also has a key design: a pinned static IP (`172.19.0.2`) plus xray's own DNS hosts override keeps the "reach self-hosted services back through the VLESS tunnel" traffic inside the docker `proxy` network, going straight to NPM without leaving the host or being SNATed — and NPM's access list whitelists exactly this static IP. k3s's pod network (Cilium) and the docker bridge are two separate networks, so migration would break this internal direct path and require rebuilding it (e.g. whitelisting the node IP instead); on top of that, any k8s approach (widening the NodePort range requires restarting k3s, hostNetwork conflicts with future PSS/Kyverno) would touch a well-running production port — the risk/reward is lopsided, so it is **not migrating for now** |

## How things are worked on

The repo directory is itself the service's runtime directory — run compose commands directly in the corresponding compose directory:

```bash
cd ~/jerome/docker-gitops/<host>/compose/<compose> && docker compose up -d
```

Mounted volumes in the compose files uniformly use absolute paths (e.g. `/etc/x-ui/...`), so moving the working directory into the repo doesn't affect where the container data lives.

Some compose stacks have their own README (recording stack-specific steps/gotchas) — check for one before entering a directory: [`ccr/README.md`](vps_oracle/compose/ccr/README.md), [`dify/README.md`](vps_oracle/compose/dify/README.md), [`npm/README.md`](vps_oracle/compose/npm/README.md), [`switchboard/README.md`](vps_oracle/compose/switchboard/README.md).

## Adding a service

See [`.claude/skills/add-service/SKILL.md`](.claude/skills/add-service/SKILL.md) for the full flow (build stack → prod/dev pools for shared resources → start → NPM reverse proxy → homepage card → commit, with a closing self-check list).

## Wiring a service into the NPM reverse proxy

See [`.claude/skills/npm-proxy-host/SKILL.md`](.claude/skills/npm-proxy-host/SKILL.md) for the full flow — the field tables for the Details/SSL tabs, the [`add-proxy-host.sh`](vps_oracle/compose/npm/add-proxy-host.sh) script usage, and three gotchas that all **fail silently** (the SSL toggle resetting itself after save, having to enter the host's internal IP rather than a hostname when reverse-proxying to a k3s NodePort, and the API writing `locations` into the database without re-rendering the on-disk config).

**The most critical one is repeated here**: avoid Custom Locations whenever possible. Normal forwarding puts the upstream hostname in a variable and resolves it per-request, so a missing backend only breaks that one site; but **every Custom Location bakes the hostname into `proxy_pass`**, and a literal upstream must resolve successfully at config load time or nginx refuses to start with `[emerg]` — **taking down all reverse-proxied sites at once**. A running nginx shows no anomaly; it only explodes at the next cold start (host reboot, `docker compose up -d`, image upgrade). This is exactly how it blew up during a 2026-08-21 NPM upgrade — full-site outage of about 90 seconds. Prefer letting each service's own nginx/gateway handle path-based routing; when stopping a stack, disable its proxy host at the same time.

## Adding a homepage card for a new service

homepage was migrated back from k3s to compose on 2026-08-18 (see the "k3s" section above); its config source file is **`vps_oracle/compose/homepage/config/services.yaml`**. See step 5 of [`.claude/skills/add-service/SKILL.md`](.claude/skills/add-service/SKILL.md) for the card format, icon naming rules, and the exception that security-sensitive services (such as 3x-ui) don't get a card. After editing, run `cd vps_oracle/compose/homepage && docker compose up -d` to apply it directly — no push/ArgoCD needed.

## Wiring Telegram notifications for a Vikunja project (via vikunja-notify-relay + Apprise)

Vikunja's task events (assignment/reminder-due/overdue/completion) are forwarded over webhook to `vikunja-notify-relay` (the second service in the `vps_oracle/compose/vikunja` stack, which composes a message carrying the project name / task title / task hyperlink), and then to `apprise`, which routes by Vikunja account to each account's own Telegram (one target per account, not a shared one). See [`docs/2026-08-03-vikunja-apprise-telegram-webhooks.md`](docs/2026-08-03-vikunja-apprise-telegram-webhooks.md) for the mechanism, the known limitations (no true global webhook), and the script usage for adding webhooks to a new project. Relay code: [`vps_oracle/compose/vikunja/notify-relay/`](vps_oracle/compose/vikunja/notify-relay/); registration script: [`vps_oracle/compose/vikunja/register-telegram-webhooks.sh`](vps_oracle/compose/vikunja/register-telegram-webhooks.sh).

## Conventions

The conventions for authoring compose files — timezone (including the tzdata silently-falls-back-to-UTC gotcha), log size limits, minimal port exposure, least privilege, restart policy, network isolation and static-IP registry, and English for outward-facing content — are maintained in one place: [`.claude/rules/compose-conventions.md`](.claude/rules/compose-conventions.md). That file is the single authority; humans and Claude read the same one.

Three other rule files: k3s/ArgoCD change discipline is in [`.claude/rules/k3s-gitops.md`](.claude/rules/k3s-gitops.md), OpenTofu adoption/free-tier/version red-lines in [`.claude/rules/tofu-conventions.md`](.claude/rules/tofu-conventions.md), and which layer a piece of documentation belongs in is in [`.claude/rules/docs-layout.md`](.claude/rules/docs-layout.md).

## Host list

| Host | Description | Details |
|---|---|---|
| vps_oracle | Oracle Cloud VPS | [vps_oracle/README.md](vps_oracle/README.md) |
| vps_gcp | GCP free-tier e2-micro (only the `tofu/` layer is managed) | [vps_gcp/README.md](vps_gcp/README.md) |

Other background/history material (incident records, design archives, etc., not required daily reading) is in [`docs/README.md`](docs/README.md).