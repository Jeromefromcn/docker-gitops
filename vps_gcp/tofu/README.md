# vps_gcp/tofu — greenfield root module

练习 greenfield 的那半：完整生命周期，从零 apply → 改 → destroy → 再 apply 验证可重现。

## 免费层边界（敲死，别动）

| 项 | 值 | 为什么 |
|---|---|---|
| region / zone | `us-west1` / `us-west1-a` | e2-micro 仅 us-west1/us-central1/us-east1 免费 |
| machine_type | `e2-micro` | 写死字面值，不用变量，防手滑改成 e2-medium |
| boot disk | 30 GB `pd-standard` | 免费层 30 GB 标准永久磁盘总额 |
| egress | 1 GB/月（不含中国/澳洲） | 见 instance.tf 注释 |

## 认证

专设 service account + key JSON。角色收窄到 `roles/compute.networkAdmin`、`roles/compute.instanceAdmin.v1`、`roles/serviceusage.serviceUsageAdmin`。

- key 放仓库之外，经环境变量引用：`export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json`
- `.auto.tfvars`（gitignored）填 `project_id`、`project_number` 与 `billing_account` 三个必填项，见 `.auto.tfvars.example`。`project_number` 是纯数字的项目编号，跟字母数字的 `project_id` 是两个不同的标识——budget 的 `budget_filter.projects` 只认 `projects/{project_number}`。

`google_billing_budget` 的权限挂在**账单账户**上、不是项目上——需在账单账户层级授 `roles/billing.costsManager`。

## 验收标准

`tofu destroy` 之后 `tofu apply` 能完整重现，且重现后 `tofu plan` 输出 `No changes.`。

## 操作

```bash
cd vps_gcp/tofu
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json
cp .auto.tfvars.example .auto.tfvars   # 填 project_id / project_number / billing_account
tofu init
tofu plan    # 验收：终态 No changes.
tofu apply
```
