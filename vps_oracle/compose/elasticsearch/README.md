# elasticsearch

A shared single-node Elasticsearch (9.x, security on) for the user's own apps. Each app gets two isolated pools — prod and dev — as native-realm users whose roles are scoped to an index-name prefix. No Kibana, no plugins.

First consumer: `rag` (bank-policy-rag) — `dense_vector` kNN with `filter`, plus BM25.

## Architecture

| container_name | network | host port | data |
|---|---|---|---|
| `elasticsearch` | `elasticsearch_default` | `127.0.0.1:9200` only | `/etc/elasticsearch/data` (bind mount, owned `1000:0`) |
| `elasticsearch-exporter` | `elasticsearch_default` + `monitoring_default` | none | — |

- Not on `proxy`, no NPM record, no homepage card (no UI) — same as the `postgres` / `redis` backends.
- HTTP is plain (no TLS): the only paths in are loopback and the stack's own docker network.

## Why it isn't exposed publicly

It holds app data, and a public ES endpoint is a standard target for credential stuffing and ransom-wipe bots — auth alone is not enough of a boundary. The port binds `127.0.0.1` (allowlisted in `PORT_EXCEPTIONS` in `.github/scripts/check-compose-conventions.py`), so it isn't reachable on the public IP even if the cloud security list opens; containers reach it over `elasticsearch_default`. Never add it to `proxy` or NPM.

## Resource limits

`cpus: 2`, `memory: 3G`, heap `-Xms1536m -Xmx1536m` (the rest is left for Lucene's off-heap / page cache). `bootstrap.memory_lock=true` with `ulimits.memlock: -1` keeps the heap out of swap (the host has 4G swap that is in use); check with `_nodes?filter_path=**.mlockall`. `xpack.ml.enabled=false` (unused). `vm.max_map_count` on the host is `1048576` — ES needs ≥ 262144; don't lower it.

## Monitoring and alerts

`elasticsearch-exporter` (Prometheus job `elasticsearch`) logs in as `prometheus_exporter` — role `prometheus_exporter`, cluster `monitor` only, no index privileges (it runs without `--es.indices`). Provision it with `./scripts/es-provision-exporter.sh` (password `ES_EXPORTER_PASSWORD` in `.env`). It joins `monitoring_default`, so **the monitoring stack must be up before this one**.

Alert rules: `../monitoring/grafana/provisioning/alerting/shared-backends-rules.yml` — Elasticsearch Down (critical), Cluster Red (critical), JVM Heap > 90% for 10m (warning). Yellow is not alerted.

- "Down" is `sum(elasticsearch_cluster_health_number_of_nodes) or vector(0) < 1`. When ES dies mid-run the exporter keeps answering 200 but drops every `cluster_health_*` series; when ES is down at exporter start the exporter never opens `:9114`. One expression covers both. Don't use `elasticsearch_clusterinfo_up` — it is cached for 5m and stays `1` after ES is gone.

## Connecting a new app

1. Provision its pools (idempotent, re-run any time):

   ```bash
   cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/elasticsearch
   ./scripts/es-provision-app.sh <app>                                   # basic
   ./scripts/es-provision-app.sh <app> --audit-pattern 'audit-<app>-*'   # + append-only audit index
   ```

   | user | role(s) | index access |
   |---|---|---|
   | `<app>` | `<app>_rw` (+ `<app>_audit_writer`) | `all` on `<app>-*` (+ `create_doc`/`create_index` on the audit pattern) |
   | `<app>_dev` | `<app>_dev_rw` (+ `<app>_dev_audit_writer`) | `all` on `<app>_dev-*` (+ the same on the dev audit pattern, `audit-<app>-` → `audit-<app>_dev-`) |
   | `<app>_audit_reader` (only with `--audit-pattern`) | `<app>_audit_reader` | `read` on the audit pattern only — nothing on `<app>-*` |
   | `<app>_audit_reader_dev` (only with `--audit-pattern`) | `<app>_audit_reader_dev` | `read` on the dev audit pattern only — nothing on `<app>_dev-*` |

   The script also maintains index template `<app>-defaults` (priority 1) on `<app>-*`, `<app>_dev-*`, `audit-<app>-*`, `audit-<app>_dev-*` with `number_of_replicas: 0` — see "Single node and replicas" below.

   Both roles also carry cluster action `cluster:monitor/main` (= `GET /`, which clients use for `info()`/version checks) and nothing else — not `monitor`, which would expose every index name through cluster state.

2. **Credentials**: the script writes `APP_<APP>_PASSWORD` / `APP_<APP>_DEV_PASSWORD` into this stack's `.env` (gitignored, `chmod 600`) on first run and reuses them afterwards — it never rotates. Copy them into the app's own `.env`; never commit them.

3. **Connect**:
   - from a container: join the network and use `http://elasticsearch:9200`
     ```yaml
     services:
       app:
         networks: [elasticsearch]
     networks:
       elasticsearch:
         name: elasticsearch_default
         external: true
     ```
   - from the host: `http://127.0.0.1:9200`
   - prod indices must be named `<app>-…`, dev `<app>_dev-…`; anything else is 403.

### Naming rules (enforced by the script)

- App names match `^[a-z][a-z0-9]*$` — no `-` or `_`. With apps `rag` and `rag-x`, the pattern `rag-*` would also match `rag-x-*`; alphanumeric names keep every app's patterns disjoint.
- **Audit indices live under the reserved `audit-` prefix**, outside the app's namespace. ES roles are additive with no deny, so an audit index under `<app>-*` would be fully writable/deletable through `<app>_rw`. The app name `audit` is reserved.
- **Audit indices are created explicitly by the app**, with its own (strict) mapping: the writer role has `create_index`, and the cluster setting `action.auto_create_index: "-audit-*,+*"` (maintained by the script) makes a write to a missing `audit-*` index fail with 404 instead of auto-creating it with a dynamic mapping. `create_index` alone would still auto-create — tested; that's why the cluster setting exists. It applies to every app's audit indices; everything else still auto-creates.
- Audit writes must be create-only: `POST /audit-<app>-x/_doc` (auto id) or `PUT …/_create/<id>`, or `_bulk` with `create` actions. `PUT …/_doc/<id>` (overwrite), reads, updates, deletes, `_delete_by_query`, deleting the index and changing its settings are all 403 for the writer. Caveat: `create_index` also grants `PUT _mapping`, so the writer can add fields (or relax `dynamic`) — it still cannot alter or remove existing docs.
- Reading audit data goes through `<app>_audit_reader` / `<app>_audit_reader_dev` (read-only, audit pattern only). Hand that credential only to the component that serves audit reads, not to the main write path.

## Ops

```bash
# elastic password (superuser, ops only — never hand it to an app)
grep ^ELASTIC_PASSWORD= .env

curl -s -u "elastic:$(grep ^ELASTIC_PASSWORD= .env | cut -d= -f2-)" '127.0.0.1:9200/_cluster/health?pretty'
```

### Single node and replicas

A replica can never be assigned on one node, so any index with the default 1 replica turns the cluster `yellow` permanently. An app creating an index without `number_of_replicas: 0` hits this, and it can't create templates itself. Hence the per-app `<app>-defaults` template (0 replicas). It is per-app rather than a catch-all `*` template because `*` at priority 0 is rejected (it collides with the built-in `.monitoring-*` templates) and at a higher priority would override them. Only one composable template applies per index, so any later higher-priority template on an app's patterns must set `number_of_replicas: 0` itself.

## First install

```bash
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/elasticsearch
cp .env.example .env && chmod 600 .env     # set ELASTIC_PASSWORD
sudo mkdir -p /etc/elasticsearch/data && sudo chown 1000:0 /etc/elasticsearch/data && sudo chmod 770 /etc/elasticsearch/data
docker compose up -d
./scripts/es-provision-app.sh rag --audit-pattern 'audit-rag-*'
./scripts/es-provision-exporter.sh && docker compose up -d elasticsearch-exporter
```

## Gotchas

- **`ELASTIC_PASSWORD` is only read on first start** with an empty data dir. Changing it in `.env` afterwards does nothing; change it through `POST /_security/user/elastic/_password` and then update `.env`.
- **Log timestamps are UTC (`Z`)** even with `TZ` set: ES's ECS JSON log layout always writes `@timestamp` in UTC. Left as-is — the image also has no tzdata, and mounting a zone file wouldn't change the ECS layout.
- **Backups**: none yet. Indices here are expected to be rebuildable from the app's source documents; add a snapshot repository if that stops being true.
