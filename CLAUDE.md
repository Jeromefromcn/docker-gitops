# docker-gitops

Central repo for server docker-compose files. Each `<host>/<service>/` directory here is the actual working directory used to run that service — no separate deploy path, no symlink.

## Rules
- Never commit secrets. Use `.env` (gitignored), never inline values.
- Pin image tags/digests. No `latest`.
- One change per commit, scoped to one service.
- After editing a file here, apply it: `cd <host>/<service> && docker compose up -d`.
- Volume paths in compose files must stay absolute — this directory can move, but bind mounts must still resolve.
- Don't assume a service here matches what's live — confirm with the user before applying changes that recreate a container.
