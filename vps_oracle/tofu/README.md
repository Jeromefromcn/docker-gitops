# vps_oracle/tofu — brownfield root module

Practices the brownfield half: `import` resources that already exist and were hand-modified via the console, tame drift, `ignore_changes`. This machine can never be rebuilt from scratch — this is the only half there is to practice here.

## Red line

> **`tofu destroy` is forbidden in this directory.**

The IAM hard wall already keeps `destroy` from reaching the compute instance or boot volume (the policy only grants `manage virtual-network-family`), but the red line is still written out explicitly — defense in depth.

## Verification standard

`tofu plan` outputs `No changes.`

This step takes longer than expected: the OCI API returns a pile of default fields the console never shows, and aligning them one by one — or deciding which ones belong in `ignore_changes` — is the actual work of this section.

## Directory layout

| File | Responsibility |
|---|---|
| `versions.tf` | required_version / required_providers (pins exact versions) |
| `provider.tf` | `auth = "InstancePrincipal"` |
| `variables.tf` | region / tenancy_ocid / compartment_id + five resource OCIDs |
| `network.tf` | VCN / subnet / IGW / route table / security list |
| `imports.tf` | `import {}` blocks (id references a variable; the actual OCID lives in `.auto.tfvars`) |

OCIDs go in the gitignored `.auto.tfvars` (see `.auto.tfvars.example`) — never committed to git.

## Adoption status (2026-09-10, Task 10)

This machine's public subnet uses the VCN's **default** route table / security list, so:

- `network.tf` uses `oci_core_default_route_table` / `oci_core_default_security_list` (**not** the plain `oci_core_route_table` / `oci_core_security_list`).
- ⚠️ **Gotcha**: these two default resources' `manage_default_resource_id` takes **the default resource's own OCID**, **not the VCN's id**. Setting it to `oci_core_vcn.main.id` triggers a force replacement (`destroy + recreate`), which could break live routing/security rules. Correct reference: `oci_core_vcn.main.default_route_table_id` / `oci_core_vcn.main.default_security_list_id` (attributes exposed by the VCN resource, which happen to equal these two default resources' ids).
- The current config is fully aligned with what's live, **no `ignore_changes` used** — every field from the factsheet (including the vless port's `description = "vless port"`) is written into `network.tf`.
- All five resource types `import`ed successfully, `tofu plan` = `No changes.`.

## IAM hard-wall verification (2026-09-10, Task 11)

Negative verification: `data.oci_core_instance` points at this machine's own instance, expecting OCI to error out on unauthorized compute access. **In practice, OCI provider 9.0.0 handles an unauthorized instance as a "silent empty shell" — `Read complete` but every field is `null`, no hard error** (the plan doc expected NotAuthorizedOrNotFound; actual behavior differs).

Chain of evidence that the hard wall is in effect (three-way comparison):

1. `oci_core_vcns` reads the full VCN (network-family authorization works).
2. The same identity's `oci_core_instances` returns an empty list (can't read compute).
3. `oci_core_instance.self` returns an all-null empty shell (unauthorized silent degradation).

Conclusion: the Instance Principal **can manage networking but not compute** — consistent with the design of the single `manage virtual-network-family` policy. When an instance data source shows `Read complete`, don't mistake that for "successfully read" — check whether the fields are all null.
