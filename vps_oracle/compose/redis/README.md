# vps_oracle/compose/redis

A unified Redis instance for the user's own services. **Third-party services that bundle their own Redis (e.g. dify's `dify-redis`) keep their own separate instances and are not migrated here** — the same tradeoff as the unified Postgres (see `../postgres/README.md`).

## Isolation model: one shared instance + one ACL user per app

Isolation uses **Redis ACL users + key-prefix namespaces** rather than one instance per app:

- One ACL user per app, of the form `user notes on ><password> ~notes:* +@all`
- `~<prefix>:*` limits the user to **only** the keys under the `<prefix>:` prefix
- App A's process **cannot** read/write App B's keys **at the permission level** — this isn't "just don't use each other's prefix" by convention, it's enforced by Redis
- One instance, one data directory, one admin UI — minimal resource overhead
- If an app needs full isolation (its own memory limit, needs `FLUSHALL`, etc.), give it its own instance

## Layout

```
redis/
├── docker-compose.yml        # redis + redisinsight, two services
├── .env.example              # template (copy to .env and fill in real values)
├── redis/
│   ├── redis.conf            # shared instance config (persistence / maxmemory)
│   └── users.acl             # [generated, gitignored] one ACL user per app
└── scripts/
    └── gen-users-acl.sh      # generates users.acl from .env
```

- `redis`: the unified instance. Pure backend on the `default` network — no published port, not on proxy. App containers join the `default` network and connect to `redis:6379`.
- `redisinsight`: admin UI (Redis's official GUI). On the `proxy` network via NPM; no built-in auth → behind the `self-only-and-auth` access list (Basic Auth). No host port published.

## First-deploy order

```bash
cd vps_oracle/compose/redis
cp .env.example .env          # fill in REDIS_PASSWORD / REDISINSIGHT_PASSWORD / each APP_*_PASSWORD
./scripts/gen-users-acl.sh    # generates redis/users.acl (with real passwords, gitignored)
docker compose up -d
```

> You must run `gen-users-acl.sh` before `up -d` — compose mounts `./redis/users.acl` read-only into the container, and redis fails to start if the file doesn't exist.

## How to add a new app

1. Add two blocks to `.env`:
   ```
   APP_<NAME>_PASSWORD=...
   APP_<NAME>_KEY_PREFIX=<prefix>   # suggest the app name, e.g. notes / todo
   ```
2. Re-run `./scripts/gen-users-acl.sh` to regenerate `users.acl`
3. `docker compose restart redis`
4. Join the app container to the redis stack's `default` network, connect to `redis:6379` with the `<name>` user + matching password, and give every key the `<prefix>:` prefix

## Admin UI

`https://redisinsight.jerome.cloudns.asia` (NPM reverse proxy, `self-only-and-auth` access list + Basic Auth). When connecting to redis use the matching app's ACL user: select **Add Redis Database** → Host: `redis`, Port: `6379`, Username: the app name, Password: the matching password.

## Operations

- Data: bind mount `/etc/redis/data` (AOF + RDB, see `redis.conf`)
- Backups: redis has no dedicated backup script; it relies on the instance data + the existing backup flow (to fold it in, see the backup pattern in `../postgres/scripts/`)
- Whichever user the app connects as, that app can only see/operate on the keys under that one `~<prefix>:`