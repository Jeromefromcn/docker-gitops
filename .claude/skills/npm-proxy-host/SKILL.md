---
name: npm-proxy-host
description: Create or modify a reverse-proxy record (proxy host) in Nginx Proxy Manager. Use when you need to configure a <service>.jerome.cloudns.asia domain for a service, onboard it to NPM, request/reuse an SSL certificate, set an access list, or reverse-proxy to a k3s NodePort. Includes add-proxy-host.sh usage and three known pitfalls that silently fail.
---

# Onboard a service to the NPM reverse proxy

When adding or modifying an NPM reverse-proxy record, follow the config below and keep it consistent with the existing stacks.

> NPM was upgraded from 2.12.3 to 2.15.1 on 2026-08-21, and the React-based new UI arrived in 2.13.0. The fields below still exist, but their locations/names may differ from the old UI — the next time you follow this and something doesn't line up, update this paragraph as you go.

For the common case — **no Custom Locations, and not reverse-proxying to a k3s NodePort** — you can just run [`vps_oracle/compose/npm/add-proxy-host.sh`](../../../vps_oracle/compose/npm/add-proxy-host.sh) to set it up in one go (including certificate request/reuse, selecting the access list by name, and auto-verifying after creation that the SSL settings weren't silently reset); see the "build the proxy host in one go with the script" section of [`vps_oracle/compose/npm/README.md`](../../../vps_oracle/compose/npm/README.md) for usage. The field table below shows the values this script applies automatically, and is the reference when doing it manually via the UI/API.

**Details tab**

| Field | Value |
|---|---|
| Domain Names | `<service>.jerome.cloudns.asia` |
| Scheme | `http` |
| Forward Hostname / IP | Container name (matches `container_name` in compose, resolved via the `proxy` network's Docker DNS — no need to enter an IP) |
| Forward Port | The container's actual internal listening port (not a host port — these services don't publish ports anyway) |
| Cache Assets | Off |
| Block Common Exploits | On |
| Websockets Support | On |
| Access List | Always select `self-only` (exception: **admin panels with no built-in auth** use `self-only-and-auth`) |
| Custom Locations | Avoid where possible — rationale under the convention below |

**SSL tab**

| Field | Value |
|---|---|
| SSL Certificate | Select the certificate matching the Domain Names; for a new domain choose "Request a new SSL Certificate" |
| Email Address for Let's Encrypt | Always `jeromefromcn@gmail.com`, consistent with existing certificates — no need to look it up |
| Force SSL | On |
| HTTP/2 Support | On |
| HSTS Enabled | Off |

**⚠️ Known pitfall**: Force SSL / HTTP/2 Support that you turn on at creation time are sometimes silently reset back to off. **After saving, reopen the record and double-check**; if they're off, tick them again and save.

**⚠️ Known pitfall (when reverse-proxying to a k3s NodePort)**: Forward Hostname/IP must be the host's internal IP directly (currently `10.0.0.95`) — not `host.docker.internal` or any other hostname — because the proxy_pass config NPM's nginx generates resolves via Docker's embedded DNS resolver, and does not read the container's `/etc/hosts`/`extra_hosts`; entering a hostname reports "could not be resolved" and yields a 502. Also, this IP is DHCP-assigned (`ip -4 addr show enp0s6` shows `dynamic`), not static — if Oracle changes the address, every reverse proxy pointing at a NodePort silently becomes 502, so check whether this IP changed before troubleshooting. See [`k3s/README.md`](../../../k3s/README.md) and the `extra_hosts` comment in [`vps_oracle/compose/npm/docker-compose.yml`](../../../vps_oracle/compose/npm/docker-compose.yml).

**⚠️ Known pitfall (changing `locations` via the API may not take effect, and fails silently)**: discovered during the dify migration cutover — `PUT /api/nginx/proxy-hosts/{id}` with the full `locations` array writes the new values into NPM's own database (a subsequent `GET` reads the new values), but the step that regenerates `/data/nginx/proxy_host/{id}.conf` does not re-render — the file on disk still holds the old content. If the old file references an upstream hostname that can no longer be resolved (e.g. the corresponding compose container has been `stop`ped), `nginx -t` reports `host not found in upstream`, the API returns `{"error":{"message":"Internal Error"}}` (500), and retries fail the same way; meanwhile nginx is still running the earlier last-successfully-reloaded config — and if the container that config references has also been stopped, the site 502s externally, and **this 502 does not self-heal; it stays stuck until a human intervenes**. The fix at the time: `docker exec npm cat /data/nginx/proxy_host/{id}.conf` to confirm the on-disk file really hadn't changed, then edit that file directly with `docker exec npm sed -i ...` (to match the values the API had already written to the database), `docker exec npm nginx -t` to verify syntax, then `docker exec npm nginx -s reload` to apply manually — the database and the on-disk config end up consistent, just with a human filling in the step NPM itself never completed. **Debugging clue**: `nginx: [emerg] host not found in upstream "..."` in `docker logs npm` pinpoints exactly which upstream hostname failed to resolve; use that stale hostname to trace back to whichever compose container has been stopped. **Avoidance advice**: when switching a service with multiple `locations`, consider NOT stopping the old compose container ahead of the cutover (wait until you've confirmed the API update actually took effect and `nginx -T` shows the new config), or verify the on-disk file immediately after the cutover rather than trusting only the API response / database value.

**⚠️ Convention: avoid Custom Locations wherever possible**

The pitfall above has a more general form that is unrelated to cutover and far more severe. When NPM generates config, ordinary forwards put the upstream hostname in a variable (`set $server "trilium";`) and nginx resolves it per-request via Docker's embedded DNS, so a missing backend container only 502s that one site; but **every Custom Location hardcodes the hostname into `proxy_pass`** (NPM's `_location.conf` template), and the literal upstream must resolve **at config-load time** or nginx directly `[emerg]` refuses to start — **all reverse-proxy sites go down together**, not just that one.

The running nginx keeps going off the previously resolved addresses, so after a backend container stops, nothing looks wrong from monitoring, the panel, or the logs. It detonates only on the **next cold start of nginx**: a host reboot, `docker compose up -d`, an image upgrade — usually an unrelated moment. This is exactly how the 2026-08-21 NPM upgrade blew up (the dify container had been stopped for 45 hours; a full-site outage of about 90 seconds) — the full story is in [`vps_oracle/compose/npm/README.md`](../../../vps_oracle/compose/npm/README.md).

So:

- **Prefer letting the service's own nginx/gateway handle path routing**, and have NPM do a single ordinary forward to that one container. The reason dify needs 8 Custom Locations is precisely that this repo's dify compose lacks the official `nginx` service.
- **When you decommission a compose stack, disable the corresponding proxy host in NPM at the same time**. A reverse-proxy record left enabled with no backend is a landmine.
- Safety net: `vps_oracle/host-native/inspector/checks/npm-nginx-config.sh` runs `nginx -t` at 09:00/21:00 daily and sends a Telegram alert if the config is broken. It runs in a separate process and doesn't affect the serving nginx, so you can always run it once manually to confirm: `docker exec npm nginx -t`.


## Final checks

1. **Re-check the SSL tab** — Force SSL / HTTP/2 are sometimes silently reset to off, so reopen the record and confirm once.
2. `docker exec npm nginx -t` to confirm the config loads (this catches literal-upstream resolution failures introduced by Custom Locations early).
3. For those reverse-proxied to a k3s NodePort, verify once with `curl -sS -o /dev/null -w 'HTTP %{http_code}\n' https://<service>.jerome.cloudns.asia/`.
4. If it's a new service, don't forget the homepage card — see the `add-service` skill.