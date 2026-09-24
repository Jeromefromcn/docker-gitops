# sillytavern

[SillyTavern](https://github.com/SillyTavern/SillyTavern) 1.19.0 — an LLM roleplay frontend — running on **vps_oracle2**. Deploy with the docker context, since the repo only lives on vps_oracle:

```bash
docker --context oracle2 compose -f vps_oracle2/compose/sillytavern/docker-compose.yml up -d
```

**There is no LLM backend here.** SillyTavern is only the frontend; the model API (OpenRouter, Featherless, a self-hosted endpoint, ...) is configured from the UI, and the API keys it stores live in `/etc/sillytavern/data` on oracle2 — never in this repo. The former `llm` stack (`llama-cpp` + `open-webui`) that used to provide a local backend was removed on 2026-09-24, so nothing in this repo serves an inference endpoint.

## Hosting model (cross-host)

Same as [dify](../dify/README.md): there is no shared docker `proxy` network between the two hosts. `sillytavern` publishes `100.100.140.33:8000` — oracle2's tailscale IP, never `0.0.0.0` — and NPM on vps_oracle forwards to that IP over the tailscale mesh. If oracle2 re-registers on tailscale (e.g. after `tofu destroy`/`apply`), update the IP in this compose file and in the NPM proxy host.

The forward host is a literal IP, so nginx has no name to resolve at config load: a stopped SillyTavern returns 502 for this one site rather than breaking NPM's startup.

## One-time host preparation

The bind mounts must exist on oracle2's filesystem before the first `up`. uid/gid 1001 is oracle2's `ubuntu` user (uid 1000 there is `opc`); `PUID`/`PGID` in compose matches, and the entrypoint re-chowns anything that doesn't.

```bash
ssh vps-oracle2 'sudo mkdir -p /etc/sillytavern/{config,data,plugins,extensions} && sudo chown -R 1001:1001 /etc/sillytavern'
```

| Mount | Contents |
|---|---|
| `/etc/sillytavern/config` | `config.yaml`, generated from ST's `default/config.yaml` on first start |
| `/etc/sillytavern/data` | chats, character cards, groups, worlds, secrets (**API keys live here**) |
| `/etc/sillytavern/plugins` | server plugins |
| `/etc/sillytavern/extensions` | third-party UI extensions (`public/scripts/extensions/third-party`) |

`backups/` is deliberately not mounted — upstream's compose doesn't either, and it only holds chat backups, not the chats themselves.

## Configuration lives in environment variables, not a committed config.yaml

`getConfigValue()` (`src/util.js`) checks `SILLYTAVERN_<KEY>` — upper-cased, dots turned into underscores — **before** reading `config.yaml`. `basicAuthUser.username`/`.password` are read through it (`src/users.js`, `src/middleware/basicAuth.js`), so the credential stays in the gitignored `.env` and no `config.yaml` needs to be committed:

| Compose env | Effective config key |
|---|---|
| `SILLYTAVERN_BASICAUTHMODE` | `basicAuthMode` |
| `SILLYTAVERN_WHITELISTMODE` | `whitelistMode` |
| `SILLYTAVERN_BASICAUTHUSER_USERNAME` | `basicAuthUser.username` |
| `SILLYTAVERN_BASICAUTHUSER_PASSWORD` | `basicAuthUser.password` |

Changing a value means editing `.env` and recreating the container — a change made in ST's own settings UI is written to `config.yaml`, which the environment variable then overrides on the next start.

### `whitelistMode` is deliberately off — the gotcha worth remembering

ST's defaults are `whitelistMode: true` **and** `enableForwardedWhitelist: true`. The middleware denies the request when *either* the socket IP *or* the X-Forwarded-For IP falls outside the whitelist:

```js
// src/middleware/whitelist.js
if (!isIPInWhitelist(whitelist, clientIp)
    || (forwardedIp && !isIPInWhitelist(whitelist, forwardedIp)))
```

NPM is a reverse proxy, so it sets `X-Forwarded-For` to the **browser's public IP** — which can never be in ST's static whitelist, since that same IP is already changing and is handled by NPM's access list instead. Left at the default, every request gets `403 forbidden-by-whitelist`, on every page, including the first load. Note that whitelisting the tailscale IP does **not** fix it: the failing check is the forwarded one.

So access control rests on two layers instead:

1. ST's own `basicAuthMode` (this also switches off ST's no-auth auto-login — `src/users.js` returns early from the security check when `basicAuthMode || whitelistMode` is set);
2. NPM's access list `self-only-and-auth` — an IP allowlist plus NPM's own basic auth on top.

## NPM

| Field | Value |
|---|---|
| Domain | `st.jerome.cloudns.asia` |
| Scheme | `http` |
| Forward Hostname / IP | `100.100.140.33` |
| Forward Port | `8000` |
| Websockets Support | On |
| Cache Assets | Off |
| Block Common Exploits | On |
| Access List | `self-only-and-auth` |

SillyTavern serves its SPA from the root path, so no Custom Locations are needed. Create it with the repo's script (see `vps_oracle/compose/npm/README.md`):

```bash
cd vps_oracle/compose/npm
./add-proxy-host.sh st.jerome.cloudns.asia 100.100.140.33 8000 self-only-and-auth
```

Then reopen the proxy host and re-check that Force SSL / HTTP/2 weren't silently reset.

**`self-only-and-auth` is a deliberate deviation** from the general rule (that access list is normally reserved for admin panels with no built-in auth). SillyTavern does have its own basic auth, but it also holds model API keys, so this stack takes both layers and accepts the double browser prompt. Proxy host id 41, certificate id 43. Switching back is a one-line change to the access list in the NPM UI.

## Users and authentication

ST ships with `enableUserAccounts: false` and `perUserBasicAuth: false`, so there is exactly one shared basic-auth credential (the username is arbitrary — it does not map to an ST user handle). User accounts can be enabled later from the UI if multi-user is ever wanted; if it is, `perUserBasicAuth` becomes the option that ties each account to its own basic-auth credential.

## Verifying a deployment

```bash
docker --context oracle2 compose -f vps_oracle2/compose/sillytavern/docker-compose.yml ps
docker --context oracle2 logs sillytavern --tail 30        # error/middleware log, not the app log
ls -ln /etc/sillytavern/data                              # files should be owned by 1001, not root
```

Timezone: the image is `node:lts-alpine3.23` and installs no tzdata, so `TZ` relies on Node's own bundled zone data. Judge it from ST's log timestamps (`+08:00`), not from `docker exec date`.
