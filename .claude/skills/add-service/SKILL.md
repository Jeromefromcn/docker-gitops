---
name: add-service
description: The full flow for adding a new service to this GitOps repo — create a compose stack, provision prod+dev isolated pools for shared resources (minio/postgres/redis) as needed, wire up an NPM reverse proxy, add a homepage card, and commit. Use when the user wants to "add a new service", "deploy a new app", or "create a new compose stack".
---

# Add a new service

Execute step by step, **don't skip any step** — missing the homepage card or the NPM record is the most common omission.

## 1. Create the compose stack

Create `<compose>/docker-compose.yml` under the appropriate `<host>/compose/`. Before writing, read [`.claude/rules/compose-conventions.md`](../../rules/compose-conventions.md) (auto-loaded when editing files under that path) — timezone, log size limits, minimal port exposure, `restart: unless-stopped`, the `proxy` network, and least privilege are all hard constraints that CI checks.

Services that don't need external exposure should **not** be attached to the `proxy` network; even those that do should **not** publish host ports — they all go through NPM reverse-proxied to the container's internal port.

## 2. Shared resources: prod / dev isolated pools

If this service uses the shared minio / postgres / redis, **provision two mutually isolated sets of resources**, with the dev set suffixed `_dev`:

| Shared resource | prod | dev |
|---|---|---|
| minio | `<name>` bucket | `<name>_dev` bucket |
| postgres | `<name>` database | `<name>_dev` database |
| redis | `<name>` ACL user | `<name>_dev` ACL user |

- postgres database creation goes through [`vps_oracle/compose/postgres/init/init-databases.sh`](../../../vps_oracle/compose/postgres/init/init-databases.sh).
- redis ACL users are generated from `.env` by [`vps_oracle/compose/redis/scripts/gen-users-acl.sh`](../../../vps_oracle/compose/redis/scripts/gen-users-acl.sh); the generated `redis/users.acl` contains plaintext passwords and is gitignored — don't commit it.
- The existing notes / todo are **not retrofitted** — leave them as-is.

## 3. Start it

```bash
cd <host>/compose/<compose> && docker compose up -d
```

The repo directory is the runtime directory — there is no separate deploy path.

## 4. Wire up the NPM reverse proxy

Use the `npm-proxy-host` skill. Domain `<service>.jerome.cloudns.asia`; if this service also needs a dev environment, dev uses `<service>.dev.jerome.cloudns.asia`.

## 5. Add a homepage card

homepage moved back from k3s to compose on 2026-08-18 (see the "k3s" section of the root [README.md](../../../README.md)), and its config source file is **`vps_oracle/compose/homepage/config/services.yaml`**. For each new service, add a card under the appropriate category (`Infra Services` / `Apps`), keeping the same format as existing entries:

```yaml
    - <service name>:
        icon: <icon-name>.png
        href: https://<service>.jerome.cloudns.asia
        description: <one-line description, in English>
```

- `icon`: prefer the matching filename from [walkxcode/dashboard-icons](https://github.com/walkxcode/dashboard-icons) (homepage pulls from the CDN automatically); where there's no dedicated icon, fall back to `si-<name>` (simple-icons), e.g. `si-anthropic`
- `description`: visitor-visible, so write it in English per the "user-facing content in English" convention below
- No `container`/`server` field — after moving back to compose this field could have been restored (mounting the docker socket), but on 2026-08-18 we decided to keep it off, staying consistent with the pre-migration k3s state and only providing the card itself
- **Exception**: security-sensitive services (e.g. 3x-ui) don't get a card — ask before adding one

After editing, `cd vps_oracle/compose/homepage && docker compose up -d` takes effect directly — no push/ArgoCD needed.
## 6. Commit

```bash
git add <host>/compose/<compose> vps_oracle/compose/homepage/config/services.yaml
git commit
```

One commit per change. Commit messages in English (Conventional Commits).

## Final self-check

- [ ] compose has `logging` / `TZ` / `restart: unless-stopped` / a pinned image tag or digest
- [ ] No unnecessary host-port publications
- [ ] Secrets are in `.env`, not in compose
- [ ] NPM record created, and **re-checked afterwards** that Force SSL / HTTP/2 weren't silently reset
- [ ] homepage card added (except security-sensitive services — ask first)
- [ ] `python3 .github/scripts/check-compose-conventions.py` passes