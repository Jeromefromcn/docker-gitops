# docker-gitops

Central GitOps repo for this VPS's infrastructure — not limited to docker-compose. Each `<host>/compose/<compose>/` directory here is the actual working directory for a compose stack — no separate deploy path, no symlink. A compose stack may define more than one service. A `<host>/` also holds non-compose subdirectories for infra managed outside docker compose (e.g. `k3s/`, `host-firewall/`, `inspector/`, `dotfiles/`) — each follows its own convention, documented in its own README.

## Rules
- Follow the conventions in `README.md` when writing or editing any compose file — timezone, logging limits, port exposure, restart policy, network isolation, etc.
- Never commit secrets. Use `.env` (gitignored), never inline values.
- Pin image tags/digests. No `latest`.
- One change per commit, scoped to one compose stack.
- After editing a file here, apply it: `cd <host>/compose/<compose> && docker compose up -d`.
- k3s/ArgoCD resources: git first, always. Never `kubectl apply`/`patch`/`edit` a live resource to test something before it's committed — `selfHeal` will silently revert it. Commit, push, let ArgoCD sync, verify after. Read-only diagnostics are always fine; for genuine live trial-and-error, disable that Application's `selfHeal` first and re-enable it once the final version is back in git.
- Any absolute path baked in elsewhere that points into this repo (compose bind mounts, `<host>/dotfiles/` symlinks) must keep resolving even if this directory moves. `vps_oracle/dotfiles/link.sh` regenerates the dotfile symlinks; bind mounts have no such fallback, so they just have to stay put.
- Don't assume a service here matches what's live — confirm with the user before applying changes that recreate a container.
- Need to configure/edit an NPM reverse proxy host? Follow the steps in README.md's "给服务接入 NPM 反代" section (includes a known SSL-toggle-resets-itself gotcha).
- Every time a new service is added to this repo, also add it as a card in the homepage dashboard — follow README.md's "给新服务加 homepage 卡片" section.
- Host dotfiles/config (global CLAUDE.md, shell rc files, VS Code machine settings, etc.) live under `<host>/dotfiles/` and are symlinked into place — see `vps_oracle/dotfiles/README.md` before adding a new one.
- Diagrams in any markdown file: use Mermaid, not ASCII art.
