---
paths:
  - "*/tofu/**"
---

# OpenTofu 约定

编写或修改任何 `<host>/tofu/` 下的 .tf 文件时必须遵守。这里是唯一权威，README 只做指引。

## 红线

> **禁止在 `vps_oracle/tofu/` 执行 `tofu destroy`。**

OCI 侧 IAM 已不授予 `manage instance-family`，`destroy` 打不到运算实例；但红线仍要写明——纵深防御，对人、对 Claude 都是同一份说明。GCP 侧 `vps_gcp/tofu/` 的 destroy 是设计目标，不受此限。

## 版本

- `versions.tf` 里 `required_version` 与 `required_providers` 钉死具体版本，不用范围、不用 latest。
- `.terraform.lock.hcl` 是纳管文件，**必须提交**——锁 provider 版本与 checksum，跟 compose 钉死 image tag/digest 同理。

## State 与机密

- `*.tfstate`、`*.tfstate.*`、`.terraform/`、`*.auto.tfvars` 一律不提交（已在 `.gitignore`）。
- `.auto.tfvars` 只放身份类值（GCP 的 `project_id` / `billing_account`；OCI 的 OCID / compartment / region），不放 key。key 放仓库之外，经环境变量引用（GCP `GOOGLE_APPLICATION_CREDENTIALS`）。
- 不在任何 `.tf` 里内联密钥、key、token。

## 认证

- OCI 用 Instance Principal：`auth = "InstancePrincipal"`，磁盘零长期凭据。Dynamic Group + policy 在 console 建，不在仓库。
- GCP 用专设 service account + key JSON，角色收窄（networkAdmin / instanceAdmin.v1 / serviceusage.serviceUsageAdmin），key 存仓库外。

## 收编与免费层

- OCI 收编用 `import {}` 区块（进 git、可 review），不用 `tofu import` 一次性指令。
- GCP 免费层是硬边界：`machine_type`、区域、磁盘大小写死字面值、不用变量；第一批资源就含 `google_billing_budget`。
