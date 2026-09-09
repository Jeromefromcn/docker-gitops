# vps_oracle/tofu — brownfield root module

练习 brownfield 的那半：`import` 已存在且被 console 手改过的资源、驯服 drift、`ignore_changes`。这台机器永远不能重建，只能练这半。

## 红线

> **禁止在此目录执行 `tofu destroy`。**

IAM 硬墙已让 `destroy` 打不到运算实例与 boot volume（policy 只授 `manage virtual-network-family`），但红线仍要写明——纵深防御。

## 验证标准

`tofu plan` 输出 `No changes.`

这一步会比预期久：OCI API 会回一堆 console 从未显示的默认字段，逐个对齐、或判断哪些该进 `ignore_changes`，就是这节的功课。

## 目录说明

| 文件 | 职责 |
|---|---|
| `versions.tf` | required_version / required_providers（钉死版本） |
| `provider.tf` | `auth = "InstancePrincipal"` |
| `variables.tf` | region / tenancy_ocid / compartment_id + 五个资源 OCID |
| `network.tf` | VCN / subnet / IGW / route table / security list |
| `imports.tf` | `import {}` 区块（id 引用变量，实测 OCID 放 `.auto.tfvars`） |

OCID 填在 gitignored 的 `.auto.tfvars`（见 `.auto.tfvars.example`），不进 git。

若探查发现这台用的是**默认**路由表/安全列表（display name 为 "Default Route Table/Security List for <vcn>"），resource 型别要用 `oci_core_default_route_table` / `oci_core_default_security_list`（见 Task 10 的分支说明）。
