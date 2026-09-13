# postgres

A unified PostgreSQL instance + pgAdmin 4 web admin UI for the user's own future apps.

Each app gets its own database + its own role (the app connects as its own role and sees only its own database), with per-database `pg_dump` backups.

**Scope**: third-party services (dify's bundled `postgres:15` + `pgvector:pg16`, k3s lab-environment's `postgres:16`) are **not migrated here** — each stays as-is. This stack serves only the user's own apps.

## Architecture

| container_name | role | network | host port |
|---|---|---|---|
| `postgres` | unified PG instance (`postgres:17-alpine`), pure backend | `default` only | none (not exposed) |
| `pgadmin` | pgAdmin 4 web admin UI | `default` + `proxy` | none (NPM only) |

- `postgres` is attached only to the `default` network and publishes no port — pure backend, not on `proxy` (repo convention).
- `pgadmin` is attached to `default` (to reach postgres) + `proxy` (reverse-proxied via NPM); it publishes no host port — the admin panel is reached only via NPM.

## Reverse-proxy the service via NPM

Creating it via the NPM API is already done (2026-08-24); no manual configuration needed:

- **Proxy host id 34**: `pgadmin.jerome.cloudns.asia` → `pgadmin` :80 (http)
- **Certificate id 36**: Let's Encrypt (HTTP-01), expires 2026-11-22, email `jeromefromcn@gmail.com`
- **Access List**: `self-only` (allows 3x-ui + the public egress IP, deny everything else)
- ssl_forced / block_exploits / websocket / http2 all on, hsts off

To recreate or verify, use the NPM API (see the automation flow in `../npm/README.md`):
1. Certificate: `POST /api/nginx/certificates`, body only needs `{"domain_names":["pgadmin.jerome.cloudns.asia"],"provider":"letsencrypt"}` (**2.15.1 no longer accepts** `meta.letsencrypt_agree`/`dns_challenge` — it 400s)
2. proxy host: `POST /api/nginx/proxy-hosts`, `forward_host: pgadmin`, `forward_port: 80`, `access_list_id: 1`, `certificate_id: <certificate id>`

> ⚠️ **Known gotcha**: when manually editing this host in the panel, Force SSL / HTTP/2 Support may be silently reset to off after saving. Reopen the record to double-check after saving.

## Add a homepage card for a new service

This stack has no outward-facing "service homepage" (pgAdmin is an admin panel), but by repo convention admin panels also get a card. Add one under the `Infra Services` group in `vps_oracle/compose/homepage/config/services.yaml`:

```yaml
    - PostgreSQL Admin:
        icon: si-postgresql
        href: https://pgadmin.jerome.cloudns.asia
        description: PostgreSQL admin (unified instance)
```

## First install

```bash
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/postgres
cp .env.example .env        # fill in the real password/email
# make sure the proxy network exists (repo README has the docker network create ...)
docker compose up -d
```

Verify:

```bash
docker compose ps                       # postgres healthy, pgadmin running
docker exec postgres pg_isready         # ready
docker exec postgres psql -U postgres -c '\l'   # should list app_notes / app_todo
```

## How to add a new app (copy-paste)

Each self-hosted app = one role + one database. Add one line to `init/init-databases.sh`:

```bash
create_role_and_db "app_name"
```

**Note**: `/docker-entrypoint-initdb.d/` only runs on **first init (empty data directory)**. For an already-running instance, apply it manually like this:

```bash
# create the role + db in the container (same logic as the script, idempotent / re-runnable)
docker exec -i postgres psql -U postgres -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='app_name') THEN
    CREATE ROLE app_name LOGIN PASSWORD 'change-me';
  END IF;
END $$;
SELECT 'CREATE DATABASE app_name OWNER app_name'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='app_name')\gexec
SQL
```

Then append `create_role_and_db "app_name"` to `init/init-databases.sh` so a future data-directory rebuild stays idempotent.

App connection string: `postgres://app_name:<password>@postgres:5432/app_name` (`postgres` is the container name, over the compose `default` network).

## Backups

Logical backups. The `scripts/backup-databases.sh` script is scheduled via cron on the **host** (same pattern as `monitoring/scripts/check-sync.sh`; the cron entry lives only on the host, not committed):

```cron
30 2 * * * /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/postgres/scripts/backup-databases.sh
```

Each run produces two parts, both keeping the most recent 14 copies:

- **Cluster-level objects**: `/etc/postgres/backups/global-objects/global-objects-YYYYMMDD.sql` (`pg_dumpall -g` — roles, privileges, tablespaces, etc.)
- **Per database**: `/etc/postgres/backups/<db>/<db>-YYYYMMDD.sql` (`pg_dump` — schema + data)

**Why the global dump is included**: `pg_dump` is single-database only and does not include roles or other cluster-level objects. Bringing `pg_dumpall -g` into the backup makes it self-contained — a rebuilt instance can be restored with the **exact same set of roles**, without depending on whether `init/init-databases.sh` was kept in sync (new roles don't necessarily go through the init script; they may be created directly in pgAdmin).

**Restore** (after rebuilding the instance):

```bash
# 1. first restore cluster-level objects (roles/privileges), then each database
docker exec -i postgres psql -U postgres -d postgres < /etc/postgres/backups/global-objects/global-objects-YYYYMMDD.sql
docker exec -i postgres psql -U postgres -d app_notes < /etc/postgres/backups/app_notes/app_notes-YYYYMMDD.sql
# 2. if a database doesn't exist, create it first (see "How to add a new app" above)
```

> Note: `pg_dumpall -g` exports **password hashes** (SCRAM), which restore usable login passwords but not plaintext. Plaintext passwords are kept separately in `.env` (gitignored) for authorizing new apps.

- Backups of third-party PG instances (dify / love-bird-boss / lab-env) are **out of scope for this stack** and handled separately

## Gotchas

- **initdb runs only once**: `init/init-databases.sh` runs only on first init; afterwards, adding an app needs a manual re-run (see above), plus add the line back into the script to keep it declarative.
- **pgAdmin only manages this stack**: `pgadmin` is attached only to the `default` network, so it can't reach other PG instances on the host (each sits on its own compose network or exposes a host port). This is intentional — third-party services stay unmigrated, and pgAdmin's attack surface isn't widened.
- **Access control**: the NPM Access List is set to `self-only`; the admin panel must not be open to the public internet.
- **Version**: this stack runs `postgres:17-alpine` (pinned digest). It differs from the existing third-party PG versions (15/16) and doesn't interfere with them.