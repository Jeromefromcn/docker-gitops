# Server Monitoring & Alerting (Prometheus + Grafana) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the torn-down Beszel/Uptime Kuma stack with Prometheus + Grafana for host-metrics monitoring and service-availability probing on the Oracle Cloud VPS, with two-tier (warning/critical) severity alerting and custom-formatted Telegram messages, per [docs/superpowers/specs/2026-07-30-server-monitoring-design.md](../specs/2026-07-30-server-monitoring-design.md).

**Architecture:** Four tightly-coupled services in one compose stack (`vps_oracle/compose/monitoring/`): Prometheus scrapes node_exporter (host metrics) and blackbox_exporter (service probes); Grafana queries Prometheus and owns alert evaluation + Telegram notification (Grafana's built-in Unified Alerting — no separate Alertmanager). Only Grafana is reverse-proxied through NPM; the other three are internal-only.

**Tech Stack:** Docker Compose, `prom/prometheus:v3.13.1`, `prom/node-exporter:v1.12.1`, `prom/blackbox-exporter:v0.28.0`, `grafana/grafana:13.1.1` (all pinned by digest, arm64 since this host is `aarch64`), nginx-proxy-manager (already deployed), Telegram Bot API.

## Global Constraints

- Never commit secrets — use `.env` (gitignored), never inline values in compose files.
- Pin image tags/digests. No `latest`.
- One change per commit, scoped to one compose stack.
- After editing a compose file, apply it: `cd <host>/<compose> && docker compose up -d`.
- Host **data** directories (things outside the repo, e.g. Prometheus TSDB, Grafana's own DB) use absolute paths so bind mounts still resolve if the repo moves. Config files that live inside this repo (`prometheus.yml`, `blackbox.yml`, Grafana provisioning YAML) are mounted with paths relative to the compose file, since they move with the repo and the documented workflow always `cd`s into the compose directory first.
- **Confirm with the user before running any `docker compose up -d` or other command that creates/recreates a container on the live VPS.**
- All alert rule titles, Grafana folder/group names, and Telegram message content are in **English**.
- Out of scope (per spec): container-level metrics, log scanning, Alertmanager, per-severity Telegram bot routing.
- **Network design**: none of the four services use `network_mode: host`. node_exporter gets host CPU/memory/disk via the bind-mount pattern (`/:/host:ro,rslave` + `--path.rootfs=/host`), not host networking — this trades away accurate network-interface throughput metrics (it would see its own veth, not the host's real NIC) for avoiding the same host-network/loopback complexity that caused repeated debugging pain in the prior Beszel attempt. This is an acceptable trade because network alerting is explicitly out of scope for this iteration. All four services share the compose file's default network (container-name DNS resolution); Grafana additionally joins the external `proxy` network for NPM.
- Verified image digests (arm64):
  - `prom/prometheus@sha256:2d61f37ba9f2185195dfad94ee500d7ac1986560bac79a77d0a6de182a5bf814` (tag `v3.13.1`)
  - `prom/node-exporter@sha256:c9ef89f9464f09e7234decaae68a80ab856ff0014435677a99fd48b03dd410ea` (tag `v1.12.1`)
  - `prom/blackbox-exporter@sha256:2d27bd2523936a9f28d1073ee12fbae1497f7d45c1b08710a271cb6c48f06550` (tag `v0.28.0`)
  - `grafana/grafana@sha256:96b9eabbe113fffa7ce6efc6267ebe7e6e33bdc65a94d85d73b2b46cbd14e43d` (tag `13.1.1`)
- Confirmed Telegram chat_id: `8737165697`.
- **Telegram bot token handling**: Grafana's alerting-provisioning YAML has documented, unresolved bugs/inconsistency around environment-variable substitution in contact points (per public GitHub issues #54984 and #69950). Rather than depend on that, the Telegram **contact point** (which holds the secret bot token) is configured manually via the Grafana UI, exactly like the Beszel/Uptime Kuma notification setup earlier — it is stored in Grafana's own database, never in a committed file. Everything else (datasource, notification template, notification policy, alert rules — none of which carry secrets) is provisioned declaratively via YAML files committed to this repo.

---

## File Structure

```
vps_oracle/
  compose/
    monitoring/
      docker-compose.yml
      .env                                          # GRAFANA_ADMIN_PASSWORD — gitignored
      prometheus/
        prometheus.yml                              # scrape configs
      blackbox/
        blackbox.yml                                # probe module definitions
      grafana/
        provisioning/
          datasources/
            prometheus.yml                          # Prometheus datasource, fixed uid
          alerting/
            templates.yml                           # notification message template
            policies.yml                             # notification policy (routes severity -> contact point)
            host-metrics-rules.yml                   # 6 CPU/Memory/Disk warning+critical rules
            probe-rules.yml                          # 5 service-availability rules
```

---

### Task 1: Monitoring compose stack — Prometheus, node_exporter, blackbox_exporter, Grafana

**Files:**
- Create: `vps_oracle/compose/monitoring/docker-compose.yml`
- Create: `vps_oracle/compose/monitoring/prometheus/prometheus.yml`
- Create: `vps_oracle/compose/monitoring/blackbox/blackbox.yml`
- Create: `vps_oracle/compose/monitoring/.env`

**Interfaces:**
- Produces: `prometheus` container reachable at `prometheus:9090` on the compose default network; `node-exporter:9100`; `blackbox-exporter:9115`. Task 3 depends on Prometheus's targets page showing all three scrape jobs UP. Task 3/4 depend on `grafana` being reachable at `grafana:3000` on the same default network and joined to `proxy`.

- [ ] **Step 1: Write the blackbox exporter module config**

```yaml
# vps_oracle/compose/monitoring/blackbox/blackbox.yml
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_status_codes: []  # defaults to 2xx

  http_2xx_or_404:
    prober: http
    timeout: 5s
    http:
      valid_status_codes: [200, 201, 202, 203, 204, 205, 206, 404]

  tcp_connect:
    prober: tcp
    timeout: 5s
```

- [ ] **Step 2: Write the Prometheus scrape config**

```yaml
# vps_oracle/compose/monitoring/prometheus/prometheus.yml
global:
  scrape_interval: 60s

scrape_configs:
  - job_name: node
    static_configs:
      - targets: ['node-exporter:9100']

  - job_name: blackbox_http_2xx
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
          - https://npm.jerome.cloudns.asia
          - https://sub.3x.jerome.cloudns.asia/sub/
          - https://portainer.jerome.cloudns.asia/
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter:9115

  - job_name: blackbox_http_2xx_or_404
    metrics_path: /probe
    params:
      module: [http_2xx_or_404]
    static_configs:
      - targets:
          - https://panel.3x.jerome.cloudns.asia
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter:9115

  - job_name: blackbox_tcp
    metrics_path: /probe
    params:
      module: [tcp_connect]
    static_configs:
      - targets:
          - jerome.cloudns.asia:39876
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter:9115
```

- [ ] **Step 3: Write the `.env` file (gitignored)**

```bash
cat > vps_oracle/compose/monitoring/.env <<'EOF'
GRAFANA_ADMIN_PASSWORD=<choose a strong password>
EOF
git check-ignore -v vps_oracle/compose/monitoring/.env   # confirm it matches the repo's .env gitignore rule
```

- [ ] **Step 4: Write the compose file**

```yaml
services:
  prometheus:
    image: prom/prometheus@sha256:2d61f37ba9f2185195dfad94ee500d7ac1986560bac79a77d0a6de182a5bf814  # v3.13.1
    container_name: prometheus
    hostname: prometheus
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - /etc/monitoring/prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
    # 不对外暴露: 没有登录认证, 只用 docker exec 或临时端口做本地 PromQL 调试

  node-exporter:
    image: prom/node-exporter@sha256:c9ef89f9464f09e7234decaae68a80ab856ff0014435677a99fd48b03dd410ea  # v1.12.1
    container_name: node-exporter
    hostname: node-exporter
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
    volumes:
      - /:/host:ro,rslave
    command:
      - '--path.rootfs=/host'
    # 不用 network_mode: host: 牺牲网络吞吐指标精度换取部署简单,网络告警本来就不在这次范围内

  blackbox-exporter:
    image: prom/blackbox-exporter@sha256:2d27bd2523936a9f28d1073ee12fbae1497f7d45c1b08710a271cb6c48f06550  # v0.28.0
    container_name: blackbox-exporter
    hostname: blackbox-exporter
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
    volumes:
      - ./blackbox/blackbox.yml:/etc/blackbox_exporter/config.yml:ro

  grafana:
    image: grafana/grafana@sha256:96b9eabbe113fffa7ce6efc6267ebe7e6e33bdc65a94d85d73b2b46cbd14e43d  # 13.1.1
    container_name: grafana
    hostname: grafana
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
    environment:
      GF_SECURITY_ADMIN_PASSWORD: "${GRAFANA_ADMIN_PASSWORD}"
      GF_SERVER_ROOT_URL: "https://grafana.jerome.cloudns.asia"
      TZ: "Asia/Hong_Kong"
    volumes:
      - /etc/monitoring/grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    networks:
      - default
      - proxy
    # NPM 反代配置: Forward Hostname/IP = grafana, Forward Port = 3000

networks:
  proxy:
    external: true   # 手动创建一次：docker network create proxy
```

- [ ] **Step 5: Confirm with the user, then deploy**

```bash
cd vps_oracle/compose/monitoring && docker compose up -d
```

- [ ] **Step 6: Verify all four containers are healthy**

Run: `docker compose ps`
Expected: `prometheus`, `node-exporter`, `blackbox-exporter`, `grafana` all show `Up`.

- [ ] **Step 7: Verify Prometheus is scraping successfully**

Run: `docker exec prometheus wget -qO- http://localhost:9090/api/v1/targets | python3 -m json.tool | grep -E '"health"|"scrapeUrl"'`
Expected: every target's `"health"` is `"up"`. If any blackbox target is `"down"`, check `docker logs blackbox-exporter` and confirm the target URL is reachable from inside the `blackbox-exporter` container (`docker exec blackbox-exporter wget -qO- <url>`).

- [ ] **Step 8: Commit**

```bash
git add vps_oracle/compose/monitoring/docker-compose.yml vps_oracle/compose/monitoring/prometheus/prometheus.yml vps_oracle/compose/monitoring/blackbox/blackbox.yml
git commit -m "Add Prometheus/node_exporter/blackbox_exporter/Grafana monitoring stack"
```

(`.env` is intentionally not committed — it's gitignored.)

---

### Task 2: NPM reverse proxy for Grafana, first login

**Files:** none (NPM UI configuration)

**Interfaces:**
- Consumes: `grafana` container from Task 1 (container name `grafana`, port `3000`).
- Produces: `https://grafana.jerome.cloudns.asia` reachable externally, logged in as admin. Tasks 3-6 depend on this.

- [ ] **Step 1: Add the proxy host in NPM**

`https://npm.jerome.cloudns.asia` → Proxy Hosts → Add Proxy Host:
- Domain Names: `grafana.jerome.cloudns.asia`
- Forward Hostname/IP: `grafana`
- Forward Port: `3000`
- Enable SSL (Let's Encrypt, force SSL)
- Access List: Publicly Accessible (unless you deliberately want the same VPN-gated restriction used for the prior stack — your call, same as before)

- [ ] **Step 2: Verify externally**

Run: `curl -sI https://grafana.jerome.cloudns.asia | head -1`
Expected: `HTTP/2 200` (or a login-page redirect), not a connection error or 502.

- [ ] **Step 3: Log in**

Visit `https://grafana.jerome.cloudns.asia`, log in with username `admin` and the password from `vps_oracle/compose/monitoring/.env`.

(No commit.)

---

### Task 3: Grafana datasource provisioning — Prometheus

**Files:**
- Create: `vps_oracle/compose/monitoring/grafana/provisioning/datasources/prometheus.yml`

**Interfaces:**
- Consumes: `prometheus:9090` from Task 1.
- Produces: a Grafana datasource with fixed `uid: prometheus` that Tasks 5-6's alert rules reference by that exact uid.

- [ ] **Step 1: Write the datasource provisioning file**

```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    uid: prometheus
    isDefault: true
```

- [ ] **Step 2: Confirm with the user, then apply**

Grafana provisioning files are read at container start, so this requires a restart:

```bash
cd vps_oracle/compose/monitoring && docker compose up -d
```

- [ ] **Step 3: Verify in the Grafana UI**

Connections → Data sources → Prometheus → click "Save & test". Expected: a green success message (something like "Successfully queried the Prometheus API").

- [ ] **Step 4: Commit**

```bash
git add vps_oracle/compose/monitoring/grafana/provisioning/datasources/prometheus.yml
git commit -m "Provision Prometheus as a Grafana datasource"
```

---

### Task 4: Telegram contact point (manual, holds the secret)

**Files:** none (manual UI configuration — see Global Constraints for why this one piece isn't provisioned as code)

**Interfaces:**
- Consumes: the Telegram bot token, chat_id `8737165697`.
- Produces: a Grafana Contact Point named `Telegram` that Task 5's notification policy routes all alerts to.

- [ ] **Step 1: Add the contact point**

`https://grafana.jerome.cloudns.asia` → Alerting → Contact points → Add contact point:
- Name: `Telegram`
- Integration: Telegram
- Bot API Token: (the bot token)
- Chat ID: `8737165697`
- Message: leave default for now (Task 5's notification template overrides formatting at the policy/template level, not here)

- [ ] **Step 2: Send a test notification**

Use the "Test" button on the contact point. Confirm the message arrives in Telegram before proceeding — do not move on to Task 5/6 until this is confirmed working.

(No commit — lives in Grafana's own database.)

---

### Task 5: Notification template + policy (severity/status-based formatting)

**Files:**
- Create: `vps_oracle/compose/monitoring/grafana/provisioning/alerting/templates.yml`
- Create: `vps_oracle/compose/monitoring/grafana/provisioning/alerting/policies.yml`

**Interfaces:**
- Consumes: the `Telegram` contact point from Task 4 (referenced by name).
- Produces: a named template (`server_alert`) that Task 6's rules' annotations can format through, and a policy that routes everything to `Telegram`.

- [ ] **Step 1: Write the notification template**

```yaml
# vps_oracle/compose/monitoring/grafana/provisioning/alerting/templates.yml
apiVersion: 1

templates:
  - orgId: 1
    name: server_alert
    template: |
      {{ define "server_alert" }}
      {{ if eq .Status "firing" }}
      {{ if eq .CommonLabels.severity "critical" }}🚨🔴 CRITICAL{{ else }}⚠️🟠 WARNING{{ end }}: {{ .CommonAnnotations.summary }}
      {{ else }}
      ✅🟢 RESOLVED: {{ .CommonAnnotations.summary }}
      {{ end }}
      {{ end }}
```

- [ ] **Step 2: Write the notification policy, referencing the template**

```yaml
# vps_oracle/compose/monitoring/grafana/provisioning/alerting/policies.yml
apiVersion: 1

policies:
  - orgId: 1
    receiver: Telegram
    group_by: ['alertname']
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h

contactPoints:
  - orgId: 1
    name: Telegram
    receivers:
      - uid: telegram_default
        type: telegram
        settings:
          message: '{{ template "server_alert" . }}'
        disableResolveMessage: false
```

**Note for the implementer:** the `contactPoints` block above re-declares the `Telegram` contact point's message template but must NOT re-declare its `bottoken`/`chatid` (those stay UI-managed from Task 4, per the Global Constraints note on why secrets aren't provisioned). Verify against the live Grafana version whether provisioning a `contactPoints` entry by matching `name` merges with the UI-created one (updating just the `message` field) or creates a duplicate — if it creates a duplicate, drop this `contactPoints` block from this file and instead set the message template directly on the contact point via the UI in Task 4, referencing `{{ template "server_alert" . }}` there.

- [ ] **Step 3: Confirm with the user, then apply**

```bash
cd vps_oracle/compose/monitoring && docker compose up -d
```

- [ ] **Step 4: Verify**

Alerting → Notification Templates: confirm `server_alert` appears. Alerting → Notification Policies: confirm the default policy routes to `Telegram`.

- [ ] **Step 5: Commit**

```bash
git add vps_oracle/compose/monitoring/grafana/provisioning/alerting/templates.yml vps_oracle/compose/monitoring/grafana/provisioning/alerting/policies.yml
git commit -m "Add Grafana notification template and policy for severity-formatted Telegram alerts"
```

---

### Task 6: Host-metric alert rules (6 rules: CPU/Memory/Disk x warning/critical)

**Files:**
- Create: `vps_oracle/compose/monitoring/grafana/provisioning/alerting/host-metrics-rules.yml`

**Interfaces:**
- Consumes: `datasourceUid: prometheus` from Task 3.
- Produces: 6 alert rules evaluated by Grafana every 60s, routed through Task 5's policy/template to Telegram.

- [ ] **Step 1: Write the rules file**

```yaml
apiVersion: 1

groups:
  - orgId: 1
    name: host_metrics
    folder: Monitoring
    interval: 60s
    rules:
      - uid: cpu_warning
        title: CPU Usage Warning
        condition: B
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "CPU usage above 75% for 15 minutes on vps_oracle"
        data:
          - refId: A
            datasourceUid: prometheus
            model:
              refId: A
              instant: true
              expr: '100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'
          - refId: B
            datasourceUid: '__expr__'
            model:
              refId: B
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [75]

      - uid: cpu_critical
        title: CPU Usage Critical
        condition: B
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "CPU usage above 90% for 10 minutes on vps_oracle"
        data:
          - refId: A
            datasourceUid: prometheus
            model:
              refId: A
              instant: true
              expr: '100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'
          - refId: B
            datasourceUid: '__expr__'
            model:
              refId: B
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [90]

      - uid: memory_warning
        title: Memory Usage Warning
        condition: B
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Memory usage above 70% for 15 minutes on vps_oracle"
        data:
          - refId: A
            datasourceUid: prometheus
            model:
              refId: A
              instant: true
              expr: '100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))'
          - refId: B
            datasourceUid: '__expr__'
            model:
              refId: B
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [70]

      - uid: memory_critical
        title: Memory Usage Critical
        condition: B
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "Memory usage above 85% for 10 minutes on vps_oracle"
        data:
          - refId: A
            datasourceUid: prometheus
            model:
              refId: A
              instant: true
              expr: '100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))'
          - refId: B
            datasourceUid: '__expr__'
            model:
              refId: B
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [85]

      - uid: disk_warning
        title: Disk Usage Warning
        condition: B
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "Disk usage above 75% on vps_oracle root filesystem"
        data:
          - refId: A
            datasourceUid: prometheus
            model:
              refId: A
              instant: true
              expr: '100 * (1 - (node_filesystem_avail_bytes{mountpoint="/host",fstype!="tmpfs"} / node_filesystem_size_bytes{mountpoint="/host",fstype!="tmpfs"}))'
          - refId: B
            datasourceUid: '__expr__'
            model:
              refId: B
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [75]

      - uid: disk_critical
        title: Disk Usage Critical
        condition: B
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "Disk usage above 85% on vps_oracle root filesystem"
        data:
          - refId: A
            datasourceUid: prometheus
            model:
              refId: A
              instant: true
              expr: '100 * (1 - (node_filesystem_avail_bytes{mountpoint="/host",fstype!="tmpfs"} / node_filesystem_size_bytes{mountpoint="/host",fstype!="tmpfs"}))'
          - refId: B
            datasourceUid: '__expr__'
            model:
              refId: B
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [85]
```

**Note for the implementer:** the disk query's `mountpoint="/host"` label assumes node_exporter reports the root filesystem under that path because of the `--path.rootfs=/host` flag from Task 1 — verify this against real data first (Step 2 below) rather than trust the label value blindly, since node_exporter's exact mountpoint labeling for the rootfs bind-mount should be confirmed empirically.

- [ ] **Step 2: Before applying, verify the PromQL expressions against real scraped data**

```bash
docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'
docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))'
docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=node_filesystem_avail_bytes'
```

Expected: each returns a non-empty `result` array with a plausible numeric value (CPU/memory queries: 0-100; the filesystem query: confirm which `mountpoint` label value corresponds to the root filesystem — adjust the `mountpoint="/host"` selector in Step 1 if it differs, then re-save the file before Step 3).

- [ ] **Step 3: Confirm with the user, then apply**

```bash
cd vps_oracle/compose/monitoring && docker compose up -d
```

- [ ] **Step 4: Verify in the Grafana UI**

Alerting → Alert rules → Monitoring folder → host_metrics group: confirm all 6 rules appear with the correct labels/thresholds, and none show an evaluation error (a red exclamation icon).

- [ ] **Step 5: Commit**

```bash
git add vps_oracle/compose/monitoring/grafana/provisioning/alerting/host-metrics-rules.yml
git commit -m "Add Grafana alert rules for CPU/memory/disk warning and critical thresholds"
```

---

### Task 7: Service-availability probe alert rules (5 rules, no severity tier)

**Files:**
- Create: `vps_oracle/compose/monitoring/grafana/provisioning/alerting/probe-rules.yml`

**Interfaces:**
- Consumes: `probe_success` metric produced by Task 1's blackbox scrape jobs, `datasourceUid: prometheus`.
- Produces: 5 alert rules, one per probe target, firing when `probe_success == 0` for 2 minutes (avoids single-check network-blip false alarms).

- [ ] **Step 1: Write the rules file**

```yaml
apiVersion: 1

groups:
  - orgId: 1
    name: service_probes
    folder: Monitoring
    interval: 60s
    rules:
      - uid: probe_npm_admin
        title: NPM Admin Panel Down
        condition: B
        for: 2m
        annotations:
          summary: "NPM Admin Panel (npm.jerome.cloudns.asia) is unreachable"
        data:
          - refId: A
            datasourceUid: prometheus
            model:
              refId: A
              instant: true
              expr: 'probe_success{instance="https://npm.jerome.cloudns.asia"}'
          - refId: B
            datasourceUid: '__expr__'
            model:
              refId: B
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: lt
                    params: [1]

      - uid: probe_3xui_panel
        title: 3x-ui Panel Down
        condition: B
        for: 2m
        annotations:
          summary: "3x-ui Panel (panel.3x.jerome.cloudns.asia) is unreachable"
        data:
          - refId: A
            datasourceUid: prometheus
            model:
              refId: A
              instant: true
              expr: 'probe_success{instance="https://panel.3x.jerome.cloudns.asia"}'
          - refId: B
            datasourceUid: '__expr__'
            model:
              refId: B
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: lt
                    params: [1]

      - uid: probe_3xui_sub
        title: 3x-ui Subscription Down
        condition: B
        for: 2m
        annotations:
          summary: "3x-ui Subscription (sub.3x.jerome.cloudns.asia) is unreachable"
        data:
          - refId: A
            datasourceUid: prometheus
            model:
              refId: A
              instant: true
              expr: 'probe_success{instance="https://sub.3x.jerome.cloudns.asia/sub/"}'
          - refId: B
            datasourceUid: '__expr__'
            model:
              refId: B
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: lt
                    params: [1]

      - uid: probe_3xui_vless_port
        title: 3x-ui VLESS Node Port Down
        condition: B
        for: 2m
        annotations:
          summary: "3x-ui VLESS node port (39876) is unreachable"
        data:
          - refId: A
            datasourceUid: prometheus
            model:
              refId: A
              instant: true
              expr: 'probe_success{instance="jerome.cloudns.asia:39876"}'
          - refId: B
            datasourceUid: '__expr__'
            model:
              refId: B
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: lt
                    params: [1]

      - uid: probe_portainer
        title: Portainer Admin Panel Down
        condition: B
        for: 2m
        annotations:
          summary: "Portainer Admin Panel (portainer.jerome.cloudns.asia) is unreachable"
        data:
          - refId: A
            datasourceUid: prometheus
            model:
              refId: A
              instant: true
              expr: 'probe_success{instance="https://portainer.jerome.cloudns.asia/"}'
          - refId: B
            datasourceUid: '__expr__'
            model:
              refId: B
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: lt
                    params: [1]
```

**Note for the implementer:** the `instance` label values above must match exactly what Prometheus assigned via the `relabel_configs` in Task 1's `prometheus.yml` (the `__param_target` becomes `instance`) — verify with the query in Step 2 before trusting these strings.

- [ ] **Step 2: Verify the exact instance label values against real scraped data**

```bash
docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=probe_success' | python3 -m json.tool
```

Expected: 5 results, each with an `instance` label. Confirm they match the strings used in Step 1 exactly (adjust Step 1's `expr` selectors if they differ, then re-save before Step 3).

- [ ] **Step 3: Confirm with the user, then apply**

```bash
cd vps_oracle/compose/monitoring && docker compose up -d
```

- [ ] **Step 4: Verify in the Grafana UI**

Alerting → Alert rules → Monitoring folder → service_probes group: confirm all 5 rules appear, none in an error state, all currently "Normal" (assuming all 5 services are actually up).

- [ ] **Step 5: Commit**

```bash
git add vps_oracle/compose/monitoring/grafana/provisioning/alerting/probe-rules.yml
git commit -m "Add Grafana alert rules for service-availability probes"
```

---

### Task 8: End-to-end verification

**Files:** none

**Interfaces:**
- Consumes: everything from Tasks 1-7.
- Produces: proof that a real threshold breach and a real probe failure both reach Telegram with the correct severity/status formatting, including the recovery message.

- [ ] **Step 1: Trigger one real host-metric alert**

Temporarily lower `disk_warning`'s threshold (edit `host-metrics-rules.yml`'s `params: [75]` to a value below the current actual disk usage — check with `df -h /` first), then re-apply:

```bash
cd vps_oracle/compose/monitoring && docker compose up -d
```

- [ ] **Step 2: Confirm Telegram delivery and formatting**

Wait for the rule's `for` duration to pass. Confirm the Telegram message arrives with the `⚠️🟠 WARNING` prefix (per the Task 5 template).

- [ ] **Step 3: Revert the threshold and confirm the resolved message**

Set the threshold back to `75`, re-apply, wait for the next evaluation, and confirm a `✅🟢 RESOLVED` message arrives.

- [ ] **Step 4: Trigger one real probe alert**

Temporarily edit `probe-rules.yml`'s `probe_npm_admin` rule's `params: [1]` to `params: [2]` (making `probe_success < 2` always true, since `probe_success` is only ever 0 or 1) to force a firing state without touching the live NPM proxy host, then re-apply.

- [ ] **Step 5: Confirm delivery, then revert**

Confirm the firing message arrives, revert `params` back to `[1]`, re-apply, and confirm the resolved message also arrives.

(No commit — this task is pure verification against the live, already-committed configuration.)

---

## Self-Review Notes

- **Spec coverage:** every row of the spec's host-metric and probe-target tables maps to a rule in Task 6/7; the spec's "no severity for probes" decision is reflected in Task 7's rules having no `severity` label; the spec's message-template requirement (emoji/color by severity and firing/resolved) is implemented in Task 5's `server_alert` template; the spec's secrets-handling decision (Telegram token never in a committed file) is reflected in Task 4 being UI-only and the Task 5 note about not re-provisioning `bottoken`/`chatid`.
- **Placeholder scan:** the two "Note for the implementer" callouts in Tasks 6 and 7 flag values (the disk mountpoint label, the probe instance label strings) that cannot be known until read off live scraped data — each is paired with a concrete verification step (Step 2 in both tasks) before the file is applied, not left as an unresolved TBD.
- **Type/naming consistency:** the Prometheus datasource `uid: prometheus` (Task 3) is referenced identically in every `datasourceUid: prometheus` field across Tasks 6-7; the `Telegram` contact point name (Task 4) matches the `receiver: Telegram` in Task 5's policy; container names (`prometheus`, `node-exporter`, `blackbox-exporter`, `grafana`) match between Task 1's compose file and all `docker exec`/relabel references throughout.
