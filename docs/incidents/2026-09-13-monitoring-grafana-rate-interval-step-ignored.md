# Grafana "Node Exporter Full" rate() panels show "No data" — the dashboard's `"step"` field is silently ignored, must use `"interval"`

- Date: 2026-09-13
- Environment: `grafana/grafana` 13.1.1, `prom/prometheus` v3.13.1, community dashboard "Node Exporter Full" (grafana.com ID 1860), provisioned as JSON files under `vps_oracle/compose/monitoring/grafana/provisioning/dashboards/`
- Symptom: CPU Busy / CPU Basic / Network Traffic / Pressure panels show "N/A" / "No data", while RAM / Load / Disk / Swap panels on the same dashboard, same job, same time range work fine
- Fix: replace the numeric `"step": <seconds>` field on every panel target with the string field `"interval": "<duration>"` — that's the field Grafana's current Prometheus datasource actually reads for "Min step"

---

## 1. Conclusion first

**The root cause is that the vendored dashboard JSON's `"step": 240` field (and later `"step": 1800` for a GCP copy) was never read by Grafana at all — not a job/instance mismatch, not a Prometheus data problem.** Confirmed via Grafana's own Query Inspector: for a panel with `"step": 240` in its JSON, the actual outgoing query showed `Step: 20s` — a value Grafana computed itself from the panel's time range and resolution, completely ignoring the JSON field. That 20s step fed into the `$__rate_interval` macro (`max($__interval + scrape_interval, 4×scrape_interval)`, with scrape_interval defaulting to 15s since the datasource has no `jsonData.timeInterval` set), producing a **60-second** rate window (`rate(...[1m0s])`) for every rate()-based panel — regardless of what the JSON's `"step"` said.

A 60-second window against a target scraped every **15 minutes** (GCP) obviously can't find 2 samples → "0 rows". A 60-second window against a target scraped every **60 seconds** (Oracle) is *also* wrong, just less obviously so — it's right at the edge of catching 2 samples depending on scrape/query alignment, so it looks "flaky" rather than "always broken". This means Oracle's own CPU/network/pressure panels were **already unreliable before any of today's GCP work started** — today's change (adding a 15-minute-interval GCP target) didn't introduce this bug, it just made it impossible to miss.

The correct field for Grafana's Prometheus datasource "Min step" override is `"interval"` (a duration **string**, e.g. `"4m"`), not `"step"` (an int, in seconds). This dashboard's JSON was almost certainly authored against an older Grafana/datasource-plugin version where `"step"` may have meant something; the current backend simply doesn't look at it.

## 2. Evidence chain

Today's session added a second node-exporter target (`vps_gcp`, scraped every 15m to stay within GCP's free-tier egress) alongside the existing 60s-interval oracle target, and split "Node Exporter Full" into two dashboards so each could pin its own `job` and (attempted) rate window. After locking each dashboard's `job` variable to a hidden constant, the user reported the GCP dashboard's CPU/network/pressure panels still empty. Manually reproducing the exact panel expression directly against Prometheus worked fine:

```bash
$ docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=100+*+(1+-+avg(rate(node_cpu_seconds_total%7Bmode%3D%22idle%22%2Cjob%3D%22node_gcp%22%7D%5B30m%5D)))'
{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[...,"0.6751390991673878"]}]}}
```

This "proved" (wrongly, as it turned out) that bumping the JSON's `"step"` from 240 to 1800 for the GCP dashboard would fix it, since a 30-minute window clearly finds data. The dashboards were committed with that fix and both `grafana`/`prometheus` restarted — but the user reported CPU panels still empty on a follow-up check ("oracle 還是看不到 cpu 信息"), even though **oracle's own step (240) was never touched** and oracle scrapes every 60 seconds — a window that small should trivially work if `"step"` were actually being honored.

The real gap was that the "verification" above only tested Prometheus's PromQL engine directly (I picked the window myself), never Grafana's actual macro substitution — the assumption that `"step"` in the JSON controls that substitution was never checked against the real UI. The turning point was asking the user to open **Panel menu → Inspect → Query** on the "CPU Busy" panel:

```
Expr: 100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle",instance="100.96.184.44:9100",job="node_gcp"}[1m0s])))
Step: 20s
```

`Step: 20s` does not appear anywhere in the JSON (which had `"step": 1800` for this exact target) — proof the field is dead. `[1m0s]` matches `max(20s+15s, 4×15s) = 60s` exactly, confirming Grafana fell back to its own auto-computed interval and the default 15s scrape-interval assumption (since `vps_oracle/compose/monitoring/grafana/provisioning/datasources/prometheus.yml` sets no `jsonData.timeInterval`).

(Separately, that screenshot also showed the user had the GCP dashboard open while believing it was Oracle's — a real but unrelated mix-up, not a config bug; the two dashboards' `job` locks were verified correct throughout.)

## 3. Root cause

Grafana's Prometheus query editor computes the effective query resolution two ways depending on the JSON schema version a panel was authored against. This dashboard (grafana.com ID 1860, imported long enough ago to predate the current schema) carries a `"step"` field left over from that older export path, which the current `grafana/grafana:13.1.1` Prometheus datasource backend does not read for `$__interval`/`$__rate_interval` purposes. Without an effective override, Grafana derives `$__interval` purely from the panel's visible time range and default resolution (here: ~20s for a 1-hour view), and `$__rate_interval` from that plus the datasource's assumed scrape interval (defaulting to 15s, since it isn't explicitly configured) — a value with no relationship to any real target's actual `scrape_interval` in `prometheus.yml`. Any target scraped less frequently than roughly a quarter of that auto-computed window will intermittently or permanently fail to satisfy `rate()`'s 2-sample minimum.

## 4. Fix

In both `vps_oracle/compose/monitoring/grafana/provisioning/dashboards/node-exporter-full-oracle.json` and `node-exporter-full-gcp.json`, every panel target's `"step": <int>` (274 occurrences per file) was replaced with `"interval": "<duration>"`:

- Oracle (scraped every 60s): `"interval": "4m"` — same 240-second intent as before, now on the field Grafana actually reads
- GCP (scraped every 15m): `"interval": "30m"` — same 1800-second intent as before

```bash
python3 - <<'EOF'
def fix(path, step_value, interval_str):
    raw = open(path).read()
    raw = raw.replace(f'"step": {step_value}', f'"interval": "{interval_str}"')
    open(path, "w").write(raw)

fix(".../node-exporter-full-oracle.json", 240, "4m")
fix(".../node-exporter-full-gcp.json", 1800, "30m")
EOF
```

No changes were needed to alert rules (`host-metrics-rules.yml`, `self-monitoring-rules.yml`) — those use literal fixed windows like `[5m]` directly in PromQL text, evaluated by Prometheus's own rule engine, not through Grafana's macro substitution at all.

## 5. Verification

Re-opened Query Inspector on the same "CPU Busy" panel after the fix and restart; this time the field actually changes with the JSON (this was the step skipped the first time around — verify against the real UI, not just against Prometheus directly). User confirmed afterwards: "現在都有 cpu 數值了" (CPU values now show on both dashboards).

```bash
cd vps_oracle/compose/monitoring && docker compose config -q && docker compose restart grafana
docker logs grafana --tail 100 | grep -iE "error|failed"   # no provisioning errors
```

## 6. Leftovers / lessons

- **Don't declare a Grafana dashboard fix verified from a raw Prometheus query alone.** Prometheus will happily run whatever window you hand it manually; the only way to know what Grafana itself sends is Query Inspector (Panel menu → Inspect → Query) or an equivalent capture of the actual `/api/ds/query` request. This is the second time in this session a "verified" fix (bumping `"step"`) turned out to not be wired to anything real.
- The Prometheus datasource (`vps_oracle/compose/monitoring/grafana/provisioning/datasources/prometheus.yml`) still has no `jsonData.timeInterval` set, so Grafana's rate-window fallback keeps assuming a 15s scrape interval dashboard-wide regardless of any real job's actual interval. Harmless now that every rate()-heavy panel carries an explicit `"interval"` override, but worth remembering if a future dashboard is added without one.
- Separately (unrelated to this incident, found while trying to query Grafana's API for diagnosis): `GF_SECURITY_ADMIN_PASSWORD` in `vps_oracle/compose/monitoring/.env` does not match any live account — the real admin login is `jerome` (`id=1`), not `admin`; `GF_SECURITY_ADMIN_PASSWORD` only seeds the bootstrap `admin` user on a brand-new database and has had no effect since. Not fixed here since it isn't broken, just misleading if someone edits `.env` expecting it to change a live password.
