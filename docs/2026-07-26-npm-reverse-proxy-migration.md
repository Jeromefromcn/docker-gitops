# 2026-07-26 Introducing nginx-proxy-manager, moving services to domain + HTTPS reverse proxy

A complete record of building a reverse proxy from scratch and migrating existing services onto it. Contains 7 gotchas, each of which could be its own article.

> **⚠️ Redact before publishing**: see the [redaction checklist](#redact-before-publishing) at the end. This repo is private, so full details are kept here.

---

## 1. Background and goals

State before the change:

- One Oracle Cloud ARM VPS running `3x-ui` (VLESS + Reality proxy service)
- Every service published its own port to the host, accessed via "public IP + non-standard port"
- No domain, no HTTPS, management panel was plaintext HTTP

Goals:

1. Set up nginx-proxy-manager (referred to as NPM) as a unified reverse-proxy entry point
2. Move all HTTP(S) services to domain + Let's Encrypt certificates
3. Services no longer expose ports to the public network; NPM becomes the single entry point

## 2. Final architecture

```
              public network
                     │
         ┌───────────┴───────────┐
         │                       │
    :80 / :443              :39876
         │                       │
    ┌────▼────┐                  │  VLESS + Reality
    │   NPM   │                  │  client connects directly, not via NPM
    │ (nginx) │                  │
    └────┬────┘                  │
         │  proxy network (container-name resolution) │
    ┌────┴──────────────┐        │
    │                   │        │
 npm itself           3x-ui ◄──────┘
  127.0.0.1:81    :46213 panel
                  :51234 subscription
```

| Domain | Points to | Description |
|---|---|---|
| `npm.jerome.cloudns.asia` | `127.0.0.1:81` | NPM reverse-proxies its own management panel |
| `panel.3x.jerome.cloudns.asia` | `3x-ui:46213` | 3x-ui panel (via container name) |
| `sub.3x.jerome.cloudns.asia` | `3x-ui:51234` | subscription service (via container name) |
| — | `IP:39876` | VLESS node; the protocol requires direct connection, not via reverse proxy |

The host keeps only these exposed to the public: `22` (SSH), `80`/`443` (NPM), `39876` (node).

## 3. Key decisions and rationale

### 3.1 One shared external network instead of each service's default network

```bash
docker network create proxy   # created manually once, outside any compose lifecycle
```

Each service that needs reverse-proxying, in its own compose:

```yaml
services:
  myapp:
    networks:
      - proxy        # ← this is what actually attaches the network interface to the container

networks:
  proxy:
    external: true   # ← this just declares "use the existing one, don't create a new one"
```

**The difference between the two `networks` levels** (a point many people are fuzzy on):

- the top-level `networks:` is a "network roster" that only declares where networks come from / their definitions — it doesn't attach any container
- the `networks:` under a service is what actually attaches an interface to that container
- side effect: once a service **explicitly declares** `networks:`, compose no longer adds the project default network (`<project>_default`)

**Benefit**: in NPM, Forward Hostname can be filled in directly with the container name (Docker's built-in DNS resolution), services don't publish any ports, and when a container is recreated its IP changes without any config edits.

### 3.2 Which containers should join `proxy`

When I first wrote the README I divided it as "new services join, old service (3x-ui) stays as-is" — that was a lazy justification, and I was called out on the spot; it doesn't hold up. Later changed to a principle-based division:

- **Default**: containers with HTTP(S) services that need reverse-proxying all join
- **Exception**: ports that require direct client connection by protocol (VLESS/Reality's raw handshake port) — publish them; they are never reverse-proxy targets
- **Do not join**: pure backends that don't serve anything externally (databases, workers) keep their default isolation

Key clarification: **joining the `proxy` network does not automatically reclaim the host port**. These are two separate things; they only make sense done together, and doing only the former just adds a path without removing one.

### 3.3 Don't open a public port for the management panel; reverse-proxy it via NPM

The NPM management panel listens on `81` inside the container and is **plaintext HTTP**. Trade-off among three options:

| Option | Password in plaintext over public network | Always accessible without SSH |
|---|---|---|
| Publish `81` directly to the public | ❌ yes | ✅ |
| `127.0.0.1:81:81` + SSH tunnel | ✅ no | ❌ must open a tunnel each time |
| **NPM reverse-proxies itself, via domain + 443** | ✅ no | ✅ |

Chose the third: Proxy Host filled with `127.0.0.1:81`, Scheme filled with `http`, SSL via Let's Encrypt. After configuring, delete the `81` port mapping from compose entirely.

**Why Scheme is `http` not `https`**: that field refers to *what protocol NPM uses to reach the backend*. Browser→NPM is HTTPS (Force SSL), NPM→`127.0.0.1:81` is HTTP, because there's no TLS listener on 81 at all. Filling in `https` yields an immediate 502.

---

## 4. Gotcha log

### Gotcha 1: two layers of firewall — all green locally but nothing gets in from outside

**Symptom**: Let's Encrypt certificate issuance failed.

```
Detail: 161.118.254.107: Fetching http://npm.jerome.cloudns.asia/.well-known/
acme-challenge/JXeYmV...: Timeout during connect (likely firewall problem)
```

**Troubleshooting**: on the host, `curl 127.0.0.1:80` returns 200, and 80 is also allowed in iptables — from the host's perspective everything is normal.

**Root cause**: the cloud server has **two independent layers of firewall**; missing one breaks connectivity:

1. **iptables inside the instance** — turned out only `22/8090/9090/3001/80` were allowed, **443 had never been allowed**
2. **OCI's VCN Security List** — cloud-platform level, independent of iptables, only changeable in the console

`80` was being blocked by the cloud-platform layer, so it looked reachable locally but timed out from outside.

**Fix**:

```bash
sudo iptables -I INPUT 8 -p tcp --dport 443 -j ACCEPT
```

Persistence: write the rule into `vps_oracle/host-firewall/host-firewall.sh` (loaded at boot by `host-firewall.service`, the single source of truth for hand-written host firewall rules).

> ⚠️ Red line (root cause of the 2026-08-16 incident): **do not** use `netfilter-persistent save` / `iptables-save` to persist a full snapshot — a full snapshot freezes Docker's runtime rules too, and netfilter-persistent replays them at every boot, turning ghost rules into a black hole for container traffic. netfilter-persistent has been disabled; see `vps_oracle/host-firewall/README.md`.

Plus add the Ingress Rule for `80`/`443` in the OCI console.

**Follow-up question: can port 80 be turned off normally and only opened when requesting certificates?** No. Let's Encrypt certificates are valid for 90 days, and NPM's built-in renewal timer automatically re-runs the same HTTP-01 validation, which also needs 80. If turned off, renewal **silently fails**, and by the time it's noticed the certificate has usually already expired and the site is down. Port 80 only carries certificate validation and the HTTP→HTTPS redirect, with no sensitive entry point; leaving it open all year round is low risk.

### Gotcha 2: a widely-spread wrong claim (that 127.0.0.1 loops forever)

The user brought another AI's answer for comparison:

> Because your NPM is running inside a Docker container. From the container's perspective, 127.0.0.1 means "the container itself", so if you fill in 127.0.0.1, NPM will infinitely loop requests to itself inside the container, resulting in a 502.

**This claim is wrong**, and deceptively so — the first half (127.0.0.1 points to the container itself) is correct, but the conclusion doesn't follow.

**Actual test**:

```bash
$ docker exec npm curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:81/
200
```

Instant response, no loop.

**Why there's no loop**: inside the NPM container is **one nginx process managing multiple virtual hosts** — one listening on 443 (handling domain reverse-proxy requests), another listening on 81 (management backend). Forwarding 443 to `127.0.0.1:81` is "forwarding from one port's listener to another port's listener", a single hop, not recursion.

**The way that actually loops forever**: filling the Forward target with the domain itself, or filling the port with 443 (443 forwarding to 443).

> This section deserves its own article: **a technical claim should be falsified with an executable experiment, not by sounding plausible**. One `docker exec ... curl` ends the argument.

### Gotcha 3: a one-character typo, reporting 502

After certificate issuance succeeded, accessing returned 502. Checking the nginx error log:

```
127.0.01 could not be resolved (3: Host not found), client: ...,
server: npm.jerome.cloudns.asia, request: "GET / HTTP/1.1"
```

`127.0.01` — missing one `0`. nginx treated it as a domain to resolve, and of course couldn't.

**Lesson**: don't stop at "502 = backend down"; the `proxy_host` error log directly tells you where nginx is actually connecting. Log path: `/data/nginx/../logs/proxy-host-N_error.log`.

Along the way I noticed the logs already contained scanning bots batch-probing `/.env`, `/docker-compose.yml`, `/secrets.json`, `/credentials.json` — minutes after a domain goes public it gets scanned; this is the norm.

### Gotcha 4: panel root path returns 404

`https://panel.3x.jerome.cloudns.asia/` returns 404, but the reverse-proxy chain works (TLS handshake succeeds, responses come back).

For security, 3x-ui serves the panel not at the root path but under a custom `webBasePath`. Query the database for the exact value:

```bash
python3 -c "
import sqlite3
con = sqlite3.connect('/etc/x-ui/db/x-ui.db')
print(con.execute(\"SELECT key,value FROM settings WHERE key='webBasePath'\").fetchall())
"
```

**Lesson**: distinguish "reverse proxy is broken" from "reverse proxy works but the path is wrong" — the former gets no response, the latter gets a definite HTTP status code.

### Gotcha 5: the subscription link still carries the reclaimed internal port

After reclaiming the subscription service's `51234` from the host, the panel-generated subscription link could still be assembled as `https://sub.xxx:51234/sub/...` — that port is no longer exposed, so clients get a dead link.

Query the database to confirm: `subDomain` empty, `subURI` empty, `subPort` still `51234`.

**Fix**: panel → Subscribe Settings → **Reverse Proxy URI** filled with `https://sub.3x.jerome.cloudns.asia/sub/`; the Clash field correspondingly filled with `.../clash/`. This field overrides the entire `subDomain`/`subPort` assembly logic.

Notably, **the UI's own help text already spells this scenario out**: "if the subscription is reached through a reverse proxy on a different port, set 'Reverse Proxy URI' instead". My first instinct at the time was to change the `Listen Port` above — that's the port actually listening inside the container, and changing it would instead break NPM's connection.

> Angle for writing: **the intuition of "which field to change" is often wrong — internal listening port vs externally published address are two concepts that must not be conflated.**

### Gotcha 6: VPN ate its own management traffic (self-loop)

**Symptom**: panel intermittently `ERR_CONNECTION_CLOSED`, resolves after a few refreshes.

**Clue**: in the nginx access log, the client IP shows as `161.118.254.107` — **the VPS's own public IP**.

**Root cause**: the user was accessing the panel while running this server's own VPN, forming a loop:

```
browser → VPN tunnel → VPS → egress from the VPS back to the public network → back to the VPS's own 443 → nginx → panel
```

This "server proxying itself" path is inherently unstable; intermittent disconnects are the classic symptom.

**Fix**: add a direct rule to Clash/Mihomo's global routing rules:

```
DOMAIN-SUFFIX,jerome.cloudns.asia,DIRECT
```

Configured in the server-side subscription, so all clients pulling this subscription take effect automatically, without editing each device by hand.

> Angle for writing: **almost everyone running a self-hosted proxy hits this loop** — the management backend's domain must be set to DIRECT in your own proxy rules.

### Gotcha 7 (the finale): X-Forwarded-For polluted the node address

This is the most subtle and the most article-worthy one of the whole process.

**Symptom progression**: first "some clients work, some don't", and finally **all clients fail to connect**.

**Server-side itemized checks, all normal**:

- container `healthy`, xray process alive (process start time matches the config modification time; not a zombie running stale config)
- Reality private key, `target`, `serverNames`, `shortIds` all correct
- derived the public key from the private key — exactly matches the client subscription
- fail2ban zero bans, logs empty
- from outside, `nc -zv <IP> 39876` → `succeeded`, **network layer fully reachable**

**A wrong guess mid-way** (worth putting in the article): I first suspected the `39876` rule in the OCI Security List had been accidentally deleted — the reasoning chain looked very plausible ("all green locally, all broken externally", "touched the OCI console today"). The user screenshotted the rule still being there, falsifying the guess. **A plausible reasoning chain isn't a correct conclusion; having the other side verify beats continued deduction.**

**The decisive clue** — the client's actual error:

```
dial tcp 203.185.15.62:39876: connect: connection refused
```

Reverse-looking-up `203.185.15.62` → `ctinets.com`, the **user's own ISP egress IP**. Then looking at the subscription content:

```yaml
proxies:
- name: sg-node-...
  server: 203.185.15.62   # ← should be the server address, but got filled with the client's own IP
  port: 39876
```

**Root cause**:

1. After migrating to NPM, NPM — following standard reverse-proxy practice — attaches `X-Forwarded-For` (real client IP) to the backend; NPM doing this is **correct**
2. 3x-ui, when generating the node link, mistakenly treats this "client IP" as "the server's own address"
3. the panel has a `hosts` table specifically meant to **pin** the node's external address, but it was **empty**, so nothing overrode the wrong guess

The three conditions stacked up, causing the subscription's `server` field to become "whatever IP pulls the subscription".

**Why it never broke before**: previously clients pulled the subscription via `IP:port` directly, never through the reverse proxy, so this code path was never reached. **This is a latent bug that only triggers "behind a reverse proxy".**

**Why I didn't catch it early** (a methodological lesson): when I tested pulling the subscription on the server, the "detected client IP" happened to be the server's own public IP, and the output looked perfectly correct — **the test's observation point itself hid the bug**. The same command, run from an external device, exposes it instantly.

**Fix**: panel → Hosts → Add Host

| Field | Value |
|---|---|
| Inbounds | `sg-node` |
| Address | `jerome.cloudns.asia` (use the domain rather than the IP, so DDNS IP changes don't require edits) |
| Port | `39876` |
| Security | `same` (inherit the existing Reality config, don't override SNI/key) |

Leave the remaining Host header / Path / Mux / Sockopt / Clash fields all empty — those are for WS/gRPC/CDN scenarios, not needed for raw TCP + Reality.

---

## 5. Troubleshooting method distilled

1. **Locate layer by layer, falsify each in turn**: local listener → local firewall → cloud-platform firewall → protocol layer → client config. Test each layer with a command that gives a definitive answer.
2. **Watch for observation-point bias**: testing your own public service from the server often misleads (gotcha 1's port 80 and gotcha 7's subscription content both fell to this). **Critical verification must be done from an external device.**
3. **Let the error speak for itself**: `ERR_CONNECTION_CLOSED`, `502`, `404` carry very little information by themselves; nginx's `proxy-host-N_error.log`, certbot's `letsencrypt.log`, and the client's `dial tcp ... refused` are the real clues.
4. **Distinguish three forms of "can't connect"**: `timeout` (blocked/packet loss), `connection refused` (reached but nobody listening), `connected but handshake fails` (protocol/key problem). In gotcha 7 it was precisely the word `refused` that signaled "connected to a wrong address".
5. **For config issues, query the data source directly**: the panel UI doesn't necessarily show all fields; `sqlite3` against the settings/hosts tables shows the real values at a glance.

## 6. Leftovers and TODOs

- **Telegram bot 409 conflict**: `Conflict: terminated by other getUpdates request`. Only reported at the moment saving settings triggers a restart, not reproduced afterwards, but hints there may be another place using the same bot token — unconfirmed.
- **OCI redundant ports not cleaned up**: `58921`, `46213`, `51234` no longer have local listeners, and can be deleted from the Security List. Among them `58921` underwent full forensics (git history, bash_history, journalctl, docker events, full-disk config search) **with no record**; the closest is `58217`, used by the deleted subconverter service, guessed as a typo made back then.
- **How to reverse-proxy a service not on the `proxy` network**: use the `proxy` network's gateway IP `172.19.0.1` (verified working; filling the host's public IP does not). More robust is adding `extra_hosts: ["host.docker.internal:host-gateway"]` to NPM, using `host.docker.internal` instead of a hardcoded IP. Not yet implemented.
- **3x-ui health check still doesn't verify a real VLESS handshake**, per the [2026-07-24 incident record](incidents/2026-07-24-3x-ui-vless-unreachable.md)'s conclusion; not improved.

## 7. Appendix: division of labor among NPM / nginx / certbot

Easy to mix up when writing; let's lay it out clearly. **The one actually doing the work is always nginx**; NPM isn't involved in any networking or encryption.

Things you'd have to do by hand without NPM:

1. `certbot certonly --webroot ...` to get the certificate (via ACME HTTP-01 validation)
2. hand-write the `listen 443 ssl` server block, configure `ssl_certificate` / `ssl_certificate_key`, and add `proxy_pass` for the reverse-proxy case
3. write a separate port-80 server block for the 301 redirect, and leave a path for `/.well-known/acme-challenge/`
4. `nginx -s reload`
5. set up your own cron/systemd timer to run `certbot renew`, then reload after renewal
6. for each domain added, repeat steps 1–5 all over again

What NPM does is **automate all of the above**:

- form → auto-generates the nginx config file (`/data/nginx/proxy_host/N.conf`)
- button click → runs certbot in the background (the full command line is visible in the logs)
- built-in renewal timer (startup log `SSL Renewal Timer initialized`) replaces cron
- every change auto-runs `nginx -t` + `nginx -s reload`

The **TLS termination** concept also needs spelling out: encryption only exists in the "browser → nginx" stretch; nginx → backend is usually still plaintext HTTP. That's why, in gotcha 3, Scheme needs to be `http`.

---

## Redact before publishing

This repo is private; the following content should be replaced with placeholders in a public article:

| Type | Value in this document | Suggested replacement |
|---|---|---|
| Public IP | `161.118.254.107` | `203.0.113.10` (documentation example range) |
| Domain | `jerome.cloudns.asia` and its subdomains | `example.com` |
| Panel custom path | the real value of `webBasePath` (omitted here) | keep it unwritten — this is a real security barrier |
| Node port | `39876` | keepable (already described as a non-standard port), or change to `xxxxx` |
| Client egress IP | `203.185.15.62` | `198.51.100.20` |
| Reality public key / UUID / subId | omitted throughout | keep unwritten |

Also, gotcha 7 concerns 3x-ui's address-inference flaw under a reverse proxy; if turning it into a public article, suggest also giving the workaround (configuring the Hosts table) so readers don't copy the architecture and hit the same gotcha.