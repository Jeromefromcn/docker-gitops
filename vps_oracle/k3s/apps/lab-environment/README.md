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

## After bringing it up: seed Consul KV (once)

`consul` runs as a `-server` with on-disk storage on a local-path PVC
(`consul-data`), so its KV survives restarts. The old `-dev` in-memory mode
wiped `config/<service>/data/db.*` (and the chaos toggles) on every restart,
crash-looping `customers-service`/`vets-service`/`visits-service` with a
Hikari/JDBC placeholder error until the keys were re-put. Only seed once, on
first bring-up or after a manual KV reset:

```bash
CONSUL_HTTP_ADDR="http://localhost:30092" \
  bash ~/jerome/lab-environment/scripts/init-consul-kv.sh
```

Note: local-path is node-local — the KV survives a node reboot but not a node
rebuild; re-seed after that.

## Host prerequisite: `fs.inotify.max_user_instances`

promtail tails every pod's log file individually (one inotify watch per
file, not per directory), and this node's default
(`fs.inotify.max_user_instances=128`) was already ~70/128 consumed by
everything else running as root on the box (containerd, cilium, other
pods) before this stack's 13 log files pushed it over the edge —
promtail crashed on startup with `too many open files` even though
`ulimit -n` itself was effectively unlimited (this is a separate,
unrelated kernel limit, not a per-container rlimit).

Raised to 1024 host-wide via `/etc/sysctl.d/99-inotify-instances.conf`
(persists across reboots). This is a node-level setting, not something
expressible in a Pod spec — if this node is ever rebuilt, reapply:

```bash
echo "fs.inotify.max_user_instances = 1024" | sudo tee /etc/sysctl.d/99-inotify-instances.conf
sudo sysctl --system
```

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
