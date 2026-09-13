# Server-level Monitoring Dashboard — Design (Grafana Dashboard)

Date: 2026-07-30

## Background

The Prometheus + Grafana alerting system in `vps_oracle/compose/monitoring` (see [server-monitoring-design.md](2026-07-30-server-monitoring-design.md)) has been deployed: Prometheus scrapes node_exporter/blackbox_exporter, and Grafana handles alert evaluation + Telegram notification. Alerting solves "notify me when a threshold is breached," but there is currently no visualization dashboard you can open to see "how the server is doing overall right now." This round fills that gap — a dashboard for common metrics such as CPU, memory, disk and network.

## Goals & Scope

- A server-level monitoring dashboard scoped to the single machine (vps_oracle): CPU, memory, disk, network and other common metrics.
- Reuse the already-deployed Prometheus data source (`uid: prometheus`, see Task 3 datasource provisioning) and the metrics scraped by node_exporter (`job_name: node`).

**Out of scope for this round**:
- Adding or changing any alert rules (Task 6/7's host-metrics-rules.yml / probe-rules.yml stay untouched).
- Changing node-exporter's `network_mode` (see "Network metric accuracy" below).
- Multi-host template variable expansion (there is only one host for now, so no extra design beyond the `$host` / `$instance` multi-select dropdown).

## Implementation Approach

Continuing this repo's declarative provisioning principle for Grafana (data sources and alert rules are committed as YAML and auto-loaded at container start), the dashboard follows the same pattern rather than being hand-clicked in the UI:

- Add `vps_oracle/compose/monitoring/grafana/provisioning/dashboards/dashboards.yml` — the dashboard provider config, declaring a provider pointing at a local JSON directory, with `updateIntervalSeconds` set to periodically reload from disk (later JSON changes need no container restart).
- Add `vps_oracle/compose/monitoring/grafana/provisioning/dashboards/node-exporter-full.json` — download the latest version of the community-maintained **Node Exporter Full** (dashboard ID `1860`) JSON from the official Grafana dashboard repo (grafana.com), pin the version and commit it into this repo (not fetched from the network at Grafana runtime, consistent with the "config-as-code, auditable, offline-capable" principle).

**Adaptation points after download**:
1. Fix-replace the datasource template variables / input items in the JSON (the community dashboard typically asks "choose your Prometheus data source" on import) with the already-created `uid: prometheus` from Task 3, so import needs no manual data source selection.
2. Confirm the dashboard's `job` variable default value / regex matches the `job_name: node` configured in `prometheus.yml` (otherwise panels show "No data").

**Folder**: `Monitoring` (same folder as the existing `host-metrics-rules.yml` / `probe-rules.yml` / `self-monitoring-rules.yml`, so all monitoring-related content is viewable in one place).

## Compatibility Verification

Dashboard 1860 is a long-lived, community-maintained dashboard. Early versions included Angular panels (Grafana began deprecating them in 9.x, and recent versions have fully removed Angular panel support); newer versions have switched to modern panel types like timeseries. The currently deployed Grafana is `13.1.1`. The implementation phase must actually import and verify:

- Whether each panel renders correctly (any "panel plugin not found"-style errors).
- If individual panel types turn out to be incompatible, drop that panel or replace it with an equivalent modern panel type — don't abandon the whole dashboard because one panel errors.

## Network Metric Accuracy

Keep the architectural decision from [server-monitoring-design.md](2026-07-30-server-monitoring-design.md): node-exporter uses a bind mount (`/:/host:ro,rslave` + `--path.rootfs=/host`) rather than `network_mode: host`, to avoid host network / port conflicts / loopback debugging complexity that was repeatedly hit with the earlier Beszel approach, and because this VPS has a public IP — host networking would directly expose the unauthenticated metrics port on the public NIC.

The cost: the network usage panels see the node-exporter container's own veth NIC data, not the host's real NIC (public/private) throughput. This round does not change that architectural decision — the network panels display as-is, useful only for trend (is traffic rising or falling), and must not be treated as the host's real absolute bandwidth.

## Validation Steps

1. After deployment, open "Node Exporter Full" in the Grafana UI (`https://grafana.jerome.cloudns.asia`) → Dashboards → Monitoring folder.
2. Confirm the CPU / memory / disk panels all show real, non-error data (not "No data" or "panel plugin not found").
3. Confirm the network panels show data (even if the values correspond to the container veth rather than the host's real NIC).
4. Confirm the dashboard appears under the `Monitoring` folder, not mixed in with the existing alert rules.

## Future Expansion

- If multiple hosts join this Prometheus later, the dashboard's `job`/`instance` variable dropdowns natively support multi-select with no JSON changes needed.
- If hard accuracy on network traffic is required, a safer alternative is to later add a separate mechanism that exposes no port and only does host-network metrics collection (e.g. textfile collector + cron script), rather than switching node-exporter's `network_mode` wholesale.