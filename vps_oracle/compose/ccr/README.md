# vps_oracle/compose/ccr

Use [claude-code-router (CCR)](https://github.com/musistudio/claude-code-router) to switch Claude Code's backend model between the **official subscription** and **third-party providers** on a per-"project group" basis, and keep **each group isolated from the others** — switching one group must never affect another.

> **CCR is a routing gateway, not a synonym for "Zhipu".** CCR can route claude's requests to **any** OpenAI-compatible provider (Zhipu GLM, DeepSeek, Qwen...). This repo's current deployment has the upstream configured as Zhipu GLM, so everywhere below that says "Zhipu" means the **current routing target**, not CCR itself. To change the upstream (e.g. to another model), just change the provider config in the CCR admin panel — the switchboard CCR toggles and the architecture in this README don't need to change.

This directory holds CCR itself; the accompanying switching UI lives in `../switchboard/` (a generic config-driven toggle framework, of which jerome-ccr/bridget-ccr are just two toggles). This README is the master document for the whole group-switching system.

> Want to bind **different Claude subscription accounts** to different groups (directory isolation)? See [`ACCOUNTS.md`](ACCOUNTS.md) — via `CLAUDE_CONFIG_DIR`, orthogonal to provider switching and stackable on top of it.

## Why this design

- The subscription token budget isn't enough, so the idea is to switch "less important project groups" to the cheaper Zhipu GLM, while "project groups that need the higher-tier models" keep using the official subscription.
- The core requirement: **isolation**. Downgrading one group must not silently affect another. So the unit of switching is a "directory-prefix group", not a global switch.
- The switching mechanism uses **direnv** (evaluates env vars per current directory), rather than editing a global config like `~/.claude/settings.json` — the latter changes everything at once, which is exactly what we want to avoid.

## Architecture: how the four parts fit together

```
Project dir ~/jerome/foo/                Project dir ~/bridget/bar/
        │                                          │
        │ .envrc (static)                          │ .envrc (static)
        ▼                                          ▼
  source_env_if_exists                       source_env_if_exists
  /home/ubuntu/.claude-provider/jerome.env   /home/ubuntu/.claude-provider/bridget.env
        │                                          │
        ▼                                          ▼
  jerome.env: empty (= official)            bridget.env: export ANTHROPIC_BASE_URL=…
                                              export ANTHROPIC_AUTH_TOKEN=ccr-profile-…
        │                                          │
        │ direnv injects these two lines into     │
        │ the claude process                      │
        ▼                                          ▼
  claude uses official OAuth                claude goes via CCR(127.0.0.1:3456) → Zhipu
```

The four parts:

1. **Static `.envrc`**: one `.envrc` at the root of each group directory (`~/jerome/`, `~/bridget/`), containing just a single line `source_env_if_exists /home/ubuntu/.claude-provider/<group>.env`. It **never changes** — so `direnv allow` is only needed the first time; switching providers afterwards doesn't require re-allowing.
2. **Dynamic `.claude-provider/<group>.env`**: the file that actually gets rewritten. Empty (or comment-only) = use the official subscription; containing the two lines `export ANTHROPIC_BASE_URL=… / ANTHROPIC_AUTH_TOKEN=…` = use CCR. **The switchboard `jerome-ccr`/`bridget-ccr` toggles are the only thing that should ever rewrite this file.**
3. **CCR** (the compose stack in this directory): gateway `127.0.0.1:3456`, admin panel `127.0.0.1:3458`, with the in-container nginx:8080 routing by path (`/v1/*`, `/messages` go to the gateway, `/`, `/api/ccr/rpc` go to the admin panel). Both host ports are bound only to `127.0.0.1` — the claude process runs on the host, not in a container, so it can't reach the proxy network and can only use the published host ports; these two host ports themselves are not exposed externally; the two routes for reaching the admin panel from another machine (NPM reverse proxy / SSH port forwarding) are under the "CCR admin panel" section below.
4. **switchboard UI** (`../switchboard/`): a generic config-driven toggle service attached to the `proxy` network, reverse-proxied by NPM as `https://switchboard.jerome.cloudns.asia` (access list=self-only). The jerome/bridget CCR switches are two toggles registered on it (`jerome-ccr`/`bridget-ccr`). Every time the page opens it **re-scans in real time** (no caching) the state of each toggle; clicking a button runs that toggle's `on.sh`/`off.sh` to atomically rewrite the corresponding `.env`.

The two paths by which direnv gets into the claude process:

- **Terminal**: `~/.claude/direnv-bash-env.sh` uses the `BASH_ENV` mechanism — it's sourced by every bash sub-shell that claude spawns, and inside it `. direnv-load.sh` evaluates the current directory's direnv.
- **VSCode extension**: a machine-level setting `claudeCode.claudeProcessWrapper=/home/ubuntu/.claude/claude-direnv-wrapper.sh` makes the extension invoke `wrapper <real claude> <args…>` with the workspace directory as cwd; inside the wrapper it likewise does `. direnv-load.sh` then `exec "$@"`, injecting the variables into the claude process itself (not just its sub-shells).

## Currently configured groups

| Group name | Directory | Default provider | Purpose |
|---|---|---|---|
| `jerome` | `~/jerome/` | Official subscription | Main project group needing Opus/Sonnet |
| `bridget` | `~/bridget/` | CCR (Zhipu) | Budget group that can be downgraded to GLM |
| `evidence` | `~/evidence/` | Official subscription | evidence project group |

## Adding a new group (copy-and-paste)

Example: adding a group called `alice` that goes through CCR:

```bash
# 1. Create the group directory + static .envrc (its content never changes)
mkdir -p ~/alice
echo 'source_env_if_exists /home/ubuntu/.claude-provider/alice.env' > ~/alice/.envrc

# 2. Create the corresponding .env (leave empty initially = official; to use CCR,
#    switch it via the UI, or write the two export lines by hand)
touch /home/ubuntu/.claude-provider/alice.env

# 3. Register a new alice-ccr toggle in switchboard:
#    - Copy the whole vps_oracle/compose/switchboard/switches/jerome-ccr/ directory
#      to switches/alice-ccr/, changing the jerome.env paths in the three scripts to
#      alice.env
#    - Add a section to switches.ini:
#      [alice-ccr]
#      group = Provider
#      label = alice
#      on_label = CCR
#      off_label = Official

# 4. Rebuild switchboard so the new toggle appears in the UI
cd vps_oracle/compose/switchboard && docker compose up -d --build
```

Then open a new claude session with this directory as the workspace. To make this group use CCR, click the button in the UI, or write directly in `alice.env`:

```
export ANTHROPIC_BASE_URL=http://127.0.0.1:3456
export ANTHROPIC_AUTH_TOKEN=<CCR client key>
```

The CCR client key (`ccr-profile-…`) is generated in the CCR admin panel; the switchboard container gets the same key via `CCR_CLIENT_TOKEN` in its `.env`, and the `alice-ccr` toggle's `on.sh` uses it to write the `.env` file.

## Four gotchas

1. **`.envrc` must stay static.** Only the `.env` file that it `source`s may change. If you edit `.envrc` itself, direnv will require re-running `direnv allow` (the trust mechanism). So keep the mutable content in `.env`; `.envrc` only does the sourcing.
2. **A project's own `.envrc` shadows the group env.** direnv loads only the "deepest" `.envrc` and does not automatically stack parent-directory ones. For example, if `~/jerome/betting-lab/.envrc` directly does `source ./venv/bin/activate`, it **replaces** `~/jerome/.envrc` and the group's provider config never comes through. The fix: add `source_up` at the very top of the project `.envrc` so it loads the parent group `.envrc` first, then does the project's own thing.
3. **Switching only takes effect for sessions opened after the switch.** A claude process already running has its env vars fixed; changing `.env` won't retrospectively change it. Only new sessions pick up the new provider.
4. **Moving a project directory breaks the resume history.** claude stores session history by project path. After moving a project from `~/jerome/x` to `~/bridget/x`, the old session records are still under the old path name, so `claude --resume` at the new path can't see them. Switching provider doesn't touch history, but physically moving the directory does.

> Note: an early UI version had a "Pending sessions" column meant to show "how many old sessions are still running". The container's private PID namespace can't see host processes, and counting them accurately would require giving the container root + `CAP_SYS_PTRACE` + `pid:host` (which, if compromised, could read host process memory) — a cost out of proportion to the security hint the column could provide, so it was removed; the static text in point 3 above now carries that reminder.

## Verification

```bash
# 1. UI live state (should return the two groups + their providers + reachable)
curl -sS https://switchboard.jerome.cloudns.asia/ | grep -oE '<td>(jerome|bridget)</td>|<td>(Official|CCR)</td>'

# 2. What direnv actually injects inside a group directory (zero token, using the
#    same wrapper real claude uses)
cd ~/bridget/any-project
/home/ubuntu/.claude/claude-direnv-wrapper.sh env | grep ANTHROPIC

# 3. Isolation: confirm that changing bridget doesn't affect jerome
#    (while bridget is using CCR)
cd ~/jerome && BASH_ENV=/home/ubuntu/.claude/direnv-bash-env.sh bash -c 'echo "${ANTHROPIC_BASE_URL:-(unset=official)}"'
```

## Renaming / deleting a group

- **Rename**: rename the `switches/<old>-ccr/` directory together with the corresponding section in `switches.ini`, `mv` the `~/<old>/` directory and `~/<old>/.envrc` to the new name, `mv /home/ubuntu/.claude-provider/<old>.env <new>.env` (the paths hardcoded in the scripts must be updated too), and rebuild switchboard. Note gotcha #4 above — moving the directory breaks old sessions' resume history.
- **Delete**: remove the corresponding section from `switches.ini`, delete the `switches/<group>-ccr/` directory, delete the `~/<group>/` directory and `.env`, and rebuild switchboard.

## Rollback (return a group to the official subscription)

Simplest: click the group's "Switch to Official" in the UI. The equivalent manual operation is to empty `/home/ubuntu/.claude-provider/<group>.env` (leaving only comments). Sessions already running still use the old provider; only new sessions return to official.

## SSE coalescing middleware (sse-coalesce.cjs)

Upstreams like Zhipu emit SSE deltas at token granularity (one every 25-50ms, ~135B per event), and the VS Code extension's per-event rendering can't keep up and falls behind, delaying the ask/approve UI by minutes. `sse-coalesce.cjs` works at the undici dispatcher layer to merge **consecutive, same-index, same-type** `content_block_delta` into larger chunks (preserving order and protocol boundaries), and is attached to every node process in the container via `NODE_OPTIONS --require`. Full investigation and design: `docs/incidents/2026-08-15-ccr-vscode-extension-stall.md`.

The coalescing window is tunable per delta type (milliseconds, set in the compose `environment:`):

| Env var | Effect | Current value |
|---|---|---|
| `CCR_SSE_COALESCE_MS` | Global window, also the fallback value for every type; `"0"` = disable overall | 200 |
| `CCR_SSE_COALESCE_THINKING_MS` | `thinking_delta`-specific window (this type is ~99% of events; display smoothness doesn't matter, so it can be large) | 500 |
| `CCR_SSE_COALESCE_TEXT_MS` | `text_delta`-specific window | 120 |
| `CCR_SSE_COALESCE_INPUT_JSON_MS` | `input_json_delta`-specific window (not set, falls back to global) | — |
| `CCR_SSE_DROP_PINGS` | Drop keep-alive pings so coalescing continues across them; `"0"` disables | Default on |

Per-type knobs that are unset or ≤0 fall back to the global value (per-type disabling alone isn't allowed — without a flush timer deltas would linger until the stream ends). Tradeoff: in the terminal, text is displayed in bursts of at most the window size; 120-500ms is imperceptible.

Runtime stats live in a container volume: `docker exec ccr cat /data/.claude-code-router/sse-coalesce-stats.log` (one line per request, `merge in=N out=M`; after changing a window, check whether the in/out ratio hits the target — ≥15x since the 2026-08-15 tuning).

**After editing a `.cjs` or a window you must run `docker compose up -d --force-recreate`**: editing only the mounted file content doesn't trigger a container rebuild, and `--require` is loaded only at process startup.

## opus/sonnet/haiku tier routing export (export-model-routing.cjs)

Claude Code's opus/sonnet/haiku tiering relies on the CLI's own `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` env vars — not on the ccr gateway auto-detecting the model name in a request to route it (otherwise it would always fall back to the profile's fallback `model` field). These three env vars have to be written into each group's `.env` by `../switchboard/`'s `on.sh`/`status.sh`, and the values they write come from each profile's own `opusModel`/`sonnetModel`/`haikuModel` in the ccr panel — but `config.sqlite` (together with its containing directory) is `700 root:root`, holds all providers' raw API keys, and no other container can read it at all.

`export-model-routing.cjs` reads only those four model strings in `profiles[]` (it never touches any key), is attached to every node process in the container via `NODE_OPTIONS --require`, and uses `fs.watch` on the `config.sqlite` main file (with 500ms debounce + a 30s fallback poll) to re-export on change, writing to a separate, non-sensitive bind mount `./model-routing/routing.json` (`chmod 644`) — fully isolated from the named volume that holds keys, which `../switchboard/` consumes via a read-only mount of the same host directory. After each write it also proactively pings `POST http://switchboard:8091/refresh` (both containers are on the `proxy` network, reached directly by container name; a failure only logs and doesn't affect the main flow). Each of the three ccr toggles' `on.sh`/`status.sh` reads its values from this file by its own profile id.

For each profile you create in the ccr panel, set up the corresponding `on.sh`/`status.sh`: **choose `Only opened from CCR` for Effect Scope** (don't pick `System default` — with multiple profiles selecting it they'd fight over writing the same Claude Code global settings.json, and the last one created overwrites the previous). Full background and three real gotchas hit along the way (a read-only connection self-triggering an `fs.watch` loop, `console.log` polluting ccr's own nginx config generation, and `/refresh`'s synchronous blocking disguising "slower" as "failed"): `docs/misc/2026-08-20-ccr-third-party-model-compat-lessons.md`.

**Only the last hop of the sync chain isn't automatic**: ccr panel save → `routing.json` update + push notification to switchboard (millisecond-level; on push failure the fallback is opening the page or the 30s poll) → each group's `.env` syncs immediately → but a claude process already running only reads the new env vars when a new session is opened (a direnv limitation, see gotcha #3 in "Four gotchas" above). `../switchboard/app.py`'s `POST /refresh` is the receiving end of this notification chain — on receipt it runs `config.scan_all(...)` once in a background thread (the same function the page load triggers) and returns immediately, so it doesn't block the notifier.

## Outgoing tool-schema sanitiser (sanitize-tool-schema.cjs)

DeepSeek's request validator rejects a JSON-Schema `pattern` that uses the `\0` escape, and rejects it by **refusing the whole request with a 400**:

```
400 Invalid schema for function 'Artifact': {"type":"string","minLength":1,
"maxLength":1024,"pattern":"^[^\\0]*$"} is not valid under any of the schemas
listed in the 'anyOf' keyword
```

`\0` is a legal regex escape for NUL, but DeepSeek's validator does not accept it — while `\u0000`, which means exactly the same thing, it does. Claude Code's `Artifact` tool ships that pattern on `file_paths.items` in its richer variant, and that variant is frozen into a session's prompt snapshot when the session is created. The result is a session that cannot talk to DeepSeek **at all**, while a freshly created session works: the old session keeps sending the old tool schema, the new one never had the offending field. (This is also why an upgrade of ccr does not help — the incompatibility is in the tool schema, not in ccr.)

`sanitize-tool-schema.cjs` rewrites that one escape on the way out. Provider requests do **not** go through `globalThis.fetch` — the only such call the gateway makes is its own `/__ccr/raw-trace-sync` upload — so the middleware hooks undici's `Dispatcher.dispatch`, where the body arrives as an `AsyncGenerator` of chunks; `fetch` is wrapped too, as defence in depth.

**Scope: it only ever rewrites `pattern` values on tool definitions** — `tools[].input_schema` (Anthropic shape) and `tools[].function.parameters` (OpenAI shape). A `\0` in message text, a system prompt, or a tool description is left exactly as it is; rewriting those would silently alter conversation content, and this middleware sits in front of *all* provider traffic. The body is buffered (bounded) so it can be parsed as a whole, and re-serialised only when something actually changed.

**It also drops `content-length` and `content-encoding`** from the outgoing headers, because the body gets longer (3 → 7 bytes per escaped `\0`) and any length the caller had computed would be stale — the same reasoning `sse-coalesce.cjs` applies to the response side.

Anything unexpected makes it fall back to forwarding the original bytes untouched: an unparseable body, an unknown chunk type, a body over the cap, an error of any kind. Binary content types (multipart / octet-stream / image / audio / video) are never touched. `\0` followed by a digit is left alone — that would be an octal escape.

Diagnostics live behind three env vars (set them on the compose `environment:` when debugging; the first two are off by default):

| Env var | Effect |
|---|---|
| `CCR_SCHEMA_SANITIZE=0` | Disable the middleware entirely |
| `CCR_SCHEMA_SANITIZE_DEBUG=1` | Log the outgoing header list on each rewrite, and a per-request summary |
| `CCR_SCHEMA_SANITIZE_MAX_BYTES` | Buffer cap (default 64 MiB); a larger body is forwarded untouched |

`docker logs ccr \| grep sanitize-tool-schema` shows one `rewrote N pattern value(s)` line per rewritten request. Editing the `.cjs` needs `docker compose up -d --force-recreate` for the same reason as `sse-coalesce.cjs`: `--require` is only read at process start.

Run the unit tests with `node vps_oracle/compose/ccr/sanitize-tool-schema.test.cjs` — they cover the scope rule (prose untouched), chunk-boundary reassembly from 1 byte up, binary content types, octal escapes, the size cap, and stdout cleanliness.

## CCR admin panel (change routing / add provider / generate client key)

Two routes in:

- **NPM reverse proxy**: `https://ccr.jerome.cloudns.asia` (this is the `CCR Admin` card on homepage), `access_list_id=1` (`self-only`: only allows the 3x-ui container IP `172.19.0.2` and the server's own public egress IP) blocks ordinary public visitors. Log in with the value of `CCR_WEB_AUTH_TOKEN` in `.env`.
- **SSH tunnel** (the fallback path when not going through 3x-ui):

  ```bash
  ssh -L 3458:127.0.0.1:3458 <server>
  # Then open http://127.0.0.1:3458 in a local browser and log in with the value of
  # CCR_WEB_AUTH_TOKEN in .env
  ```

> Before 2026-08-10 there was no separate NPM reverse proxy for the CCR admin panel: the in-container nginx:8080 served both `/v1/*` (the model gateway) and `/` (the admin panel) on one port, so reverse-proxying it would have also exposed the model gateway to the public domain. We later decided to wire it up anyway — using `self-only` to block ordinary public visitors the same way as the repo's other admin panels (npm itself, portainer, grafana...); all that's exposed is the mere existence of the domain, not unrestricted access.

## CCR's NPM reverse proxy (reproducible)

Same standard setup as switchboard: attach to the `proxy` network, and NPM reverse-proxies via the container name `ccr:8080` (**not** the host ports 3456/3458 — NPM and ccr are both on the `proxy` network, using Docker's built-in DNS, so you use the container name + the container's internal port directly), access list=`self-only`, HTTPS uses a Let's Encrypt certificate obtained by NPM itself:

```bash
cd ../npm && source .npm-automation.env
docker run --rm --network proxy curlimages/curl:latest sh -c "
TOKEN=\$(curl -sS -X POST http://npm:81/api/tokens -H 'Content-Type: application/json' -d '{\"identity\":\"\$NPM_AUTOMATION_EMAIL\",\"secret\":\"\$NPM_AUTOMATION_PASSWORD\"}' | sed -n 's/.*\"token\":\"\([^\"]*\)\".*/\1/p')
# 1. Create the certificate first
curl -sS -X POST http://npm:81/api/nginx/certificates -H \"Authorization: Bearer \$TOKEN\" -H 'Content-Type: application/json' -d '{\"provider\":\"letsencrypt\",\"nice_name\":\"ccr.jerome.cloudns.asia\",\"domain_names\":[\"ccr.jerome.cloudns.asia\"],\"meta\":{\"letsencrypt_email\":\"jeromefromcn@gmail.com\",\"letsencrypt_agree\":true,\"dns_challenge\":false}}'
# 2. Then create the proxy host (replace certificate_id with the id from the previous step; access_list_id=1 is self-only)
curl -sS -X POST http://npm:81/api/nginx/proxy-hosts -H \"Authorization: Bearer \$TOKEN\" -H 'Content-Type: application/json' -d '{\"domain_names\":[\"ccr.jerome.cloudns.asia\"],\"forward_scheme\":\"http\",\"forward_host\":\"ccr\",\"forward_port\":8080,\"certificate_id\":<id>,\"ssl_forced\":true,\"http2_support\":true,\"block_exploits\":true,\"allow_websocket_upgrade\":true,\"access_list_id\":1,\"caching_enabled\":false,\"locations\":[],\"meta\":{\"letsencrypt_agree\":false,\"dns_challenge\":false}}'
"
```

## switchboard's NPM reverse proxy (reproducible)

switchboard uses the standard setup for every NPM-reverse-proxied service in the repo: attached to the `proxy` network, NPM reverse-proxies via the container name `switchboard:8091`, access list=`self-only`, HTTPS uses a Let's Encrypt certificate obtained by NPM itself. One-time creation (the full pattern for token exchange + proxy host creation is in `../npm/README.md`):

```bash
cd ../npm && source .npm-automation.env
docker run --rm --network proxy curlimages/curl:latest sh -c "
TOKEN=\$(curl -sS -X POST http://npm:81/api/tokens -H 'Content-Type: application/json' -d '{\"identity\":\"\$NPM_AUTOMATION_EMAIL\",\"secret\":\"\$NPM_AUTOMATION_PASSWORD\"}' | sed -n 's/.*\"token\":\"\([^\"]*\)\".*/\1/p')
# 1. Create the certificate first (HTTP-01 challenge; DNS already has a *.jerome.cloudns.asia wildcard)
curl -sS -X POST http://npm:81/api/nginx/certificates -H \"Authorization: Bearer \$TOKEN\" -H 'Content-Type: application/json' -d '{\"provider\":\"letsencrypt\",\"nice_name\":\"switchboard.jerome.cloudns.asia\",\"domain_names\":[\"switchboard.jerome.cloudns.asia\"],\"meta\":{\"letsencrypt_agree\":true,\"dns_challenge\":false}}'
# Note the returned id (used as certificate_id below)
# 2. Then create the proxy host (replace certificate_id with the id from the previous step; access_list_id=1 is self-only)
curl -sS -X POST http://npm:81/api/nginx/proxy-hosts -H \"Authorization: Bearer \$TOKEN\" -H 'Content-Type: application/json' -d '{\"domain_names\":[\"switchboard.jerome.cloudns.asia\"],\"forward_scheme\":\"http\",\"forward_host\":\"switchboard\",\"forward_port\":8091,\"certificate_id\":<id>,\"ssl_forced\":true,\"http2_support\":true,\"block_exploits\":true,\"allow_websocket_upgrade\":true,\"access_list_id\":1,\"caching_enabled\":false,\"locations\":[],\"meta\":{\"letsencrypt_agree\":false,\"dns_challenge\":false}}'
"
```

> Why `forward_host` is the container name `switchboard` rather than an IP: switchboard and NPM are both on the `proxy` network, and docker's built-in DNS resolves container names. Only host-level services like k3s NodePort need the host's internal IP `10.0.0.95` (see the "reverse-proxying to k3s NodePort" gotcha in the root README).
>
> The old `provider.jerome.cloudns.asia` proxy host and certificate need to be manually deleted/deactivated in NPM after the NPM reverse proxy switch to switchboard is complete (there's no record of the corresponding delete API call in the repo).

## provider-switch → switchboard first-deploy handoff checklist

After `provider-switch` was renamed/rewritten to `switchboard`, a few one-time manual wrap-up items remain:

1. **Copy `.env` first**: `vps_oracle/compose/provider-switch/.env` (gitignored, holds `CCR_CLIENT_TOKEN`) won't automatically show up at `vps_oracle/compose/switchboard/.env` from a `git mv` — copy it manually before deploying, otherwise `docker compose up -d --build` will fail outright because of the missing `env_file`.
2. **Clean up old containers/images after the switch**: the `provider-switch` container and image won't disappear on their own — after `docker compose -p provider-switch down`, confirm the old image is also removed in `docker images`; the leftover `.env` and `__pycache__/` under the old directory are orphaned files, delete them together.
3. **Clean up old lock files**: `/home/ubuntu/.claude-provider/jerome.env.lock`, `/home/ubuntu/.claude-provider/bridget.env.lock` (the old `status.py` put the lock at `env_path + ".lock"`) are no longer used after switching to switchboard — the new engine's locks go to `LOCK_DIR` (default `/tmp/switchboard-locks`). These two old files are orphaned and can be deleted manually.