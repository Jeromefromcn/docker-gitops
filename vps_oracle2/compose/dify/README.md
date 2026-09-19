# dify

Runs on **vps_oracle2** (moved from vps_oracle on 2026-09-19). Deploy with the docker context, since the repo only lives on vps_oracle: `docker --context oracle2 compose up -d`. Bind mounts resolve on oracle2's daemon, so two things must exist there: `/etc/dify/*` (data) and a copy of `./ssrf_proxy/` at the same absolute path under `~/jerome/docker-gitops/vps_oracle2/compose/dify/` (`scp -rp` it after editing). `.env` is read locally and needs no sync.

## Hosting model (cross-host)

There is no shared docker `proxy` network between the two hosts. `dify-web` (3000), `dify-api` (5001) and `dify-plugin-daemon` (5002) publish ports bound to oracle2's tailscale IP `100.100.140.33` only, and NPM on vps_oracle forwards to that IP over the tailscale mesh. If oracle2 re-registers on tailscale (e.g. after a `tofu destroy`/`apply`), update the IP in this compose file and in NPM host 24 (all 8 locations). Egress from dify (model APIs, plugins, workflow HTTP nodes) now leaves from oracle2's public IP.

Self-hosted Dify 1.14.2 (community edition), trimmed down from the official `docker/docker-compose.yaml`.

## Differences from the official default deployment

- **Don't use the official bundled nginx** — the official nginx only does path-based forwarding (`/console/api`, `/api`, `/v1`, `/files`, `/mcp`, `/triggers`, `/openapi` → api; `/e/` → plugin_daemon; the rest → web), all under one domain. Here we use NPM's Custom Locations feature to copy these forwarding rules directly, without spinning up a separate nginx container. See "Wiring the service into an NPM reverse proxy" below.
- **Don't deploy the sandbox** (the code-execution sandbox) — the Code node in Workflow becomes unavailable; the rest of the functionality is unaffected. Add this container separately later if it's needed.
- **Don't use certbot** — certificates all go through NPM.
- **Use pgvector for the vector store**, not the official default weaviate — note that pgvector is a separate Postgres container in the official compose (the `pgvector` service), not a reuse of `db_postgres`, Dify's own metadata database instance.
- **Don't use the latest 1.16.x** — 1.16.0 added a whole "Dify Agent" subsystem (`agent_backend`+`local_sandbox`+`agent_ssrf_proxy`+`api_websocket`) that we don't need, and it costs extra memory.
- **Pin 1.14.2, don't use 1.15.x** — 1.15.0 changed `web/hooks/use-timestamp.ts` to independently issue a `GET /console/api/account/profile` via `react-query` (1.14.x reads the already-loaded app context directly, producing no extra request). If this background request hits a transient 401 even once, `web/service/base.ts` unconditionally hard-redirects the whole page to `/signin` (no silent-request exemption — the corresponding fix, PR #38273, was proposed but never merged); after the redirect the page reload re-triggers the same hook, forming a redirect loop that keeps bouncing after login (upstream issue [#38457](https://github.com/langgenius/dify/issues/38457), same version, same symptom). Confirmed by directly diffing the 1.14.2/1.15.0 source: 1.14.2 has no such extra request, so the loop's trigger path doesn't exist. **If we later upgrade to a version that fixes this, remember to re-check this note and the URL section below together.**
- **Don't enable collaboration (`api_websocket`)** — the multi-user collaborative workflow-editing feature, which we have no need for.

## Architecture

| Container | Role |
|---|---|
| `dify-db` | Dify's own metadata Postgres |
| `dify-pgvector` | The vector store, a separate Postgres container |
| `dify-redis` | Cache / Celery broker |
| `dify-ssrf-proxy` | Squid; outbound requests from workflow HTTP request nodes and plugins go through here for SSRF protection — unrelated to the sandbox, this is a core component |
| `dify-plugin-daemon` | Plugin runtime, **required** — from 1.x on, even model providers like OpenAI/Anthropic are implemented as plugins |
| `dify-api` | Backend API |
| `dify-worker` | Celery worker (runs dataset indexing, async workflow tasks, etc.) |
| `dify-worker-beat` | Celery scheduler |
| `dify-web` | Frontend |

There's no one-shot init container: the permissions on `/app/api/storage` (api/worker run as uid 1001) were handled directly on the host with `sudo chown -R 1001:1001 /etc/dify/storage` — permanent, no need to run a use-once-and-exit container on every start.

Only `dify-web`, `dify-api`, and `dify-plugin-daemon` publish host ports (tailscale IP only, see "Hosting model"); the rest of the containers stay on the internal networks and publish nothing.

## Wiring the service into an NPM reverse proxy

Configured via the NPM API on vps_oracle (proxy host id 24, certificate id 26). Unlike the general convention in the root README, this service needs **one proxy host + several Custom Locations**. The forward host is `100.100.140.33` (oracle2's tailscale IP), not a container name.

**Details tab**

| Field | Value |
|---|---|
| Domain Names | `dify.jerome.cloudns.asia` |
| Scheme | `http` |
| Forward Hostname / IP | `100.100.140.33` |
| Forward Port | `3000` |
| Cache Assets | Off |
| Block Common Exploits | On |
| Websockets Support | On |
| Access List | `self-only` |

**Custom Locations** (same proxy host, forward host `100.100.140.33`)

| Location | Forward Port |
|---|---|
| `/console/api`, `/api`, `/v1`, `/files`, `/mcp`, `/triggers`, `/openapi` | `5001` |
| `/e/` | `5002` |

The SSL tab follows the general config in the root README (Force SSL / HTTP/2 / fixed email value); remember to save and reopen to re-check that known gotcha.

Because the upstreams are literal IPs, nginx has no name to resolve at config load, so a stopped dify no longer breaks NPM's startup (see `vps_oracle/compose/npm/README.md`), and the old "reload nginx after the network is rebuilt" gotcha no longer applies. A stopped dify just returns 502 for this one site.

## Adding a homepage card for a new service

Already added to `vps_oracle/compose/homepage/config/services.yaml` (homepage stays on vps_oracle; the card links to the public URL) in the format from the root README.

**Gotcha hit**: `dify-web`'s `server.js` binds to `$HOSTNAME` (which Docker injects from the compose `hostname:` field), not `0.0.0.0`. Unfixed, it only listens on the `default` network IP, so the `proxy` network (i.e. NPM) can't connect — manifesting as a persistent 502 on the homepage, except for paths like `/console/api` that forward to `dify-api`. Already fixed in compose by explicitly setting `HOSTNAME: "0.0.0.0"` on the `web` service to override it.

## Internal vs external URL-style config

A note on the gotchas hit with the several `*_URL` variables in compose:

- **Internal (container-name:port, over the docker network)**: `DB_HOST`/`REDIS_HOST`/`PGVECTOR_HOST`, `SSRF_PROXY_HTTP(S)_URL`, `PLUGIN_DAEMON_URL`, `DIFY_INNER_API_URL`, `SERVER_CONSOLE_API_URL` (web's SSR stage connects directly to api via this; inside a container there's no "current request domain" to infer), `INTERNAL_FILES_URL` (used by api/worker; plugins read files via this rather than going around through the public domain). The precondition is that both sides share at least one docker network (all verified).
- **External (real public domain, for browsers/third parties)**: `CONSOLE_WEB_URL`/`CONSOLE_API_URL`/`SERVICE_API_URL`/`APP_WEB_URL`/`FILES_URL` (api, worker, and worker_beat all need it — registration/invite/password-reset emails are sent by worker's Celery tasks, and image/file download links are also composed into API response bodies for external clients, not consumed inside the container, so they must be addresses reachable from outside), `ENDPOINT_URL_TEMPLATE` (the callback URL for plugin Endpoint types, e.g. for Slack integration), `TRIGGER_URL` (the callback URL for plugin Triggers, corresponding to `/triggers` in NPM). These two were initially left unset; the official defaults are `http://localhost/...`, and if you actually installed a plugin needing a webhook callback, the generated URL would be unreachable from outside entirely — now filled in.
- **Third-party external (not our infrastructure)**: `MARKETPLACE_API_URL`/`MARKETPLACE_URL` (`https://marketplace.dify.ai`, Dify's official plugin marketplace, accessed directly by the browser, not through our containers).

`PLUGIN_REMOTE_INSTALL_HOST`/`PORT` (api) and `PLUGIN_REMOTE_INSTALLING_HOST`/`PORT` (plugin_daemon) are left at `localhost`/`0.0.0.0` unchanged — these two are for the "remote plugin debug install" feature, and since we don't publish the 5003 port to the host (least-exposure principle), that feature was never reachable in the first place; it's not a misconfiguration, it's just not enabled.

## First-time install

1. `docker compose up -d`
2. Wait for `dify-api` and `dify-web` to be healthy (`docker compose ps`)
4. After the NPM reverse proxy is configured, visit `https://dify.jerome.cloudns.asia/install` and set up the admin account using the `INIT_PASSWORD` value from `.env`

## Memory usage

vps_oracle2 has 2 cores / ~11GB. After deploying, it's worth running `docker --context oracle2 stats --no-stream` once to record a baseline.
