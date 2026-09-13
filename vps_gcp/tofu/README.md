# vps_gcp/tofu — greenfield root module

Practices the greenfield half: full lifecycle, from a clean apply → change → destroy → apply again to verify reproducibility.

## Free-tier boundaries (locked, don't touch)

| Item | Value | Why |
|---|---|---|
| region / zone | `us-central1` / `us-central1-a` | e2-micro is free only in us-west1/us-central1/us-east1; matches the free-tier region the prior live instance was in |
| machine_type | `e2-micro` | Hardcoded literal, not a variable, to prevent an accidental slip to e2-medium |
| boot disk | 30 GB `pd-standard` | The free tier's total allowance is 30 GB of standard persistent disk |
| egress | 1 GB/month (excludes China/Australia) | See the comment in instance.tf |

## Authentication

A dedicated service account + key JSON. Roles narrowed to `roles/compute.networkAdmin`, `roles/compute.instanceAdmin.v1`, `roles/serviceusage.serviceUsageAdmin`.

- The key lives outside the repo, referenced via an environment variable: `export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json`
- `.auto.tfvars` (gitignored) holds the three required values `project_id`, `project_number`, and `billing_account` — see `.auto.tfvars.example`. `project_number` is the purely-numeric project number, a different identifier from the alphanumeric `project_id` — the budget's `budget_filter.projects` only accepts `projects/{project_number}`.

`google_billing_budget`'s permissions attach to the **billing account**, not the project — grant `roles/billing.costsManager` at the billing-account level.

## SSH login (two layers, considered separately)

**The key persists** — you may optionally set `ssh_public_key` (a public key, not a secret). GCP's `ssh-keys` metadata is installed into `ubuntu`'s `authorized_keys` by the guest-agent, and is attached to the instance resource, so **it gets reinstalled automatically after a destroy→apply rebuild**.

- Value format: `ssh-ed25519 AAAA... comment`. Injected via `TF_VAR_ssh_public_key="$(cat ~/.ssh/id_gcp.pub)"` (`.auto.tfvars` holds only identity-type values, never the key itself).
- Left blank (default) = falls back to Console browser SSH.

**The IP does not persist** — the current `nat_ip` is ephemeral (see instance.tf), so the external IP changes on every rebuild. Adding a `google_compute_address` for this practice machine isn't recommended (a reserved IP is billed during the destroy→apply gap while unattached, which would violate the free-tier red line). Approach: read the new IP after apply:

```bash
# With gcloud: query live
gcloud compute instances describe vps-gcp --zone us-central1-a \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)'

# Without gcloud: read state directly (runs locally, no GCP auth needed)
tofu state show google_compute_instance.vps | grep '"nat_ip"'
```

After each rebuild, just write the new IP into the `Host vps-gcp` entry's `HostName` field in `~/.ssh/config`. No need for an "auto-discovery" background daemon — a rebuild is a low-frequency, manually-triggered event; a single grep handles it.

## Acceptance criteria

After `tofu destroy`, `tofu apply` can fully reproduce the setup, and `tofu plan` outputs `No changes.` afterward.

## Operation

```bash
cd vps_gcp/tofu
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json
cp .auto.tfvars.example .auto.tfvars   # fill in project_id / project_number / billing_account
tofu init
tofu plan    # acceptance: final state is No changes.
tofu apply
```
