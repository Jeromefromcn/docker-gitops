# Server-level Monitoring & Alerting System — Design (Prometheus + Grafana)

Date: 2026-07-30

## Background

We initially evaluated three options (Prometheus+Grafana / Netdata / Beszel+Uptime Kuma) and first chose Beszel+Uptime Kuma, fully implementing, deploying and validating one round. Implementation surfaced two hard limits in Beszel's data model:

1. The `alerts` collection has a `(user, system, name)` unique index, and `name` is a fixed metric enum, so **the same metric can only have one alert rule** — there is no room for warning/critical to coexist as two tiers.
2. Alert notifications have **no message templating capability** (there is an open feature request on GitHub; the official team hasn't built it yet), so the Telegram messages it sends are hard-coded English sentences with no way to add prominent colors/emoji to distinguish severity and recovery state.

Both are product limitations that were not anticipated during selection. After weighing the trade-offs we decided to start over and switch to Prometheus + Grafana — giving up some "lightweight" in exchange for configuration flexibility. The original Beszel/Uptime Kuma deployment, compose files and git commits (none of which were ever pushed) have been fully removed.

## Goals & Scope

Continuing the scope of the original design:

- **Host metrics**: CPU / memory / disk usage, two severity tiers (warning/critical)
- **Service availability probes**: whether existing HTTP(S) services and TCP ports are reachable
- **Alert channel**: Telegram, messages must be prominent (emoji/color to distinguish tiers), recovery must use green elements to visually separate from alerts

**Out of scope for this round** (YAGNI, explicitly excluded):
- Container-level metrics
- Log scanning / abnormal-keyword alerting
- Alertmanager (Grafana's built-in Unified Alerting connects to Telegram directly, so that component is skipped)

**Naming & message language**: alert rule names, config names inside Grafana, and Telegram notification message content are all in **English**. This design document itself is still written in Chinese.

## Architecture

A tightly-coupled monitoring system; the four components go into the **same** compose directory (`vps_oracle/compose/monitoring/`) because they form a one-way dependency chain with no standalone meaning when separated: Grafana's only data source is this Prometheus, and Prometheus's only scrape targets are these two exporters.

- **Prometheus**: scrapes, stores, evaluates alert rules
- **node_exporter**: host metric collection on this machine (the standard approach is to read-only bind mount the host's `/proc`, `/sys`, `/` into the container; `network_mode: host` is not needed)
- **blackbox_exporter**: service availability probing (HTTP/TCP), one configuration covering all probe targets
- **Grafana**: dashboards + alert evaluation + notification (Unified Alerting, no extra Alertmanager needed)

**Multi-host expansion**: a future new host only adds one node_exporter (placed in the new host's own directory, similar to the previous Beszel agent pattern), not a copy of the whole `monitoring` directory; that host's node_exporter must be reachable by this Prometheus (requires inter-host network reachability — a known cost of this option relative to Beszel/Uptime Kuma, already mentioned during the earlier evaluation: multi-host scenarios require wiring up exporter networking).

### Network & Exposure

- **Grafana**: HTTP UI, joins the `proxy` network, reverse-proxied via NPM (`grafana.jerome.cloudns.asia`), does not publish a host port
- **Prometheus**: not exposed externally, has no login auth; only reachable via `docker exec` or a local port for ad-hoc PromQL debugging
- **node_exporter / blackbox_exporter**: pure metrics endpoints, do not join the `proxy` network; they only need Prometheus to reach them over the docker internal network (within the same compose file the default network already interconnects)

### Persistence & Configuration Files

- `/etc/monitoring/prometheus-data`: Prometheus data
- `/etc/monitoring/grafana-data`: Grafana data (including dashboards, users, and other runtime state)
- The Prometheus/blackbox_exporter config files (`prometheus.yml`, `blackbox.yml`) are **application configuration, not runtime data**: committed to the repo and mounted read-only into the containers. Changing config means "edit file → git commit → `docker compose up -d`", not editing inside the container
- Grafana's alert rules, data sources, and Contact Points should go through **declarative provisioning** wherever possible (YAML files in a `provisioning/` directory, committed to the repo, auto-loaded at container start). This is the biggest improvement over Beszel — no more scripting API calls for the "query-then-add/update/delete" dance

## Secrets Handling

- **Grafana initial admin password**: injected via environment variables (`.env`, gitignored), not hard-coded in the compose file
- **Telegram bot token**: Grafana's provisioning YAML supports environment-variable placeholders (`${VAR}`); the actual token lives in `.env` and never enters git — the exact placeholder syntax must be verified against the Grafana version when writing the implementation plan, to avoid guessing the format wrong
- Prometheus, node_exporter and blackbox_exporter involve no secrets

## Alert Design

### Host Metrics (two severity tiers, restoring the original design)

| Metric | Warning tier | Critical tier |
|---|---|---|
| CPU | >75%, sustained 15 min | >90%, sustained 10 min |
| Memory | >70%, sustained 15 min | >85%, sustained 10 min |
| Disk usage | >75%, immediate | >85%, immediate |

Each rule gets a `severity: warning` or `severity: critical` label. Disk has no duration requirement (disk usage changes slowly, so reaching the threshold is essentially the real state); network traffic anomaly has no threshold for now (no historical baseline yet — collect data first). 6 alert rules in total.

### Service Availability Probes (blackbox_exporter, no tiers, binary state)

| Target | Probe method | Notes |
|---|---|---|
| `https://npm.jerome.cloudns.asia` | HTTP, module `http_2xx` | NPM admin panel |
| `https://panel.3x.jerome.cloudns.asia` | HTTP, custom module, accepts status codes including 404 | The panel uses random paths; a 404 at the root path is normal (see [migration doc](../../2026-07-26-npm-reverse-proxy-migration.md)) |
| `https://sub.3x.jerome.cloudns.asia/sub/` | HTTP, module `http_2xx` | subscription service |
| `jerome.cloudns.asia:39876` | TCP, module `tcp_connect` | VLESS node port |
| `https://portainer.jerome.cloudns.asia/` | HTTP, module `http_2xx` | Portainer admin panel |

Prometheus scrape interval and blackbox probe interval are recommended at 60 seconds, combined with Grafana alert rule's `for` field (e.g. only alert after being unreachable for 2 minutes) to avoid false positives from network jitter.

### Message Template (Grafana Unified Alerting — the core reason for switching in the first place)

Use Grafana's notification templates (Go template), generating the message prefix dynamically from the `severity` label and `$status` (firing/resolved):

- Firing + critical: `🚨🔴 CRITICAL: ...`
- Firing + warning: `⚠️🟠 WARNING: ...`
- Resolved: `✅🟢 RESOLVED: ...`

Verify the exact template syntax against the Grafana version's documentation when writing the implementation plan, to avoid syntax guessing.

## Deployment & Validation Steps (outline; concrete commands left to the implementation plan)

1. Deploy the `monitoring` compose stack (Prometheus + node_exporter + blackbox_exporter + Grafana)
2. Add a `grafana.jerome.cloudns.asia` reverse proxy rule in NPM
3. Verify Prometheus can scrape node_exporter/blackbox_exporter normally (check Prometheus's own targets page, accessed temporarily via a local port)
4. In Grafana, configure the Prometheus data source, Telegram Contact Point, 6 alert rules + message template
5. End-to-end verification: trigger one real metric alert and one probe alert separately, confirm Telegram receives the messages with the expected format (emoji/color clearly distinguished), then verify the recovery notification also works

## Future Expansion

- **Multi-host**: add a node_exporter compose on the new host (same pattern as the previous Beszel agent), ensuring Prometheus can reach it over the network (a known cost relative to Beszel/Uptime Kuma, already mentioned during the earlier option comparison).
- **Growth in uptime probe targets**: add to blackbox_exporter's targets list directly via the Prometheus config file; no extra dependency to introduce.