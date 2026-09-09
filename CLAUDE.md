# docker-gitops

Central GitOps repo for this VPS's infrastructure — not limited to docker-compose. Each `<host>/compose/<compose>/` directory here is the actual working directory for a compose stack — no separate deploy path, no symlink. A compose stack may define more than one service. A `<host>/` also holds non-compose subdirectories for infra managed outside docker compose (e.g. `k3s/`, `host-firewall/`, `inspector/`, `dotfiles/`) — each follows its own convention, documented in its own README.

## Rules

Path-scoped rules in `.claude/rules/` load automatically when files in their scope are read — you do not need to go find them:

| Scope | Rule file |
|---|---|
| `*/compose/**` | `compose-conventions.md` — timezone, logging, port exposure, least privilege, restart policy, network isolation and the static-IP registry |
| `*/k3s/**` | `k3s-gitops.md` — git-first discipline, selfHeal, PSS baseline constraints, SealedSecrets |
| always loaded | `docs-layout.md` — which layer a piece of documentation belongs in |

## Always

- **Never commit secrets.** Use `.env` (gitignored), never inline values.
- **Don't assume a service here matches what's live** — confirm with the user before applying changes that recreate a container.
- One change per commit, scoped to a single stack or component.
- Any absolute path baked in elsewhere that points into this repo (compose bind mounts, `<host>/dotfiles/` symlinks) must keep resolving even if this directory moves. `vps_oracle/dotfiles/link.sh` regenerates the dotfile symlinks; bind mounts have no such fallback, so they just have to stay put.

## Entry points for common tasks

- **Put a service behind NPM**: follow README.md's "给服务接入 NPM 反代" section (there's a script, `vps_oracle/compose/npm/add-proxy-host.sh`, plus known gotchas — the SSL toggle resets itself, and Custom Locations can take down every site at once).
- **Add a new service**: README.md's "新增一个服务" + "给服务接入 NPM 反代" + "给新服务加 homepage 卡片" — all three, none optional.
- **Host-level config** (global CLAUDE.md, shell rc files, VS Code machine settings): lives under `<host>/dotfiles/` and is symlinked into place — read `vps_oracle/dotfiles/README.md` before adding a new one.
- **Troubleshooting**: search `docs/incidents/` first; a matching symptom may already have a root cause on record.
