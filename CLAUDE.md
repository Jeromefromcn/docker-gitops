# docker-gitops

Central repo for server docker-compose files. Each `<host>/<compose>/` directory here is the actual working directory for a compose stack — no separate deploy path, no symlink. A compose stack may define more than one service.

## Rules
- Follow the conventions in `README.md` when writing or editing any compose file — timezone, logging limits, port exposure, restart policy, network isolation, etc.
- Never commit secrets. Use `.env` (gitignored), never inline values.
- Pin image tags/digests. No `latest`.
- One change per commit, scoped to one compose stack.
- After editing a file here, apply it: `cd <host>/<compose> && docker compose up -d`.
- Volume paths in compose files must stay absolute — this directory can move, but bind mounts must still resolve.
- Don't assume a service here matches what's live — confirm with the user before applying changes that recreate a container.
- Need to configure/edit an NPM reverse proxy host? Follow the steps in README.md's "给服务接入 NPM 反代" section (includes a known SSL-toggle-resets-itself gotcha).
- Every time a new service is added to this repo, also add it as a card in the homepage dashboard — follow README.md's "给新服务加 homepage 卡片" section.
