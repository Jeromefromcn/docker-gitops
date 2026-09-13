---
paths:
  - "*/tofu/**"
---

# OpenTofu conventions

Must be followed when writing or modifying any `.tf` file under `<host>/tofu/`. This file is the single source of truth; README is only a pointer.

## Red lines

> **`tofu destroy` is forbidden under `vps_oracle/tofu/`.**

The OCI-side IAM no longer grants `manage instance-family`, so `destroy` can't reach the compute instances; but the red line is still written out — defense in depth, one statement for both humans and Claude. On the GCP side, `destroy` under `vps_gcp/tofu/` is the design goal and is exempt from this rule.

## Versions

- Pin `required_version` and `required_providers` in `versions.tf` to exact versions — no ranges, no latest.
- `.terraform.lock.hcl` is a managed file and **must be committed** — it locks provider versions and checksums, the same principle as pinning image tag/digest in compose.

## State and secrets

- `*.tfstate`, `*.tfstate.*`, `.terraform/`, `*.auto.tfvars` are never committed (already in `.gitignore`).
- `.auto.tfvars` holds identity-type values (GCP's `project_id` / `billing_account`; OCI's OCID / compartment / region) and genuinely non-secret values like an SSH **public** key. It's still gitignored, but that's about not committing machine-specific config, not about hiding it — a public key isn't a secret and belongs here so its value survives across shells (a bare `TF_VAR_*` env var doesn't: it's gone the moment the shell exits, and the next `apply` silently reverts whatever depends on it — see `vps_gcp/tofu/instance.tf`'s `ssh_public_key` handling for the incident this caused).
- Private keys, API credentials, and other actual secrets never go in `.auto.tfvars` or any `.tf` file — they live outside the repo, referenced via environment variables (GCP `GOOGLE_APPLICATION_CREDENTIALS`).

## Authentication

- OCI uses Instance Principal: `auth = "InstancePrincipal"`, zero long-lived credentials on disk. The Dynamic Group + policy are created in the console, not in this repo.
- GCP uses a dedicated service account + key JSON, with roles narrowed down (networkAdmin / instanceAdmin.v1 / serviceusage.serviceUsageAdmin); the key lives outside the repo.

## Adoption and free tier

- OCI adoption uses `import {}` blocks (committed to git, reviewable), not one-off `tofu import` commands.
- GCP free tier is a hard boundary: `machine_type`, region, and disk size are hardcoded literals, not variables; the first batch of resources already includes `google_billing_budget`.