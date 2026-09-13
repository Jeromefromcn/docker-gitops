# vps_gcp

A GCP free-tier e2-micro instance. This machine as a whole is currently **not** managed by this repo — only the `tofu/` layer lives here, for practicing the full greenfield IaC lifecycle (from-scratch apply → destroy → re-apply to verify reproducibility).

## Currently managed scope

| Directory | What it is | Conventions in |
|---|---|---|
| `tofu/` | OpenTofu root module: VPC / subnet / firewall / e2-micro instance / API enablement / budget alert | [tofu/README.md](tofu/README.md) |

What runs on the machine, how it's deployed, and how its README is written are handled separately; for now this directory only contains this one layer.