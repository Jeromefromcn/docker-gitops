# Server Monitoring Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Grafana dashboard to the existing `vps_oracle/compose/monitoring` stack showing CPU, memory, disk, and network metrics for the vps_oracle host, provisioned declaratively (no manual UI import), per [docs/superpowers/specs/2026-07-30-server-monitoring-dashboard-design.md](../specs/2026-07-30-server-monitoring-dashboard-design.md).

**Architecture:** Reuse the community-maintained "Node Exporter Full" dashboard (grafana.com ID `1860`), downloaded once and committed as a pinned JSON file, adapted to reference the existing fixed `prometheus` datasource uid. Grafana's file-based dashboard provisioning (same declarative pattern already used for the datasource and alert rules) loads it automatically from the `provisioning/` directory that's already bind-mounted into the container — no `docker-compose.yml` changes needed.

**Tech Stack:** Grafana `13.1.1` dashboard JSON model + file provisioning (`apiVersion: 1` dashboards provider), `curl`, `jq`.

## Global Constraints

- Never commit secrets — use `.env` (gitignored), never inline values in compose files. (Not applicable to this plan — no secrets involved.)
- Pin image tags/digests. No `latest`. (No new images in this plan.)
- One change per commit, scoped to one compose stack.
- After editing a file here, apply it: `cd vps_oracle/compose/monitoring && docker compose up -d`.
- **Confirm with the user before running any `docker compose up -d` or other command that creates/recreates a container on the live VPS.**
- Grafana dashboard titles/folder names are in **English**.
- Do not modify `node-exporter`'s `network_mode` or any alert rule file (`host-metrics-rules.yml`, `probe-rules.yml`, `self-monitoring-rules.yml`) — out of scope per the design spec.
- The network-traffic panels in this dashboard will show the node-exporter container's own veth interface, not the host's real NIC — this is a known, accepted limitation (see design spec), not a bug to fix in this plan.

---

### Task 1: Dashboard provider provisioning config

**Files:**
- Create: `vps_oracle/compose/monitoring/grafana/provisioning/dashboards/dashboards.yml`

**Interfaces:**
- Consumes: nothing new (the `./grafana/provisioning:/etc/grafana/provisioning:ro` bind mount already exists in `docker-compose.yml:79`).
- Produces: a dashboard provider named `Monitoring` that Task 2's JSON file lands in the `Monitoring` Grafana folder (same folder used by `host-metrics-rules.yml`/`probe-rules.yml`/`self-monitoring-rules.yml`) and auto-reloads every 30s from disk.

- [ ] **Step 1: Write the dashboard provider config**

```yaml
# vps_oracle/compose/monitoring/grafana/provisioning/dashboards/dashboards.yml
apiVersion: 1

providers:
  - name: Monitoring
    orgId: 1
    folder: Monitoring
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: /etc/grafana/provisioning/dashboards
      foldersFromFilesStructure: false
```

- [ ] **Step 2: Confirm with the user, then apply**

```bash
cd vps_oracle/compose/monitoring && docker compose up -d
```

- [ ] **Step 3: Verify Grafana picked up the provider**

```bash
docker logs grafana 2>&1 | grep -i "dashboard"
```
Expected: a log line indicating the `Monitoring` file provider was registered, no error about the `dashboards.yml` file itself (there will be no dashboards found yet — that's expected until Task 2).

- [ ] **Step 4: Commit**

```bash
git add vps_oracle/compose/monitoring/grafana/provisioning/dashboards/dashboards.yml
git commit -m "Add Grafana dashboard provider for the Monitoring folder"
```

---

### Task 2: Import and adapt the Node Exporter Full dashboard

**Files:**
- Create: `vps_oracle/compose/monitoring/grafana/provisioning/dashboards/node-exporter-full.json`

**Interfaces:**
- Consumes: the `Monitoring` dashboard provider from Task 1; the `prometheus` datasource uid from `grafana/provisioning/datasources/prometheus.yml` (already provisioned); the `node` job scraping `node-exporter:9100` from `prometheus/prometheus.yml`.
- Produces: a dashboard titled "Node Exporter Full" visible in Grafana's `Monitoring` folder, showing CPU/memory/disk/network panels for the `node-exporter:9100` target.

- [ ] **Step 1: Download the dashboard JSON**

```bash
curl -sL https://grafana.com/api/dashboards/1860/revisions/latest/download \
  -o vps_oracle/compose/monitoring/grafana/provisioning/dashboards/node-exporter-full.json
```

- [ ] **Step 2: Verify the download is valid JSON and check its size**

```bash
jq empty vps_oracle/compose/monitoring/grafana/provisioning/dashboards/node-exporter-full.json && echo "valid json"
wc -l vps_oracle/compose/monitoring/grafana/provisioning/dashboards/node-exporter-full.json
```
Expected: `valid json` printed, no parse error. The file should be several thousand lines (this is a large community dashboard with dozens of panels — that's expected, don't manually rewrite it).

- [ ] **Step 3: Fix the datasource reference and dashboard identity**

The downloaded JSON uses a template input placeholder (`${DS_PROMETHEUS}`) for the datasource, meant to be filled in by Grafana's UI import wizard. Since this is file-provisioned (no import wizard), replace it with the fixed `prometheus` datasource uid from Task 3 of the alerting plan, and clear the dashboard's internal `id` (so Grafana treats it as a fresh dashboard on first load) while giving it a stable `uid`:

```bash
cd vps_oracle/compose/monitoring/grafana/provisioning/dashboards

sed -i 's/\${DS_PROMETHEUS}/prometheus/g' node-exporter-full.json

jq '.id = null | .uid = "node-exporter-full"' node-exporter-full.json > node-exporter-full.json.tmp
mv node-exporter-full.json.tmp node-exporter-full.json

cd -
```

- [ ] **Step 4: Confirm no `${DS_PROMETHEUS}` placeholders remain**

```bash
grep -c 'DS_PROMETHEUS' vps_oracle/compose/monitoring/grafana/provisioning/dashboards/node-exporter-full.json
```
Expected: `0`. If it's not 0, inspect the remaining matches with `grep -n 'DS_PROMETHEUS' <file>` — they're likely in the `__inputs`/`__requires` metadata blocks (harmless leftovers from the import-wizard format, safe to ignore since file provisioning doesn't use them), not in a `datasource` field. Only investigate further if a match is inside a `"datasource"` object.

- [ ] **Step 5: Confirm with the user, then apply**

Since the provider's `updateIntervalSeconds: 30` (Task 1) means Grafana polls the directory, this may not require a restart — but confirm with the user before restarting, since this document doesn't assume the interval has already fired:

```bash
cd vps_oracle/compose/monitoring && docker compose up -d
```

- [ ] **Step 6: Verify the dashboard loaded without errors**

```bash
docker logs grafana 2>&1 | tail -50 | grep -i -E "dashboard|error"
```
Expected: no error referencing `node-exporter-full.json` (e.g. no "failed to load dashboard" or JSON parse errors).

- [ ] **Step 7: Verify in the Grafana UI, fix any incompatible panels**

Visit `https://grafana.jerome.cloudns.asia` → Dashboards → `Monitoring` folder → "Node Exporter Full". For each panel:
- Confirm it renders data (not "No data", not a red panel-error banner).
- If a panel shows a plugin-not-found or Angular-related error (this dashboard has years of history and Grafana 13 dropped Angular panel support), that panel is incompatible — remove it from the JSON:
  ```bash
  jq 'del(.panels[] | select(.title == "<exact panel title from the error>"))' \
    vps_oracle/compose/monitoring/grafana/provisioning/dashboards/node-exporter-full.json \
    > vps_oracle/compose/monitoring/grafana/provisioning/dashboards/node-exporter-full.json.tmp
  mv vps_oracle/compose/monitoring/grafana/provisioning/dashboards/node-exporter-full.json.tmp \
    vps_oracle/compose/monitoring/grafana/provisioning/dashboards/node-exporter-full.json
  ```
  Wait up to 30s (the provider's reload interval) and refresh the browser to confirm the panel is gone and no new errors appeared. Repeat for each broken panel.
- Confirm at least one CPU panel, one memory panel, one disk panel, and one network panel are present and rendering real data.

- [ ] **Step 8: Commit**

```bash
git add vps_oracle/compose/monitoring/grafana/provisioning/dashboards/node-exporter-full.json
git commit -m "Import Node Exporter Full dashboard for CPU/memory/disk/network monitoring"
```

---

### Task 3: End-to-end verification

**Files:** none

**Interfaces:**
- Consumes: everything from Tasks 1-2.
- Produces: confirmation that the dashboard is usable day-to-day and that its known limitations are understood, not silently broken.

- [ ] **Step 1: Confirm CPU, memory, and disk panels show plausible real values**

In the Grafana UI, cross-check one CPU panel's current value against:
```bash
docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'
```
Expected: the dashboard's displayed CPU percentage is in the same ballpark as this query's result (small differences from time-window/aggregation choices are fine; a wildly different value, e.g. off by 10x, means the panel query or datasource is misconfigured).

- [ ] **Step 2: Confirm the network panel renders (accepting known inaccuracy)**

Confirm a network-traffic panel shows non-empty data. Per the design spec, this reflects the node-exporter container's own veth interface, not the host's real NIC — do not treat this value as the host's actual bandwidth.

- [ ] **Step 3: Confirm the dashboard is in the correct folder**

In Grafana UI, Dashboards list: confirm "Node Exporter Full" appears under the `Monitoring` folder alongside the existing alert rule groups, not in "General".

(No commit — this task is pure verification against the already-committed configuration from Tasks 1-2.)

---

## Self-Review Notes

- **Spec coverage:** the design spec's four requirements are each covered — declarative provisioning (Task 1 provider config), Node Exporter Full import with datasource/folder adaptation (Task 2), Angular/panel-compatibility verification (Task 2 Step 7), and network-accuracy caveat carried through as a documented constraint rather than something this plan tries to fix (Global Constraints, Task 3 Step 2).
- **Placeholder scan:** Task 2 Step 7's panel-removal command uses a bracketed example (`<exact panel title from the error>`) because the actual broken panel title, if any, can't be known until the dashboard is imported against live Grafana 13.1.1 — this mirrors how the parent alerting plan handled the disk-mountpoint label (verify empirically, then act), not a deferred TBD.
- **Type/naming consistency:** the datasource uid `prometheus` matches `grafana/provisioning/datasources/prometheus.yml`'s `uid: prometheus`; the `job_name: node` referenced in Task 2 matches `prometheus/prometheus.yml`; the `Monitoring` folder name matches the `folder: Monitoring` used in `host-metrics-rules.yml`/`probe-rules.yml`/`self-monitoring-rules.yml`.
