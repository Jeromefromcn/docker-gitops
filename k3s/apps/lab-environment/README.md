# lab-environment on k3s

Migrated from `~/jerome/lab-environment/docker-compose.yml` (a separate,
independently-managed project). Fully isolated `lab-environment`
namespace: no shared Prometheus/Grafana/alerting with `vps_oracle`'s own
monitoring stack (deliberate — this stack's `toxiproxy`-driven chaos
testing shouldn't share a pipeline with real incident alerting), no
cross-namespace scraping. (NPM does expose a few `*.lab.jerome.cloudns.asia`
hosts — api/consul/grafana/jaeger — behind an access list.)

## Runs always-on, on vps-oracle2

Since 2026-09-24 all 14 Deployments run at `replicas: 1` on **vps-oracle2**,
the k3s agent node ([`k3s/install/agent-vps-oracle2/`](../../install/agent-vps-oracle2/README.md)),
instead of sitting at 0 on vps_oracle to save its memory. Placement is not in
these manifests: the Kyverno mutate policy
[`lab-environment-on-oracle2`](../../kyverno/policies/lab-environment-on-oracle2.yaml)
injects `nodeSelector: dedicated=lab` and the matching toleration into every
Pod in this namespace. Monitoring: Grafana `Lab API Down` (end-to-end probe
through oracle2's NodePort) and `vps-oracle2 k3s Kubelet Down`.

The four Spring Boot services have a 1000m CPU limit (was 250m: startup took
61-98 s, half of it CFS-throttled; now ~40-55 s with all four starting at
once on the 2-core node) and startup + readiness probes on the actuator
`liveness`/`readiness` groups, so Ready means serving. If Consul isn't up yet
they exit 1 and retry — they settle on their own once it is.

Every workload carries `trivy-operator.skip: "true"` on its pod template: the
five `ops-lab/*` images can't be pulled for scanning, and nothing consumes the
namespace's reports.

## After bringing it up: seed Consul KV (once)

`consul` runs as a `-server` with on-disk storage on a static local PV
(`consul-data`, see `k8s/pv.yaml`), so its KV survives restarts.
`server_rejoin_age_max` is raised (see `consul.yaml`): with the default 168h,
Consul refuses to start at all after a week offline. The old `-dev` in-memory mode
wiped `config/<service>/data/db.*` (and the chaos toggles) on every restart,
crash-looping `customers-service`/`vets-service`/`visits-service` with a
Hikari/JDBC placeholder error until the keys were re-put. Only seed once, on
first bring-up or after a manual KV reset:

```bash
CONSUL_HTTP_ADDR="http://localhost:30092" \
  bash ~/jerome/lab-environment/scripts/init-consul-kv.sh
```

Note: the PV is node-local on vps-oracle2 — the KV survives a node reboot but
not a node rebuild; re-seed after that.

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
(persists across reboots) — on **vps-oracle2** now that the lab runs there
(vps_oracle keeps its own copy of the setting). This is a node-level setting,
not something expressible in a Pod spec — if the node is ever rebuilt, reapply:

```bash
ssh vps-oracle2 'echo "fs.inotify.max_user_instances = 1024" | sudo tee /etc/sysctl.d/99-inotify-instances.conf && sudo sysctl --system'
```

## NodePorts

Every NodePort answers on vps_oracle's `10.0.0.95` (NPM and the host relay
use this; Cilium forwards to oracle2 over VXLAN) and on vps-oracle2's
tailscale IP `100.100.140.33` (the blackbox probe uses this).

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
project's own `scripts/build.sh`, run on vps_oracle) with no registry
behind them — containerd can't pull them. Build on vps_oracle, then import
into **vps-oracle2's** k3s containerd (use `k3s ctr`: oracle2's plain `ctr` is
docker's, a different containerd):

```bash
cd ~/jerome/lab-environment && ./scripts/build.sh
for i in mcp-toolkit api-gateway visits-service vets-service customers-service; do
  docker save ops-lab/$i:dev | ssh vps-oracle2 'sudo k3s ctr -n k8s.io images import -'
done
```

If the source project rebuilds these images, re-run the import and restart
the affected Deployment, or containerd keeps serving the stale image it
already has (no pull happens for an image it believes it has).

**They are irreplaceable once deleted.** On 2026-09-24 they were found gone:
vps_oracle's `k3s-containerd-images` inspector check runs `crictl rmi
--prune`, and with the lab at `replicas: 0` nothing referenced them. The
oracle2 counterpart (`oracle2-k3s-containerd-images`) removes by ID and
always keeps `ops-lab/*`.

## Data

`postgres` and `consul` are stateful, on static `local` PVs on vps-oracle2
(`k8s/pv.yaml`, `Retain`, `/var/lib/lab-environment/<name>`) — not
local-path, whose helper pod has no toleration for oracle2's taint. Both were
copied from their old vps_oracle local-path PVs on 2026-09-24 (backup:
`/home/ubuntu/backups/lab-environment-pv-2026-09-24.tar.gz` on vps_oracle).
Postgres was originally seeded from the compose
`lab-environment_postgres_data` volume. Everything else
(`prometheus`/`grafana`/`loki`) is ephemeral in the original compose
setup too — no data volumes there, so no PVC here either.

### Restoring data into a PV

The PVs are plain directories on vps-oracle2, so no seed Pod is needed
(that was a local-path `WaitForFirstConsumer` workaround). Stop the
workload by setting its `replicas: 0` in git (a bare `kubectl scale` is
reverted by selfHeal), then copy with ownership preserved — postgres data
is uid 999, consul uid 100:

```bash
sudo tar --numeric-owner -C <source-dir> -cf - . \
  | ssh vps-oracle2 'sudo tar --numeric-owner -xpf - -C /var/lib/lab-environment/<name>'
```

Restore `replicas: 1` in git afterwards.
