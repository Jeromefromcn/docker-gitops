# lab-environment on k3s

Migrated from `~/jerome/lab-environment/docker-compose.yml` (a separate,
independently-managed project). Fully isolated `lab-environment`
namespace: no shared Prometheus/Grafana/alerting with `vps_oracle`'s own
monitoring stack (deliberate — this stack's `toxiproxy`-driven chaos
testing shouldn't share a pipeline with real incident alerting), no NPM
domains, no cross-namespace scraping.

All 14 Deployments are held at `replicas: 0` by default, same as the
compose stack's normal off state. Bring the whole thing up with:

```bash
kubectl -n lab-environment scale deployment --all --replicas=1
```

(or edit `replicas:` in each `k8s/*.yaml` and let ArgoCD sync it, if the
change should stick — `selfHeal` will otherwise revert a bare `kubectl
scale` within a couple minutes).

## After bringing it up: reseed Consul KV

`consul` runs in `-dev` mode and does not persist data — every time it
(re)starts, `config/<service>/data/db.*` (and the chaos toggles) are gone,
and `customers-service`/`vets-service`/`visits-service` will crash-loop on
a Hikari/JDBC placeholder error until the KV keys exist. Re-run the
project's own bootstrap script against the new NodePort:

```bash
CONSUL_HTTP_ADDR="http://localhost:30092" \
  bash ~/jerome/lab-environment/scripts/init-consul-kv.sh
```

This is not new behavior introduced by the k8s migration — the original
compose setup already required re-running this after every
`docker compose up`, it's just pointed at a different Consul address now.

## NodePorts

| Service | NodePort | Was (compose host port) |
|---|---|---|
| consul (UI/API) | 30092 | 8600 |
| prometheus | 30093 | 9190 |
| grafana | 30094 | 3100 |
| jaeger (UI) | 30095 | 16786 |
| mcp-toolkit | 30096 | 8865 |
| api-gateway | 30097 | 180 |

`postgres`, `redis`, `toxiproxy`, `loki`, `promtail`, `customers-service`,
`vets-service`, `visits-service` are ClusterIP-only, matching their
compose state (not published to the host there either).

## Images

`mcp-toolkit`, `customers-service`, `vets-service`, `visits-service`, and
`api-gateway` are local-only builds (`ops-lab/*:dev`, built by the source
project's own `scripts/build.sh`) with no registry behind them —
containerd can't pull them. They were loaded once via:

```bash
docker save ops-lab/<name>:dev | sudo k3s ctr images import -
```

If the source project rebuilds these images, re-run the same import
before scaling the affected Deployment back up, or containerd will keep
serving the stale image it already has cached (no pull happens for an
image containerd already believes it has).

## Data

Only `postgres` is stateful (PVC, seeded once from the compose
`lab-environment_postgres_data` volume). Everything else
(`prometheus`/`grafana`/`loki`) is ephemeral in the original compose
setup too — no data volumes there, so no PVC here either.
