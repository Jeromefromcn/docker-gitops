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

`oracle-hub` may reach the other two on any port; neither may initiate anything back. Never add another host to `tag:oracle-hub` — it would inherit that reach.
