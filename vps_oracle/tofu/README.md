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

## 收编现状（2026-09-10，Task 10）

这台机器的 public subnet 用的是 VCN 的**默认** route table / security list，所以：

- `network.tf` 用 `oci_core_default_route_table` / `oci_core_default_security_list`（**不是**普通 `oci_core_route_table` / `oci_core_security_list`）。
- ⚠️ **踩坑**：这两个 default 资源的 `manage_default_resource_id` 填的是**该默认资源自己的 OCID**，**不是 VCN 的 id**。填 `oci_core_vcn.main.id` 会触发 force replacement（`destroy + recreate`），可能破坏线上路由/安全规则。正确引用：`oci_core_vcn.main.default_route_table_id` / `oci_core_vcn.main.default_security_list_id`（VCN 资源暴露的属性，正好等于这两个默认资源的 id）。
- 当前配置与线上完全对齐，**没有用 `ignore_changes`**——factsheet 里的字段（含 vless 端口的 `description = "vless 端口"`）都写进了 `network.tf`。
- 五类资源全部 `import` 成功，`tofu plan` = `No changes.`。

## IAM 硬墙验证（2026-09-10，Task 11）

负验证：`data.oci_core_instance` 指向本机实例，预期 OCI 对未授权 compute 报错。**实测 OCI provider 9.0.0 对未授权实例是「静默空壳」——`Read complete` 但所有字段为 `null`，不硬报错**（计划文档预期 NotAuthorizedOrNotFound，实际行为不同）。

硬墙生效的证据链（三处对照）：

1. `oci_core_vcns` 读到完整 VCN（network-family 授权生效）。
2. 同一身份 `oci_core_instances` 返回空列表（compute 读不到）。
3. `oci_core_instance.self` 返回全 null 空壳（未授权静默降级）。

结论：Instance Principal **能管网络、管不了 compute**——符合 `manage virtual-network-family` 单条 policy 的设计。看到 `Read complete` 的实例 data source 时不要误判为「读到了」，检查字段是否全 null。
