# vps_oracle/compose/npm

## Security architecture: using access lists to lock NPM-reverse-proxied services into the "internal network"

Most of the services behind NPM (grafana, homepage, dify, trilium, vikunja, apprise, portainer, and NPM's own admin panel) are **not open to the public**, but are deliberately locked down via NPM's Access List to sources that are "the server itself" or "IPs within the `proxy` docker network" — ordinary public visitors just get a 403 when they connect.

**3x-ui is the only exception**, deliberately not restricted by an access list, because it's the key for getting in: 3x-ui's own xray config (`dns.hosts` in `/app/bin/config.json`) has an override rule `"domain:jerome.cloudns.asia": "172.19.0.3"` — whenever any `*.jerome.cloudns.asia` domain is accessed through the 3x-ui proxy, xray **doesn't do a public DNS resolution**, but instead directly sends the traffic to `172.19.0.3` (that is, npm) inside the `proxy` docker network. Because this path never leaves the host machine and isn't rewritten by Docker's SNAT, the source nginx sees is **3x-ui's own real container IP** — which is exactly why the access list allows `172.19.0.2`. This is a "connect through the proxy first, then you can reach the internal services" model that disguises a public-machine host as a private intranet you can only enter through that proxy.

**Both of these IPs must be pinned to static values — miss either and it breaks**:

- `3x-ui` is fixed at `172.19.0.2` (matching the source allowed by the access list)
- `npm` is fixed at `172.19.0.3` (matching the target that the xray DNS override points to)

Both are written into `networks.proxy.ipv4_address` in their respective `docker-compose.yml`; otherwise Docker's dynamic allocation could swap the IP when the container is rebuilt. If either of these two services drifts, proxied traffic would be sent to the wrong place or blocked by the access list (this happened once on 2026-08-06: npm was temporarily pinned alone at `172.19.0.2`, which didn't match the `172.19.0.3` in the xray override rule, so no service could be reached through the proxy — it took a long while before discovering these two IPs had been swapped).

## Current Access Lists

| Access List | Allow rules | Extra requirement |
|---|---|---|
| `self-only` (id 1) | `172.19.0.2/32` (3x-ui's IP on the `proxy` network), `161.118.254.107` (the server's current public IP) | None |
| `self-only-and-auth` (id 2) | Same two as above | Also requires Basic Auth (account `jerome`) |

`self-only-and-auth` is for **admin panels without built-in auth** (e.g. `npm`'s own admin panel, `grafana`, `portainer`, `cc-window`, `redisinsight`, `jaeger`). Rule: **any service without built-in auth must always use `self-only-and-auth`, not `self-only`** (`self-only` only blocks the "source", not the "who" — any user/process on the same machine can still access it). The number of proxy hosts on each list changes as services are added/removed — check live via the NPM API (`GET /api/nginx/proxy-hosts`) rather than trusting a number written here.

`161.118.254.107` is the server's current public egress IP (findable via `curl https://ifconfig.me`), **not permanently fixed** — if Oracle ever changes this machine's public IP, both access lists must be updated, otherwise traffic coming straight in from the public internet without going through 3x-ui (e.g. blackbox_exporter's own probes) would be blocked.

## How to change the Access List

**UI**: log in to `npm.jerome.cloudns.asia` (you first have to pass the access list, or go in directly via the server itself / an SSH tunnel) → Access Lists → pick `self-only` or `self-only-and-auth` → edit Clients.

**API** (run on the server itself, no need to pass the access list first; goes over the internal `proxy` network straight to npm's admin port):

```bash
source vps_oracle/compose/npm/.npm-automation.env
docker run --rm --network proxy curlimages/curl:latest sh -c "
TOKEN=\$(curl -sS -X POST http://npm:81/api/tokens -H 'Content-Type: application/json' -d '{\"identity\":\"$NPM_AUTOMATION_EMAIL\",\"secret\":\"$NPM_AUTOMATION_PASSWORD\"}' | sed -n 's/.*\"token\":\"\([^\"]*\)\".*/\1/p')
curl -sS 'http://npm:81/api/nginx/access-lists?expand=items,clients' -H \"Authorization: Bearer \$TOKEN\"
"
```

After looking up the access list `id`, use `PUT /api/nginx/access-lists/{id}` with the complete `clients` array (keeping the old rules + adding the new rules) to update.

**After changing an access list, always run `docker exec npm nginx -t` once**: updating an access list also regenerates the config of all the proxy hosts under it, which could re-introduce the dify problem below.

## Creating a Let's Encrypt certificate via the API (2.15.1 schema, hit on 2026-08-24)

You need a certificate before creating a proxy host via the API. NPM 2.15.1's `POST /api/nginx/certificates` **does not accept** the top-level `email` field written in the old docs (the SSL tab in the repo root README), nor `meta.letsencrypt_agree` / `meta.letsencrypt_email` — those are old-schema fields, and the new schema returns `400 data/meta must NOT have additional properties`.

**Working body** (`meta` only needs `dns_challenge`; `letsencrypt_email`/`agree` get their defaults filled in automatically by the new version):

```bash
curl -sS -X POST 'http://npm:81/api/nginx/certificates' -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"provider":"letsencrypt","domain_names":["<domain>"],"meta":{"dns_challenge":false}}'
```

After getting the `certificate_id`, create the proxy host (`forward_host` is the container name, `forward_port` is the container's internal port, `access_list_id` is the corresponding list's id).

## Create a proxy host in one go with a script (`add-proxy-host.sh`)

The whole chain above — "mint token → look up access list id → create/reuse certificate → create proxy host → verify SSL settings weren't silently reset" — if broken into several **separately executed** commands (like Claude Code's Bash tool, where each command is an independent shell process and variables don't survive across commands, only the working directory does), the token minted in the first step no longer exists by the next step, so you'd have to re-mint, and it feels like "the token often can't be found when creating a reverse proxy". The root cause isn't NPM; it's the mismatch between multi-step manual operations and the Bash tool's statelessness.

`vps_oracle/compose/npm/add-proxy-host.sh` wraps the whole flow in a **single** shell process that runs to completion, keeping the token entirely inside the script, and also handles every gotcha documented above: looks up the access list id by name (doesn't hardcode 1/2), uses the 2.15.1 new schema for certificates, reuses an existing certificate if the domain already has one instead of re-requesting, re-GETs after creating the proxy host to verify whether `ssl_forced`/`http2_support` were silently reset (and automatically PUTs them back if so), and finally runs `nginx -t`.

Usage:

```bash
./add-proxy-host.sh <service>.jerome.cloudns.asia <forward-host> <forward-port> [self-only|self-only-and-auth]
```

The 4th argument defaults to `self-only`; admin panels without built-in auth must pass `self-only-and-auth` (rule in the root README under "wiring a service into an NPM reverse proxy").

**Cases the script doesn't handle — use the manual flows in the other sections of this doc**:

- The domain already has a proxy host — the script errors out and exits instead of overwrite-updating (use the UI or the manual API flow above)
- Services needing Custom Locations — the repo convention is to avoid them where possible (see the root README under "avoid Custom Locations when you can"), the script doesn't implement them
- Reverse-proxying to a k3s NodePort — just pass `10.0.0.95` as `forward-host`; the script does no special handling, but that IP is DHCP-assigned, so first confirm it hasn't changed per the known gotcha in the root README
- For new services, remember to manually add a homepage card afterwards (`vps_oracle/compose/homepage/config/services.yaml`); the script doesn't add it automatically

## 2026-08-21: upgrade to 2.15.1, and a 90-second full-site outage

**Reason for the upgrade**: the Proxy Hosts count on the dashboard homepage showed only 16, when there were actually 24. 2.12.3's `report.js` wrote `permission_visibility` as `visibility`, so it always got `undefined`, and the count then always fell back to "only hosts owned by the current logged-in user" — the 8 hosts created with the automation account (`claude`) were never counted. The list page was always correct; only that homepage number was wrong. The upstream fixed it in **2.14.0**. Along the way we also got a security fix from 2.15.0: any authenticated user could change their own `roles` field via `PUT` — which landed squarely on the `claude` account in `.npm-automation.env` that was supposed to be least-privileged.

**How the outage went**: after `docker compose up -d` rebuilt the container, nginx repeatedly failed to start:

```
nginx: [emerg] host not found in upstream "dify-api" in /data/nginx/proxy_host/24.conf:74
```

For about 90 seconds on 443 there was no process listening at all — not a single site returning 502, but all sites unreachable. Handling: renamed `24.conf` to `24.conf.disabled-2026-08-21`, and s6's retry loop brought it up on the next round.

**This is unrelated to the upgrade.** Proxy host 24 (dify) has 8 Custom Locations pointing at `dify-api:5001` / `dify-plugin-daemon:5002`, and the entire dify stack had been stopped 45 hours earlier. Literal upstreams must be resolved at config load time (mechanism in the repo root README under "avoid Custom Locations when you can"), so rolling back to 2.12.3, or simply `docker restart npm`, or rebooting the host would all produce exactly the same result. The four days before were fine only because that nginx process had started while dify was still alive.

**Items verified as part of the upgrade itself**: both DB migrations (`redirect_auto_scheme`, `trust_forwarded_proto`) applied normally; all 24 certificates passed `certbot renew --dry-run` (all HTTP-01, no DNS plugin used, so 2.15.0's certbot 5.6 DNS plugin warning doesn't apply); and the API flow's mount paths above were unchanged.

### Leftover state: dify's reverse proxy

Currently **host 24 is still enabled in the DB, but its conf is missing from disk** — the two are inconsistent. An npm restart is safe in this state.

Only these three things, all requiring manual action and none happening on their own, would write `24.conf` back (i.e. re-arm the landmine) — automatic renewal only runs `certbot renew` and updates the DB expiry, never regenerating any host config:

| Trigger action | Impact scope |
|---|---|
| Editing the `self-only` access list (e.g. the public IP changed and needs an updated allow rule) | Rewrites every host config under it, including 24 |
| Editing or enabling host 24 in the panel | Rewrites 24 |
| Re-**requesting** (not renewing) dify's certificate | Rewrites the hosts using that domain |

To root it out there are two paths: bring dify back up (once `dify-api` resolves, the landmine disappears naturally), or disable host 24 in the panel. Until then, after doing any action in the table above, run `docker exec npm nginx -t` once to confirm; `vps_oracle/host-native/inspector/checks/npm-nginx-config.sh` will also catch it within 12 hours.

### A known piece of log noise

Each request writes one line: `[warn] using uninitialized "trust_forwarded_proto" variable`. The host config on disk was still generated by 2.12.3 and lacks the `set $trust_forwarded_proto "F";` that 2.14.0 added; the new image's `conf.d/include/force-ssl.conf` carries its own fallback default, so **the behavior is exactly the same as before the upgrade** — purely log noise, and logrotate keeps it in check. It won't go away on its own; clearing it requires regenerating the corresponding host's config (see the table above) — but that would also re-arm the dify landmine; the two are the same switch.