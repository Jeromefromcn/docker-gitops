# vps_gcp

A GCP free-tier e2-micro instance. This machine as a whole is currently **not** managed by this repo — only the `tofu/` layer (practicing the full greenfield IaC lifecycle, from-scratch apply → destroy → re-apply to verify reproducibility) and a thin `compose/` layer (`node-exporter` and `glances` monitoring targets plus the `plans` web app, all run against GCP's docker daemon over SSH — see [../CLAUDE.local.md](../CLAUDE.local.md)).

## Currently managed scope

| Directory | What it is | Conventions in |
|---|---|---|
| `tofu/` | OpenTofu root module: VPC / subnet / firewall / e2-micro instance / API enablement / budget alert | [tofu/README.md](tofu/README.md) |
| `inspector-checks/` | inspection checks about this host, executed on vps_oracle by its inspector over SSH | [inspector-checks/README.md](inspector-checks/README.md) |
| `compose/` | Stacks `node-exporter`, `glances`, `plans`, run via `docker --context gcp`, and bound to this node's tailscale IP only (`100.96.184.44`), not `0.0.0.0` — reachable from vps_oracle's prometheus/homepage/NPM over the oracle↔GCP tailscale mesh. `plans` (port 8081, private content) is built on GCP's daemon from `~/jerome/plans` on vps_oracle via `plans/deploy.sh`; no source or git credentials are stored on GCP, and `plans.jerome.cloudns.asia` is reverse-proxied by NPM to `100.96.184.44:8081` | root [README.md](../README.md) |

What runs on the machine, how it's deployed, and how its README is written are handled separately; for now this directory only contains these layers.