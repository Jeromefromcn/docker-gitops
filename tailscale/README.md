# tailscale

Tailnet-wide access policy, managed by GitOps. Not host-scoped, so it lives at the repo root rather than under a `<host>/` directory.

[`policy.hujson`](policy.hujson) is the single source of truth. [`.github/workflows/tailscale-acl.yml`](../.github/workflows/tailscale-acl.yml) runs the official `tailscale/gitops-acl-action`:

| Event | Action |
|---|---|
| pull request touching the policy | `test` — validates syntax and runs the policy's `tests` block against the control server, changes nothing |
| push to `main` touching the policy | `apply` — replaces the live policy with this file |

**Don't edit the policy in the admin console.** The next `apply` from `main` overwrites the whole file, silently discarding console edits. Change `policy.hujson`, commit, push.

## Credentials

An OAuth client created under admin console **Settings → Trust credentials**, scoped to **Policy File: Write** only (it cannot manage devices or keys). Stored as GitHub repo secrets `TS_OAUTH_ID` / `TS_OAUTH_SECRET`; never on any host, never in git. `tailnet: '-'` means the credential's own tailnet.

## Trust model

| Tag | Hosts |
|---|---|
| `tag:oracle-hub` | vps_oracle |
| `tag:oracle2` | vps-oracle2 |
| `tag:gcp-lab` | vps-gcp |

`oracle-hub` may reach the other two on any port. `gcp-lab` may initiate nothing. `oracle2` may initiate only the k3s node ports toward `oracle-hub` (tcp 6443, udp 8472, tcp 4240, icmp) because it is an agent node of the k3s cluster whose server runs on vps_oracle — nothing else, and nothing toward `gcp-lab`. The `tests` block in the policy asserts exactly this, so CI fails if an edit widens it. Never add another host to `tag:oracle-hub` — it would inherit full reach.
