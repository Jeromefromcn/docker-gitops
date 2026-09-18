# vps_oracle2/tofu — full-control adoption of a second OCI tenancy

Same brownfield-import starting point as `vps_oracle/tofu/`, but the IAM
policy in this tenancy is not walled off — it's expected to also cover the
compute instance and boot volume, and to allow lifecycle management
(including `destroy`) going forward, not just the network layer.

## Why this differs from `vps_oracle/tofu/`

- Different tenancy (a separate OCI account), so `auth = "InstancePrincipal"`
  doesn't work here — this repo's host (`vps_oracle`) isn't a member of this
  tenancy. Uses `auth = "ApiKey"` instead (see `provider.tf`).
- Scope is "full control" by choice: import what already exists (the server
  was created by hand, free tier), then decide how much lifecycle management
  (including whether `destroy` is ever exercised) to take on from here.
  Governed by `.claude/rules/tofu-conventions.md` — `destroy` is only a hard
  red line under `vps_oracle/tofu/`, not here.

## Setup checklist

1. **Generate an API signing key** in the vps_oracle2 tenancy's own console:
   Profile icon (top right) -> *My profile* -> *API keys* -> *Add API key* ->
   *Generate API Key Pair*. Download the private key PEM and put it
   **outside this repo** on the host that will run `tofu` (e.g.
   `~/.oci/vps_oracle2_api_key.pem`, `chmod 600`) — never paste key contents
   into a chat or commit them.
2. After adding the key, the console shows a **Configuration file preview**
   with `user`, `fingerprint`, `tenancy`, `region` — copy these into
   `.auto.tfvars` (gitignored, see `.auto.tfvars.example`).
3. `compartment_id` is usually the root compartment, i.e. equal to
   `tenancy_ocid`, unless a sub-compartment was created for this server.
4. Collect the OCIDs of what already exists, from the console (each
   resource's detail page has a "Copy" link next to its OCID):
   - Networking -> Virtual Cloud Networks -> the VCN, its subnet, internet
     gateway, default route table, default security list.
   - Compute -> Instances -> the instance itself, and its boot volume
     (linked from the instance detail page).
5. Fill all of the above into `.auto.tfvars`.
6. Probe + write `network.tf` / `instance.tf` to match the live facts exactly
   (same method `vps_oracle/tofu/README.md` Task 9/10 used: read each
   resource's actual field values from the console or `tofu plan` diff
   output, write them in literally, avoid `ignore_changes` where possible),
   then `import {}` blocks referencing the vars above.
7. Verification standard: `tofu plan` -> `No changes.`

## Status (2026-09-18)

Onboarded. `network.tf` imports the VCN/subnet/IGW/default route table/default
security list, `tofu plan` = `No changes.`.

`instance.tf` is a **fresh creation**, not an import: the original instance
(`instance-20260918-1902`) was launched without a public IP and was
unreachable, so it was destroyed via `tofu` (import-then-remove-from-config,
same pattern as any other cleanup) along with an unrelated orphan VCN found
during the probe (zero subnets, its own stray IGW — leftover from an earlier
console attempt). The new instance (`vps-oracle2`) reuses the same VCN/
subnet/shape/image, this time with `assign_public_ip = true`. SSH access:
dedicated keypair `~/.ssh/id_oracle2` (not shared with any other host), value
lives in `.auto.tfvars`' `ssh_public_key`. See `CLAUDE.local.md` for the
current IP / `ssh vps-oracle2` alias.

Free tier note: Oracle halved the Always-Free Ampere A1.Flex pool from
4 OCPU/24GB to 2 OCPU/12GB tenancy-wide on 2026-06-15. The instance is sized
at the full 2/12 allotment.
