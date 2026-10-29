# vps_gcp

A GCP free-tier e2-micro instance, used to practice the full greenfield IaC lifecycle (from-scratch apply → destroy → re-apply to verify reproducibility).

**Stopped long-term since 2026-10-29.** Everything that ran on it was removed or moved at that point:

- `plans` (the only real workload) moved to [vps_oracle2](../vps_oracle2/README.md).
- The `node-exporter` / `glances` / `portainer-agent` compose stacks, the `inspector-checks/` tree, the prometheus `node_gcp` scrape job, its Grafana dashboard and the homepage cards were deleted — recover them from git history if the instance is brought back.

The tailnet node and its `tag:gcp-lab` ACL entries in [`../tailscale/policy.hujson`](../tailscale/policy.hujson) are left as-is; an offline node is harmless there.

## Currently managed scope

| Directory | What it is | Conventions in |
|---|---|---|
| `tofu/` | OpenTofu root module: VPC / subnet / firewall / e2-micro instance / API enablement / budget alert | [tofu/README.md](tofu/README.md) |
