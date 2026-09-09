# vps_gcp

GCP 免费层（free tier）e2-micro 实例。目前这台机器整机**不**纳入本仓库管理——这里只有 `tofu/` 一层，用于练 greenfield IaC 的完整生命周期（从零 apply → destroy → 再 apply 验证可重现）。

## 目前纳管范围

| 目录 | 是什么 | 约定见 |
|---|---|---|
| `tofu/` | OpenTofu root module：VPC / subnet / firewall / e2-micro 实例 / API 启用 / 预算告警 | [tofu/README.md](tofu/README.md) |

机器上跑什么、怎么部署、README 怎么写，另案处理；本目录暂时只此一层。
