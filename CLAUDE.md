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

## Skills — invoke these instead of improvising

| Task | Skill |
|---|---|
| Add a new service end to end (stack → shared-resource pools → NPM → homepage card → commit) | `add-service` |
| Create or change an NPM reverse proxy record | `npm-proxy-host` |
| Write up a troubleshooting session into `docs/incidents/` | `write-incident` |
| Add or change an inspector check under `vps_oracle/host-native/inspector/` | `inspector-check` |

## Subagent

`ops-diagnostician` — read-only investigator for "what is actually wrong with X right now". Its toolset is physically restricted to non-mutating commands, so dispatch it freely for live-state questions. It never changes anything; it reports and proposes.

## Automated checks

- A `PostToolUse` hook (`.claude/hooks/validate-compose.sh`) runs `docker compose config -q` plus the conventions checker after any compose file edit.
- CI (`.github/workflows/repo-conventions.yml`) enforces the compose conventions and the inspector's check/test pairing. Run it locally with `python3 .github/scripts/check-compose-conventions.py`.

## Other pointers

- **Host-level config** (global CLAUDE.md, shell rc files, VS Code machine settings): lives under `<host>/dotfiles/` and is symlinked into place — read `vps_oracle/dotfiles/README.md` before adding a new one.
- **Troubleshooting**: search `docs/incidents/` first; a matching symptom may already have a root cause on record.
