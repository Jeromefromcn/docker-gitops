# OpenTofu Integration Implementation Plan (vps_oracle adoption + vps_gcp sandbox)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land a complete OpenTofu IaC setup in the repo — `vps_gcp` full greenfield lifecycle + `vps_oracle` brownfield adoption, each with its own root module, its own state, its own credentials, plus a path-scoped rules file and CI static checks.

**Architecture:** Two independent root modules (`vps_gcp/tofu/`, `vps_oracle/tofu/`), living alongside the existing host-first directory structure, each with its own local `*.tfstate` + gitignore. GCP uses a dedicated service account + key (roles narrowed down); OCI uses Instance Principal (zero credentials on disk + an IAM hard wall). CI runs static checks (`tofu fmt -check` + `tofu validate`) only, never touching anything live.

**Tech Stack:** OpenTofu 1.12.6, provider `oracle/oci` 9.0.0, provider `hashicorp/google` 8.2.0, GitHub Actions `opentofu/setup-opentofu@v1` (`tofu_version: 1.12.6`).

**Spec:** [docs/superpowers/specs/2026-09-09-opentofu-integration-design.md](../specs/2026-09-09-opentofu-integration-design.md) (this plan defers to the spec — whoever executes it must read the spec alongside it)

## Global Constraints

- **What tofu can do = exactly what the identity handed to it is authorized to do by IAM, no more, no less.** Least privilege is set in IAM, not in Terraform.
- **Never run `tofu destroy` in `vps_oracle/tofu/`.** (The IAM hard wall already makes it unable to reach the instances, but the red line still needs to be written down — defense in depth.)
- GCP free-tier hard boundaries (exceed them and it's real money): e2-micro is free only in us-west1 / us-central1 / us-east1; 30 GB total standard persistent disk; 1 GB/month egress (excludes China and Australia). `machine_type` / region / disk size are **hardcoded literals, not variables**.
- Versions pinned: `required_version` and `required_providers` use exact versions, no ranges, no latest. `.terraform.lock.hcl` must be committed.
- No secrets committed: `*.tfstate`, `*.tfstate.*`, `.terraform/`, `*.auto.tfvars` are all gitignored; the GCP key JSON lives outside the repo, referenced via the `GOOGLE_APPLICATION_CREDENTIALS` env var.
- OCI adoption uses `import {}` blocks (goes into git, reviewable), not one-off `tofu import` commands.
- The two root modules, two states, and two sets of credentials are isolated from each other — a broken OCI state doesn't block GCP work.
- English commit messages (this repo's convention).

---

## Prerequisites (blocking, manual console operations, cannot be done by Claude)

Before starting Phase 1's live steps (Task 7) and Phase 2's live steps (Tasks 9–11), whoever executes this plan must confirm item-by-item with the user that all of the following are done:

1. **Install OpenTofu (arm64)**: make `tofu` available on the host's PATH, version ≥ 1.12 (1.12.6 recommended).
2. **OCI**: in the console, create a Dynamic Group (matching this machine's OCID) + one policy that grants only `manage virtual-network-family`.
3. **GCP**: create a dedicated service account, grant the three roles `roles/compute.networkAdmin`, `roles/compute.instanceAdmin.v1`, `roles/serviceusage.serviceUsageAdmin`, generate a key JSON and store it outside the repo.
4. **GCP billing account** (the easiest one to get wrong): `google_billing_budget`'s permission is attached at the **billing account** level, not the project level — `roles/billing.costsManager` (or equivalent) must be granted at the billing-account level. No amount of project-level roles can reach the budget.

> Claude can prepare the exact console click-paths / commands for each item above, but the actual authorization action must be performed by the user. Step 1 of every live apply/import task (Tasks 7, 9, 10, 11) starts with "confirm the prerequisites are ready."

---

### Task 1: Repo guardrails — `.gitignore` + `tofu-conventions.md`

**Files:**
- Modify: `.gitignore` (append 4 lines at the end)
- Create: `.claude/rules/tofu-conventions.md`

**Interfaces:**
- Produces: rules file `.claude/rules/tofu-conventions.md` (`paths: */tofu/**`, governs all `.tf` changes in every later task); `.gitignore`'s state/tfvars exclusions (so the `*.tfstate` / `.auto.tfvars` produced by later tasks don't get committed by mistake).

- [ ] **Step 1: Append to the end of `.gitignore`**

```gitignore
# OpenTofu (vps_oracle/tofu, vps_gcp/tofu)
*.tfstate
*.tfstate.*
.terraform/
*.auto.tfvars
```

- [ ] **Step 2: Write `.claude/rules/tofu-conventions.md`** (format aligned with the existing `compose-conventions.md` / `k3s-gitops.md`: `paths:` frontmatter + prose body)

```markdown
---
paths:
  - "*/tofu/**"
---

# OpenTofu conventions

Must be followed when writing or modifying any `.tf` file under `<host>/tofu/`. This is the single source of truth here; the README is only a pointer.

## Red lines

> **`tofu destroy` is forbidden in `vps_oracle/tofu/`.**

The OCI-side IAM no longer grants `manage instance-family`, so `destroy` cannot reach the compute instance; but the red line still needs to be written down — defense in depth, the same statement for both humans and Claude. On the GCP side, destroy under `vps_gcp/tofu/` is the design goal and is not subject to this restriction.

## Versions

- In `versions.tf`, pin `required_version` and `required_providers` to exact versions — no ranges, no latest.
- `.terraform.lock.hcl` is a managed file and **must be committed** — it locks provider versions and checksums, the same principle as pinning image tag/digest in compose.

## State and secrets

- `*.tfstate`, `*.tfstate.*`, `.terraform/`, `*.auto.tfvars` are never committed (already in `.gitignore`).
- `.auto.tfvars` holds only identity-type values (GCP's `project_id` / `billing_account`; OCI's OCID / compartment / region), never a key. Keys live outside the repo, referenced via environment variables (GCP `GOOGLE_APPLICATION_CREDENTIALS`).
- Never inline a secret, key, or token in any `.tf` file.

## Authentication

- OCI uses Instance Principal: `auth = "InstancePrincipal"`, zero long-lived credentials on disk. The Dynamic Group + policy are created in the console, not in this repo.
- GCP uses a dedicated service account + key JSON, with roles narrowed down (networkAdmin / instanceAdmin.v1 / serviceusage.serviceUsageAdmin); the key lives outside the repo.

## Adoption and free tier

- OCI adoption uses `import {}` blocks (goes into git, reviewable), not one-off `tofu import` commands.
- GCP free tier is a hard boundary: `machine_type`, region, and disk size are hardcoded literals, not variables; the first batch of resources already includes `google_billing_budget`.
```

- [ ] **Step 3: Self-verify the rules file's frontmatter format** (the same YAML `paths:` shape as `compose-conventions.md`)

Run: `head -6 .claude/rules/tofu-conventions.md` (should show `---` / `paths:` / `  - "*/tofu/**"` / `---`)

- [ ] **Step 4: Commit**

```bash
git add .gitignore .claude/rules/tofu-conventions.md
git commit -m "chore: add OpenTofu conventions rule and gitignore state/tfvars"
```

---

### Task 2: CI static checks — the `tofu` job

**Files:**
- Modify: `.github/workflows/repo-conventions.yml` (`paths` trigger + a new job)

**Interfaces:**
- Consumes: Task 1's `*/tofu/**` directory (at the time this task lands there's no `.tf` yet — `find` won't locate the directory, the loop runs empty, exits 0).
- Produces: CI job `tofu`, gatekeeping every `.tf` file added by later tasks with `fmt -check` + `validate`.

- [ ] **Step 1: Extend the `paths` trigger** (add to both `push` and `pull_request`, pointing at `'*/tofu/**'`)

```yaml
    paths:
      - '*/compose/**/docker-compose.yml'
      - 'vps_oracle/host-native/inspector/**'
      - '*/tofu/**'
      - '.github/scripts/**'
      - '.github/workflows/repo-conventions.yml'
```

- [ ] **Step 2: Add the `tofu` job** (after `inspector-tests`)

```yaml
  # Static checks only — tofu fmt + validate never touch live cloud resources.
  # `tofu init -backend=false` only downloads provider plugins from the
  # registry; it needs no cloud credentials (OCI's InstancePrincipal /
  # GCP's key are never exercised by `validate`).
  tofu:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up OpenTofu
        uses: opentofu/setup-opentofu@v1
        with:
          tofu_version: 1.12.6

      - name: tofu fmt -check + init + validate
        run: |
          failed=0
          for d in $(find . -type d -name tofu -not -path './.worktrees/*'); do
            echo "--- $d"
            (cd "$d" && tofu fmt -recursive -check) || failed=1
            (cd "$d" && tofu init -backend=false -input=false >/dev/null) || failed=1
            (cd "$d" && tofu validate) || failed=1
          done
          exit $failed
```

- [ ] **Step 3: Verify the YAML syntax**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/repo-conventions.yml'))"` (no output means it passed)

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/repo-conventions.yml
git commit -m "ci: add OpenTofu fmt/validate static checks"
```

---

### Task 3: `vps_gcp/` skeleton + `vps_gcp/tofu/` scaffold

**Files:**
- Create: `vps_gcp/README.md`
- Create: `vps_gcp/tofu/README.md`
- Create: `vps_gcp/tofu/versions.tf`
- Create: `vps_gcp/tofu/provider.tf`
- Create: `vps_gcp/tofu/variables.tf`
- Create: `vps_gcp/tofu/.auto.tfvars.example`
- Modify: `README.md` (add a `vps_gcp` row to the Host list table)

**Interfaces:**
- Produces: `var.project_id` (string, required), `var.billing_account` (string, required) — referenced by Task 4/5/6's provider and budget resources; resource names like `google_compute_network.main` are defined starting in Task 4.

- [ ] **Step 1: `vps_gcp/README.md`** (explains that this machine currently only has a tofu layer under management)

```markdown
# vps_gcp

A GCP free-tier e2-micro instance. This machine as a whole is **not** yet brought under this repo's management — only the `tofu/` layer exists here, used to practice the full greenfield IaC lifecycle (from a from-scratch apply → destroy → re-apply verifying it's reproducible).

## Currently under management

| Directory | What it is | Conventions in |
|---|---|---|
| `tofu/` | OpenTofu root module: VPC / subnet / firewall / e2-micro instance / API enablement / budget alerts | [tofu/README.md](tofu/README.md) |

What runs on the machine, how it's deployed, and how that README should read is a separate matter — for now this directory has only this one layer.
```

- [ ] **Step 2: `vps_gcp/tofu/README.md`**

```markdown
# vps_gcp/tofu — greenfield root module

The half that practices greenfield: the full lifecycle, from a from-scratch apply → change → destroy → re-apply verifying it's reproducible.

## Free-tier boundaries (fixed, don't touch)

| Item | Value | Why |
|---|---|---|
| region / zone | `us-west1` / `us-west1-a` | e2-micro is free only in us-west1/us-central1/us-east1 |
| machine_type | `e2-micro` | hardcoded literal, not a variable, to prevent an accidental change to e2-medium |
| boot disk | 30 GB `pd-standard` | the free tier's total 30 GB standard persistent disk allowance |
| egress | 1 GB/month (excludes China/Australia) | see the comment in instance.tf |

## Authentication

A dedicated service account + key JSON. Roles narrowed down to `roles/compute.networkAdmin`, `roles/compute.instanceAdmin.v1`, `roles/serviceusage.serviceUsageAdmin`.

- The key lives outside the repo, referenced via an environment variable: `export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json`
- `.auto.tfvars` (gitignored) fills in the two required values `project_id` and `billing_account` — see `.auto.tfvars.example`.

`google_billing_budget`'s permission is attached at the **billing account** level, not the project — `roles/billing.costsManager` must be granted at the billing-account level.

## Acceptance criteria

After a `tofu destroy`, `tofu apply` must fully reproduce the setup, and afterward `tofu plan` must output `No changes.`.

## Operation

```bash
cd vps_gcp/tofu
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json
cp .auto.tfvars.example .auto.tfvars   # fill in project_id / billing_account
tofu init
tofu plan    # acceptance: final state is No changes.
tofu apply
```
```

- [ ] **Step 3: `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.12.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.2.0"
    }
  }
}
```

- [ ] **Step 4: `provider.tf`**

```hcl
# Credentials come from the GOOGLE_APPLICATION_CREDENTIALS env var (a dedicated
# SA key living OUTSIDE this repo) — never inline a key here. The provider
# reads it implicitly; no `credentials` attribute is set on purpose.
provider "google" {
  project = var.project_id
  region  = "us-west1" # free-tier region, hardcoded (see README)
}
```

- [ ] **Step 5: `variables.tf`**

```hcl
variable "project_id" {
  description = "GCP project ID that owns the resources."
  type        = string
}

variable "billing_account" {
  description = "GCP billing account ID (format A1B2C3-D4E5F6-G7H8I9) for the budget; needs roles/billing.costsManager at the BILLING ACCOUNT level, not the project."
  type        = string
}
```

- [ ] **Step 6: `.auto.tfvars.example`** (a committed placeholder template, no real values; matches the repo's existing `.env.example` convention)

```hcl
project_id      = ""
billing_account = ""
```

- [ ] **Step 7: Add one row to the root `README.md` Host list**

```markdown
| vps_gcp | GCP free-tier e2-micro (only the `tofu/` layer is under management) | [vps_gcp/README.md](vps_gcp/README.md) |
```

- [ ] **Step 8: Static validation** (this module currently has no resources, a pure schema check)

Run:
```bash
cd vps_gcp/tofu && tofu fmt -recursive -check && tofu init -backend=false -input=false && tofu validate
```
Expected: all green, `Success! The configuration is valid.`

- [ ] **Step 9: Confirm `.auto.tfvars.example` is not caught by gitignore**

Run: `git status --ignored --short vps_gcp/tofu/` (the `example` file should show as staged for commit, not ignored)

- [ ] **Step 10: Commit**

```bash
git add vps_gcp README.md
git commit -m "feat(vps_gcp): scaffold OpenTofu greenfield root module"
```

---

### Task 4: GCP networking — VPC / subnet / firewall

**Files:**
- Create: `vps_gcp/tofu/network.tf`
- Create: `vps_gcp/tofu/firewall.tf`

**Interfaces:**
- Consumes: `var.project_id` (Task 3); the provider is already configured for region `us-west1`.
- Produces: `google_compute_network.main`, `google_compute_subnetwork.main`, `google_compute_firewall.ssh` — the first two are referenced by Task 5's `network_interface`.

- [ ] **Step 1: `network.tf`**

```hcl
resource "google_compute_network" "main" {
  name                    = "vps-gcp-vpc"
  auto_create_subnetworks = false # custom-mode VPC: full control over the subnet
}

resource "google_compute_subnetwork" "main" {
  name          = "vps-gcp-subnet"
  network       = google_compute_network.main.id
  region        = "us-west1"
  ip_cidr_range = "10.0.0.0/24"
}
```

- [ ] **Step 2: `firewall.tf`**

```hcl
# Only SSH ingress. The instance itself carries the free-tier egress boundary.
resource "google_compute_firewall" "ssh" {
  name    = "allow-ssh"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
}
```

- [ ] **Step 3: Static validation**

Run:
```bash
cd vps_gcp/tofu && tofu fmt -recursive -check && tofu init -backend=false -input=false && tofu validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add vps_gcp/tofu/network.tf vps_gcp/tofu/firewall.tf
git commit -m "feat(vps_gcp): declare VPC, subnet and SSH firewall rule"
```

---

### Task 5: GCP compute — the e2-micro instance + API enablement

**Files:**
- Create: `vps_gcp/tofu/instance.tf`
- Create: `vps_gcp/tofu/services.tf`

**Interfaces:**
- Consumes: `google_compute_network.main.id` / `google_compute_subnetwork.main.id` (Task 4); `var.project_id` (Task 3).
- Produces: `google_compute_instance.vps`, `google_project_service.*` (no later task depends on these; the budget doesn't depend on the instance either).

- [ ] **Step 1: `instance.tf`**

```hcl
# FREE-TIER BOUNDARY — every value below is a hardcoded literal on purpose,
# NOT a variable. Changing machine_type / region / disk size can produce real
# billing. See the README's "free-tier boundaries" section before touching anything here.
resource "google_compute_instance" "vps" {
  name         = "vps-gcp"
  machine_type = "e2-micro"   # free only in us-west1/us-central1/us-east1
  zone         = "us-west1-a"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 30          # 30 GB is the free-tier standard-PD total
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = google_compute_network.main.id
    subnetwork = google_compute_subnetwork.main.id

    access_config {
      # ephemeral public IP — free tier allows 1 GB egress/month (excl. CN/AU)
    }
  }
}
```

- [ ] **Step 2: `services.tf`**

```hcl
# Declaratively track "which APIs are enabled". `disable_on_destroy = false`
# means the destroy/apply acceptance test does not tear down the APIs, only
# the resources on top of them.
resource "google_project_service" "compute" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "billingbudgets" {
  project            = var.project_id
  service            = "billingbudgets.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudbilling" {
  project            = var.project_id
  service            = "cloudbilling.googleapis.com"
  disable_on_destroy = false
}
```

- [ ] **Step 3: Static validation**

Run:
```bash
cd vps_gcp/tofu && tofu fmt -recursive -check && tofu init -backend=false -input=false && tofu validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add vps_gcp/tofu/instance.tf vps_gcp/tofu/services.tf
git commit -m "feat(vps_gcp): declare free-tier e2-micro instance and API enablement"
```

---

### Task 6: GCP cost guardrail — `google_billing_budget`

**Files:**
- Create: `vps_gcp/tofu/budget.tf`

**Interfaces:**
- Consumes: `var.billing_account` (Task 3); `var.project_id` (Task 3).
- Produces: `google_billing_budget.free_tier` — wraps up Phase 1, nothing downstream depends on it.

- [ ] **Step 1: `budget.tf`**

```hcl
# The budget's permission lives on the BILLING ACCOUNT, not the project —
# `roles/billing.costsManager` must be granted at the billing-account level in
# the console. A project-level role cannot see budgets regardless of scope.
resource "google_billing_budget" "free_tier" {
  billing_account = var.billing_account
  display_name    = "free-tier-guard"

  amount {
    specified_amount {
      currency_code = "USD"
      units         = "1"
    }
  }

  # ~$0.50 and ~$0.90 of the $1.00 cap — an early warning well inside the
  # free tier, not at its edge.
  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }

  budget_filter {
    projects = ["projects/${var.project_id}"]
  }
}
```

- [ ] **Step 2: Static validation**

Run:
```bash
cd vps_gcp/tofu && tofu fmt -recursive -check && tofu init -backend=false -input=false && tofu validate
```
Expected: `Success! The configuration is valid.`

> If provider 8.2.0 has renamed a `budget_filter` field, `validate` will surface it right here — align the field name to the error message without changing the intent. This is the one resource most likely to need a small tweak due to the provider version.

- [ ] **Step 3: Commit**

```bash
git add vps_gcp/tofu/budget.tf vps_gcp/tofu/.terraform.lock.hcl
git commit -m "feat(vps_gcp): add free-tier billing budget with alerts"
```

> Note: this step's first `tofu init` will produce `.terraform.lock.hcl` — make sure to commit it too (the spec requires the lock file to be in git).

---

### Task 7: GCP live acceptance — apply → destroy → apply → No changes

**Files:** none (pure operations); if a drift fix is needed, edit the corresponding `.tf` and add it to this task.

**Interfaces:**
- Consumes: the whole GCP module defined by Tasks 3–6.
- Produces: live GCP resources; Phase 1 acceptance evidence (`tofu plan` = `No changes.`).

> **PREREQ gate**: Prerequisites 1 (tofu installed), 3 (SA key), 4 (billing costsManager) are done; `GOOGLE_APPLICATION_CREDENTIALS` and `.auto.tfvars` are ready.

- [ ] **Step 1: Confirm credentials and tfvars are ready**

Run:
```bash
cd vps_gcp/tofu
test -n "$GOOGLE_APPLICATION_CREDENTIALS" && test -f "$GOOGLE_APPLICATION_CREDENTIALS" && echo "creds OK"
test -s .auto.tfvars && grep -qE '^(project_id|billing_account)\s*=\s*"[^"]+"' .auto.tfvars && echo "tfvars OK"
```
Expected: `creds OK` and `tfvars OK`.

- [ ] **Step 2: `tofu init`**

Run: `cd vps_gcp/tofu && tofu init`

- [ ] **Step 3: `tofu plan` to review the resource list**

Run: `cd vps_gcp/tofu && tofu plan`
Expected: the plan lists VPC / subnet / firewall / instance / 3× `google_project_service` / budget, no errors. Manually confirm the instance's `machine_type = e2-micro`, `zone = us-west1-a`, `size = 30`.

- [ ] **Step 4: `tofu apply`**

Run: `cd vps_gcp/tofu && tofu apply`
Expected: everything created successfully, `Apply complete!`.

- [ ] **Step 5: `tofu destroy`** (the full greenfield lifecycle — exactly the half the spec permanently forbids practicing on vps_oracle)

Run: `cd vps_gcp/tofu && tofu destroy`
Expected: everything deleted (the enabled APIs stay, due to `disable_on_destroy=false`).

- [ ] **Step 6: `tofu apply` again to verify it's reproducible**

Run: `cd vps_gcp/tofu && tofu apply`
Expected: full reproduction.

- [ ] **Step 7: Acceptance `tofu plan`**

Run: `cd vps_gcp/tofu && tofu plan`
Expected: **`No changes. Your infrastructure matches the configuration.`**

- [ ] **Step 8: (only if a drift fix was needed) Commit**

```bash
git add vps_gcp/tofu
git commit -m "fix(vps_gcp): align <resource> to converge on No changes"
```

---

### Task 8: `vps_oracle/tofu/` scaffold (brownfield, laying down the skeleton first)

**Files:**
- Create: `vps_oracle/tofu/README.md`
- Create: `vps_oracle/tofu/versions.tf`
- Create: `vps_oracle/tofu/provider.tf`
- Create: `vps_oracle/tofu/variables.tf`
- Create: `vps_oracle/tofu/.auto.tfvars.example`
- Modify: `vps_oracle/README.md` (add a `tofu/` row to the "directory structure" table)
- Modify: `README.md` ("conventions" section, "two other rule files" → "three other rule files")

**Interfaces:**
- Produces: `var.region`, `var.tenancy_ocid`, `var.compartment_id` and five OCID variables (filled into `.auto.tfvars` after Task 9's probing). The provider uses Instance Principal. Task 10's `import {}` blocks and resource blocks reference these variables.

- [ ] **Step 1: `vps_oracle/tofu/README.md`**

```markdown
# vps_oracle/tofu — brownfield root module

The half that practices brownfield: `import`ing resources that already exist and have been hand-modified in the console, taming drift, `ignore_changes`. This machine can never be rebuilt — it only exists to practice this half.

## Red lines

> **`tofu destroy` is forbidden in this directory.**

The IAM hard wall already makes `destroy` unable to reach the compute instance and boot volume (the policy grants only `manage virtual-network-family`), but the red line still needs to be written down — defense in depth.

## Acceptance criteria

`tofu plan` outputs `No changes.`

This step takes longer than expected: the OCI API returns a pile of default fields the console never shows, and aligning them one by one — or deciding which ones belong in `ignore_changes` — is the actual homework of this section.

## Directory layout

| File | Responsibility |
|---|---|
| `versions.tf` | required_version / required_providers (pinned versions) |
| `provider.tf` | `auth = "InstancePrincipal"` |
| `variables.tf` | region / tenancy_ocid / compartment_id + five resource OCIDs |
| `network.tf` | VCN / subnet / IGW / route table / security list |
| `imports.tf` | `import {}` blocks (the `id`s reference variables; the actual OCIDs live in `.auto.tfvars`) |

OCIDs are filled into the gitignored `.auto.tfvars` (see `.auto.tfvars.example`), never committed.

If the probe finds this machine uses the **default** route table/security list (display name "Default Route Table/Security List for <vcn>"), the resource type must be `oci_core_default_route_table` / `oci_core_default_security_list` (see the branch note in Task 10).
```

- [ ] **Step 2: `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.12.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "9.0.0"
    }
  }
}
```

- [ ] **Step 3: `provider.tf`**

```hcl
# InstancePrincipal — this very instance is the identity. Zero long-lived
# credentials on disk, auto-rotated by OCI. Requires a Dynamic Group matching
# this instance's OCID + a policy granting `manage virtual-network-family`
# ONLY (the IAM hard wall — see spec "The IAM wall"). The `region` comes from
# .auto.tfvars; the tenancy home region is discoverable in the console.
provider "oci" {
  auth   = "InstancePrincipal"
  region = var.region
}
```

- [ ] **Step 4: `variables.tf`**

```hcl
variable "region" {
  description = "Tenancy home region (e.g. ap-tokyo-1); console tenant page."
  type        = string
}

variable "tenancy_ocid" {
  description = "Tenancy OCID (console: Profile → Tenancy)."
  type        = string
}

variable "compartment_id" {
  description = "Compartment holding the resources; usually the root compartment = tenancy_ocid."
  type        = string
}

# Discovered OCIDs — filled during the probe (Task 9), stored gitignored.
variable "vcn_ocid"               { type = string }
variable "subnet_ocid"            { type = string }
variable "internet_gateway_ocid"  { type = string }
variable "route_table_ocid"       { type = string }
variable "security_list_ocid"     { type = string }
```

- [ ] **Step 5: `.auto.tfvars.example`**

```hcl
region                = ""
tenancy_ocid          = ""
compartment_id        = ""
vcn_ocid              = ""
subnet_ocid           = ""
internet_gateway_ocid = ""
route_table_ocid      = ""
security_list_ocid    = ""
```

- [ ] **Step 6: Update `vps_oracle/README.md`'s directory structure table** (add below the `host-firewall/` row)

```markdown
| `tofu/` | OpenTofu brownfield adoption: VCN / subnet / IGW / route table / security list (brings the upstream OCI network layer under management) | [tofu/README.md](tofu/README.md) |
```

- [ ] **Step 7: Update the root `README.md`'s rule-file pointer** (the section that currently says "two other rule files")

```markdown
Three other rule files: for k3s/ArgoCD change discipline see [`.claude/rules/k3s-gitops.md`](.claude/rules/k3s-gitops.md), for OpenTofu's adoption/free-tier/version red lines see [`.claude/rules/tofu-conventions.md`](.claude/rules/tofu-conventions.md), and for which layer documentation belongs in see [`.claude/rules/docs-layout.md`](.claude/rules/docs-layout.md).
```

- [ ] **Step 8: Static validation** (no resources, no imports yet, schema only)

Run:
```bash
cd vps_oracle/tofu && tofu fmt -recursive -check && tofu init -backend=false -input=false && tofu validate
```
Expected: `Success! The configuration is valid.`

> If tofu isn't installed locally, CI validation can be used instead (Task 2's job already covers this module). `validate` doesn't hit the OCI API and needs no credentials.

- [ ] **Step 9: Commit**

```bash
git add vps_oracle/tofu vps_oracle/README.md README.md
git commit -m "feat(vps_oracle): scaffold OpenTofu brownfield root module"
```

---

### Task 9: OCI probing — a factsheet aligned with what's live

**Files:**
- Create: `vps_oracle/tofu/probe.tf` (**one-shot, deleted after probing, never committed**)

**Interfaces:**
- Consumes: `var.region` / `var.compartment_id` (Task 8's variables, already filled into `.auto.tfvars`).
- Produces: a factsheet — five OCIDs (VCN/subnet/IGW/route table/security list), each resource's display name, and a determination of "does this machine use a default or self-managed route table/security list." This factsheet is Task 10's input.

> **PREREQ gate**: Prerequisites 1 (tofu installed), 2 (Dynamic Group + policy created).

- [ ] **Step 1: Confirm the InstancePrincipal can at least "see" the network resources**

Run:
```bash
cd vps_oracle/tofu
test -s .auto.tfvars && echo "tfvars ready"
```

- [ ] **Step 2: Write the one-shot `probe.tf`** (data-source read-only probing — `tofu apply` here only reads, never changes anything)

```hcl
# One-shot probe — delete this file after extracting the factsheet.
data "oci_identity_tenancy" "t" {
  tenancy_id = var.tenancy_ocid
}

data "oci_core_vcns" "all"   { compartment_id = var.compartment_id }
data "oci_core_subnets" "all" { compartment_id = var.compartment_id }
data "oci_core_internet_gateways" "all" { compartment_id = var.compartment_id }
data "oci_core_route_tables" "all" { compartment_id = var.compartment_id }
data "oci_core_security_lists" "all" { compartment_id = var.compartment_id }

output "factsheet" {
  value = {
    vcns     = data.oci_core_vcns.all.virtual_networks
    subnets  = data.oci_core_subnets.all.subnets
    igws     = data.oci_core_internet_gateways.all.gateways
    routes   = data.oci_core_route_tables.all.route_tables
    sec_lists = data.oci_core_security_lists.all.security_lists
  }
}
```

- [ ] **Step 3: Run the probe**

Run:
```bash
cd vps_oracle/tofu && tofu init && tofu apply -auto-approve && tofu output factsheet
```
Expected: output of the five resource types' `id`, `display_name`, `cidr_block(s)`, and the route table / security list's `route_rules`, `ingress_security_rules`.

- [ ] **Step 4: Determine the resource type** (the key decision)

In the factsheet, look at the route table's and security list's `display_name`:

- If it's **"Default Route Table for <vcn>"** → this machine's route table is the **default** one, so Task 10 uses `oci_core_default_route_table` with `manage_default_resource_id = <vcn_ocid>`.
- If it's **"Default Security List for <vcn>"** → use `oci_core_default_security_list`.
- Otherwise it's self-managed, use the plain `oci_core_route_table` / `oci_core_security_list`.

Record the determination and the five OCIDs in the factsheet (write them into Task 10's working notes or a local note, never into git).

- [ ] **Step 5: Delete `probe.tf`**

Run: `rm vps_oracle/tofu/probe.tf && cd vps_oracle/tofu && tofu apply -auto-approve` (the second apply removes the output, preparing a clean base for Task 10)

- [ ] **Step 6: (nothing to commit)** — `probe.tf` is a one-shot side effect, never version-controlled. No commit for this task.

---

### Task 10: OCI adoption — network.tf + imports.tf, converging to No changes

**Files:**
- Create: `vps_oracle/tofu/network.tf`
- Create: `vps_oracle/tofu/imports.tf`

**Interfaces:**
- Consumes: Task 9's factsheet (five OCIDs + resource-type determination); Task 8's OCID variables (`.auto.tfvars` already filled with the real probed values).
- Produces: five resources brought under management via `import`; the acceptance evidence of `tofu plan` = `No changes.`.

> **PREREQ gate**: Task 9 done; the five OCIDs are already filled into `.auto.tfvars`.

The essence of brownfield is "align to the values OCI actually holds." The `network.tf` below gives the **plain resource type + representative values**; every `<probed>` placeholder is replaced with the actual value from Task 9's factsheet, **never invented**. If Task 9 determined the default type, jump to "Step 5's branch" first.

- [ ] **Step 1: Write `imports.tf`** (the `id`s reference variables; OCIDs stay in gitignored tfvars, only the structure goes into git)

```hcl
# Declarative import — the `id`s come from .auto.tfvars (gitignored), so no
# OCID literal enters git. Converge to `No changes.` before considering this
# "done": the resource bodies in network.tf must match what OCI actually holds.
import {
  to = oci_core_vcn.main
  id = var.vcn_ocid
}
import {
  to = oci_core_subnet.public
  id = var.subnet_ocid
}
import {
  to = oci_core_internet_gateway.igw
  id = var.internet_gateway_ocid
}
import {
  to = oci_core_route_table.rt
  id = var.route_table_ocid
}
import {
  to = oci_core_security_list.sl
  id = var.security_list_ocid
}
```

- [ ] **Step 2: Write `network.tf`'s resource skeleton (the plain-type path)**

```hcl
resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_id
  cidr_blocks    = ["<probed>"]   # e.g. ["10.0.0.0/16"]
  display_name   = "<probed>"
}

resource "oci_core_subnet" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  cidr_block     = "<probed>"
  display_name   = "<probed>"
  route_table_id = oci_core_route_table.rt.id
  security_list_ids = [oci_core_security_list.sl.id]
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "<probed>"
}

resource "oci_core_route_table" "rt" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "<probed>"
  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_security_list" "sl" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "<probed>"
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
  # ingress rules copied VERBATIM from the fact sheet (22/80/443 for this host),
  # not invented here.
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options { min = 22; max = 22 }
  }
  # ...fill in the rest of the ingress rules exactly as they appear in the factsheet
}
```

- [ ] **Step 3: Run the import + converge loop** (the core homework of this task, will take longer than expected)

Loop the following until it reaches `No changes.`:
```bash
cd vps_oracle/tofu
tofu init
tofu plan     # first run: lists the import (create) plus field diffs
tofu apply    # completes the import + writes to state
tofu plan     # every run after this is a pure drift comparison
```
For every diff `tofu plan` reports, judge it field by field:
- OCI actually holds this value but we haven't written it → add it to the matching field in `network.tf`;
- it's a default field tofu can't predict or has no intention of managing → add it to `ignore_changes`.

- [ ] **Step 4: The right way to use `ignore_changes`** (append it inside the matching resource, and write the reason into `vps_oracle/tofu/README.md`)

```hcl
resource "oci_core_vcn" "main" {
  # ...
  lifecycle {
    ignore_changes = [
      # <field>: OCI returns/updates this outside Terraform's view; accepting
      # it quiets the diff without claiming to manage it. Reason recorded in
      # the README (spec: "ignore_changes on specific fields, with the reason recorded in the README").
    ]
  }
}
```

- [ ] **Step 5: Branch — if Task 9 determined the default type**

Replace `oci_core_route_table.rt` in `network.tf` with:

```hcl
resource "oci_core_default_route_table" "rt" {
  manage_default_resource_id = var.vcn_ocid
  # align the remaining route attributes to the factsheet (the default RT is auto-created with the VCN)
}
```

Similarly replace `oci_core_security_list.sl` with `oci_core_default_security_list` (`manage_default_resource_id = var.vcn_ocid`). The subnet's `route_table_id` / `security_list_ids` still point at these same two resources, same semantics. Also update `imports.tf`'s `to =` to the default type. **The converge loop (Step 3) is unchanged.**

- [ ] **Step 6: Acceptance**

Run: `cd vps_oracle/tofu && tofu plan`
Expected: **`No changes. Your infrastructure matches the configuration.`**

- [ ] **Step 7: Commit**

```bash
git add vps_oracle/tofu/network.tf vps_oracle/tofu/imports.tf vps_oracle/tofu/.terraform.lock.hcl vps_oracle/tofu/README.md
git commit -m "feat(vps_oracle): import OCI network resources into tofu"
```

---

### Task 11: OCI IAM hard-wall negative verification (read-only) + cleanup

**Files:**
- Create: `vps_oracle/tofu/wall-check.tf` (**one-shot, deleted after verification, never committed**)

**Interfaces:**
- Consumes: Task 10's module; `var.compartment_id`.
- Produces: a piece of safe **negative-verification** evidence — that tofu's identity can't even "see" this machine's own compute instance (404), let alone delete it. Removed right after, leaving no trace in git.

> **PREREQ gate**: Task 10 is done.

- [ ] **Step 1: Write the one-shot `wall-check.tf`**

```hcl
# Negative proof of the IAM hard wall: a `data` source pointing at the live
# instance. The policy grants only `manage virtual-network-family`, so OCI
# returns 404/403 for compute resources — tofu cannot even SEE the instance,
# let alone destroy it. Purely read-only. Delete after verifying.
data "oci_core_instance" "self" {
  instance_id = var.instance_ocid # the OCID of THIS very machine
}
```

Note: `var.instance_ocid` must first be added to `variables.tf`, with the machine's own OCID filled into `.auto.tfvars` (obtain it from the console or `curl http://169.254.169.254/opc/v2/instance/id`). This variable **exists only for the lifetime of this task** and is removed along with `wall-check.tf` right after verification.

- [ ] **Step 2: Run plan, expecting it to "fail due to insufficient permission"**

Run: `cd vps_oracle/tofu && tofu plan`
Expected: **failure** — OCI returns 404/403 for an unauthorized compute resource (the provider error contains `NotAuthorizedOrNotFound` or `404`). **This is the signal of success, not a bug.**

- [ ] **Step 3: Remove the one-shot file and variable**

Run:
```bash
cd vps_oracle/tofu
git checkout -- variables.tf 2>/dev/null || true   # if not git-tracked yet, delete the instance_ocid variable by hand
rm wall-check.tf
# remove the instance_ocid line from .auto.tfvars
```
Then run `tofu plan` again to confirm it's back to `No changes.` (Task 10's final state).

- [ ] **Step 4: Confirm the working tree is clean**

Run: `git status --short vps_oracle/tofu/` (expect nothing left over: `wall-check.tf` deleted, `variables.tf` has no `instance_ocid`, no `probe.tf`)

- [ ] **Step 5: (nothing to commit)** — the negative verification is a one-shot fact, never version-controlled.

---

## Final self-check (before merging)

- [ ] `git status` is clean, with no `.tfstate`, no `.auto.tfvars` (with real values), no leftover `probe.tf` / `wall-check.tf`.
- [ ] `.terraform.lock.hcl` is committed (one per module).
- [ ] The CI `tofu` job passes on a clean checkout (`fmt -check` + `init` + `validate`).
- [ ] `vps_oracle/tofu/`'s red line (no `destroy`) is written into both `tofu-conventions.md` and `vps_oracle/tofu/README.md`.
- [ ] Phase 3, which the spec never promised (a shared-resource-pool module, the redis ACL provider), has **not** slipped into this plan by mistake.

## Not included in this plan (explicit YAGNI / future practice per the spec)

| Not doing | Left for |
|---|---|
| Remote state backend | Future practice (the migration itself is a lesson) |
| GCP impersonation (ADC + SA impersonation replacing a key) | Future practice (get the key working first in this phase) |
| Per-service shared-resource-pool module (minio/postgres) | Phase 3, not promised |
| redis ACL automation | No provider exists, keep using `gen-users-acl.sh` |
| NPM / ClouDNS / docker / k8s adoption | Already has an owner — stacking this on top would mean two owners for one resource |
| OCI compute instance / boot volume | The IAM hard wall + too large a blast radius |
