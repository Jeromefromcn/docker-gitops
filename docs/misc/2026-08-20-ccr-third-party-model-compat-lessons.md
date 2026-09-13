# Three gotchas of plugging third-party models into CCR: Anthropic passthrough returns empty + opus/sonnet/haiku tiered routing not taking effect + three hidden pitfalls of the NODE_OPTIONS injection script

- Date: 2026-08-20
- Trigger scenario: the user newly purchased a Volcano Engine Ark / Byteplus coding plan and plugged it in via ccr (claude-code-router v3.0.20); messages frequently "sent with no response"; later, to make opus/sonnet/haiku tiered routing take effect, a "ccr panel as the single source of truth" architecture rework was done; finally upgraded from "self-heals only when the page is opened" to "ccr actively pushes a notification after saving"
- Repo changes involved: `vps_oracle/compose/ccr/{docker-compose.yml,export-model-routing.cjs,model-routing/}`, `vps_oracle/compose/switchboard/{app.py,docker-compose.yml,.env,.env.example}`, `vps_oracle/compose/switchboard/switches/{jerome,bridget,evidence}-ccr/{on.sh,status.sh}`
- Positioning of this doc: not a timeline of one specific incident (see `docs/incidents/` for that style), but a lessons-learned summary of the task of plugging in third-party models, for direct reference when adding a new provider / debugging similar issues later

## Conclusion first

1. **In ccr, any provider that is not the official Anthropic must have its protocol set to `OpenAI Chat` (`openai_chat_completions`), never `Anthropic Messages` (`anthropic_messages`).** Passthrough mode is currently unsafe for all third parties tested (DeepSeek official, Volcano Engine Ark).**
2. **The opus/sonnet/haiku tiered routing relies on the `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` environment variables that the Claude Code CLI itself recognizes — not the ccr gateway auto-detecting the model name in the request to route.** Without these three environment variables, switching models (`/model opus` etc.) is a no-op on the ccr path; it always hits the default `model` in the profile. To give the three directories (jerome/bridget/evidence) their own config, you must create three independent profiles in the ccr panel (each bound to its own token), not share one — see gotcha #2 "final solution".
3. Changing ccr config (provider `type`, profile `opusModel`, etc.) **does not guarantee hot reload**; a running gateway process caches config in memory. When unsure whether a change took effect, `cd vps_oracle/compose/ccr && docker compose restart` is the least effort.
4. The provider "preset templates" built into ccr (e.g. the "Byteplus" one) may have wrong/incomplete endpoint paths (`source: "preset"` rather than `"detected"`) — when adding a provider, prefer a method that actually probes connectivity (check Auto detect protocols, or manually fill a custom provider so ccr goes `detected`), don't unconditionally trust presets.
5. **Injecting a `NODE_OPTIONS --require` script into the ccr container: use only `console.error` (never `console.log`), never let `fs.watch` include `config.sqlite-wal`/`-shm`, and never make cross-container notification a synchronous blocking call.** All three are pitfalls that actually took down / stalled the system this time — details in gotcha #3. Always validate changes to this kind of script against a copy of the volume (`docker volume create` + `cp -a`) in an isolated environment first, never trial-and-error directly on the live container.
6. **The model name Claude Code displays cannot be customized.** For `ANTHROPIC_DEFAULT_OPUS_MODEL` etc., as long as the value is not an official model name the CLI natively recognizes, the model picker just displays the string verbatim (with a line of small text like "Custom Opus model" explaining the tier). Checked `--help`/`settings`/`config` — no relevant switch; most likely an intentional transparency design (does not want third-party models to be silently disguised as official Opus/Sonnet), not something configureable away.

## Gotcha #1: Anthropic Messages passthrough, third-party model returns empty

### Symptom

CC sends a message and gets no response for a long time; the second message in the same session is normal again. ccr's own request logs show 200/success.

### Root cause

A recent Claude Code version (2.1.237 this time) added a private beta feature — `mid-conversation-system` (request header `anthropic-beta: ...mid-conversation-system-2026-04-07...`). When this feature is hit, the CLI in the **first turn of the session** wraps the extra context injected by hooks (SessionStart etc.) as an entry in the `messages` array:

```json
{"role": "system", "content": "..."}
```

This is illegal in the standard Anthropic Messages API — `system` can only be a top-level field, not a role inside the `messages` array.

The "Anthropic-compatible" endpoints offered by third-party models (verified this time against DeepSeek's own official `/anthropic/v1/messages`, and Volcano Engine Ark reselling the same DeepSeek model) are just **thin shells added later** to let tools like Claude Code integrate; they haven't kept up with this new beta. When the shell sees this illegal message it **does not error, does not ignore, but returns a "success" response that is completely empty** (`200 OK`, `output_tokens: 0`, `content` empty string). ccr faithfully forwards this "success" response — from ccr's perspective there is genuinely nothing abnormal to report.

The second message in the same session does not re-trigger hook injection, carries no illegal message, so it responds normally — this is the origin of "first message no response, second normal".

### Why switching to OpenAI Chat fixes it

The **native, first-party** interface for DeepSeek-family models is the OpenAI Chat Completions format (`/v1/chat/completions`) — the Anthropic-compatible shell is just an add-on. The OpenAI format spec legitimately allows `role: "system"` to appear anywhere in the `messages` array (multiple allowed), which is fully legal. When ccr selects `openai_chat_completions`, it **converts** the Anthropic-format request into OpenAI format before sending; that originally "non-compliant" message translates into a legal form, and the model processes it normally via its most mature native interface.

When `anthropic_messages` is selected, ccr **passthrough** (no conversion, forwards as-is); the illegal message is passed verbatim to that fragile compat shell and gets swallowed.

### Debugging method on record

Logs alone can't reveal why the content is empty — ccr's `request-logs.sqlite` defaults `requestLogBodyCapture: "errors"` (changed after the last incident fix; successful requests don't store body), and this config also doesn't hot-reload (same in-memory-cache pitfall).

What actually works: spin up a zero-dependency Node reverse proxy locally (code below), point `ANTHROPIC_BASE_URL` at it temporarily, run `claude -p "hi"` once, and you get the full request body the CLI actually sends and the raw SSE bytes ccr actually returns — without touching any shared-service config:

```js
// record_proxy.mjs — pure record-and-forward, does not modify any request/response
import http from 'node:http';
import { writeFileSync, appendFileSync } from 'node:fs';
const TARGET = 'http://127.0.0.1:3456';
const OUTDIR = process.env.RECORD_OUTDIR;
let counter = 0;
http.createServer(async (req, res) => {
  const id = ++counter, chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', async () => {
    const reqBody = Buffer.concat(chunks);
    writeFileSync(`${OUTDIR}/req_${id}.json`, reqBody);
    const upstream = await fetch(TARGET + req.url, {
      method: req.method, headers: { ...req.headers, host: undefined },
      body: ['GET','HEAD'].includes(req.method) ? undefined : reqBody, duplex: 'half',
    });
    res.writeHead(upstream.status, Object.fromEntries(upstream.headers));
    if (upstream.body) {
      const reader = upstream.body.getReader();
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        res.write(value);
        appendFileSync(`${OUTDIR}/resp_${id}.sse`, Buffer.from(value));
      }
    }
    res.end();
  });
}).listen(3999, '127.0.0.1');
```

```bash
mkdir -p /tmp/recorded
RECORD_OUTDIR=/tmp/recorded node record_proxy.mjs &
ANTHROPIC_BASE_URL=http://127.0.0.1:3999 ANTHROPIC_AUTH_TOKEN=$TOKEN claude -p "hi" --output-format json
# /tmp/recorded/req_N.json is the full request body the CLI actually sends (including system/tools/messages)
# /tmp/recorded/resp_N.sse is the raw SSE bytes the upstream actually returns
```

After getting the real request body, replay it verbatim with curl and ablate field by field (remove a field/header and send again) — far faster than guessing; this is how the scope was narrowed from "is the payload too big" to "it's that `role:system` message".

## Gotcha #2: opus/sonnet/haiku model switching, ccr does not route to the configured target

### Symptom

In the ccr admin panel `profile.claudeCode.opusModel` is clearly set to the big model (e.g. `deepseek-v4-pro`), but after switching `/model opus` in CC, the ccr gateway log's `resolved_model` is still the small model (`deepseek-v4-flash`) — as if nothing was switched.

### Root cause

ccr's "profile" mechanism is not the gateway parsing the `model` field itself after receiving the request to route. Its design: ccr converts the `opusModel`/`sonnetModel`/`haikuModel` config values into environment variables the Claude Code CLI **natively recognizes**:

```
ANTHROPIC_DEFAULT_OPUS_MODEL
ANTHROPIC_DEFAULT_SONNET_MODEL
ANTHROPIC_DEFAULT_HAIKU_MODEL
```

The values are ccr's own `provider/model` format (e.g. `byteplus/deepseek-v4-pro-ga-260813`). **Only after the CLI reads these three environment variables does it know "which model name the opus tier should actually send"**; it then sends that string verbatim as the `model` field to ccr, and the ccr gateway splits on `/` to get the target provider+model.

This repo's ccr switching mechanism (see `vps_oracle/compose/ccr/README.md`) deliberately uses only `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` for provider switching, and does not maintain the three model-tier variables — so the CLI has no idea which model name "opus" should send, and can only send its own default generic alias (e.g. `claude-opus-5`); for a string it has never seen and has no explicit mapping for, the ccr gateway falls back to the profile's fallback `model` field (i.e. flash).

### First fix (deprecated): hardcode in docker-compose

The initial approach hardcoded three values (`CCR_OPUS_MODEL` etc.) in `switchboard/docker-compose.yml`, and `on.sh` copied them straight into `.env`. **This approach was overturned**: after changing the model in the ccr panel, this hardcoded copy wouldn't follow, requiring manually going back to edit compose and `docker compose up -d --build` to rebuild — the ccr panel became a decoy. The correct approach is to keep the ccr panel as the single source of truth — see the final solution below.

### Final solution: three independent profiles + read-only summary file + self-heal

**1. Create three independent claude-code profiles in the ccr panel** (Jerome/Bridget/Evidence), each bound to its own client token; their `opusModel`/`sonnetModel`/`haikuModel` are configured separately in the ccr panel, not interfering with each other. Two fields need care when creating:

- **Effect Scope choose `Only opened from CCR`, not `System default`**: selecting the latter makes multiple profiles compete to write the same Claude Code global `~/.claude/settings.json`, with later ones overwriting earlier ones.
- **Entry Mode is fine either way** (only affects ccr's built-in "one-click open" convenience button, not API routing); for a pure terminal scenario choosing CLI only is more accurate.

Each token in the `api_keys` table is bound one-to-one as `id: "profile:<profile-id>"` — this is ccr's native mechanism for "each client has its own config", no need to invent our own.

**2. ccr itself exports a "safe summary", no sensitive data shared**

`config.sqlite` and its containing directory are `700 root:root` (holding all providers' raw API keys and the admin panel password), so other containers **can't mount and read it at all** (not unwilling, but unable at the permission level — verified by experiment).

So a new `vps_oracle/compose/ccr/export-model-routing.cjs` was added — same technique as `sse-coalesce.cjs`, mounted into every node process of the ccr container via `NODE_OPTIONS --require`. It reads only the four strings `model`/`opusModel`/`sonnetModel`/`haikuModel` from `profiles[]` (touching no key), and writes them to a separate, non-sensitive bind mount (`vps_oracle/compose/ccr/model-routing/routing.json`, `chmod 644`), completely isolated from the named volume holding keys. `switchboard/docker-compose.yml` read-only-mounts the same host directory to consume it.

Listener mechanism: `fs.watch` watches `config.sqlite` (**only the main filename, never also `-wal`/`-shm` — see gotcha #3 below**), with 500ms debounce + 30s fallback polling to avoid missing events.

**3. `on.sh`/`status.sh` read the three tier models from the summary file by their own profile id**

`on.sh` (at the moment of switching) and `status.sh` (**runs on every switchboard page load**, see the header note in `config.py` "nothing here is cached, by design") both read `routing.json`, take the three tier models for their respective profile id, and write them into `.env`. `status.sh` does self-heal on the side: as long as base_url shows "on", it compares the three lines in `.env` against the current `routing.json` values and rewrites them if inconsistent. `on.sh` only manages token/base_url at the moment of switching; tokens are per-group independent (`CCR_TOKEN_JEROME`/`CCR_TOKEN_BRIDGET`/`CCR_TOKEN_EVIDENCE` in `switchboard/.env`, gitignored, never in git).

**4. ccr actively pushes after saving, rather than waiting for switchboard to notice on its own**

The first version relied only on "opening the page triggers self-heal"; a real gap was found in practice: after changing the model in the ccr panel, until someone happens to open the switchboard page, `.env` stays at the old value — `routing.json` has long been updated, but no one tells switchboard to re-scan. Waiting tens of seconds, opening a new session and still getting the old model — that's hitting this gap.

The fix adds a push notification, with no new dependency on either side:

- `export-model-routing.cjs`, each time it finishes writing `routing.json`, POSTs `http://switchboard:8091/refresh` (ccr and switchboard are on the same `proxy` docker network, direct by container name; Node's built-in `fetch`, 2s timeout, failure only logs and does not affect the main flow — switchboard temporarily unreachable, the next real config change will notify again, and page self-heal remains the fallback).
- `switchboard/app.py` adds a generic `POST /refresh`: on receipt it runs `config.scan_all(...)` once in a **background thread** and returns immediately. This is the same function triggered by "someone opens the page", just a different trigger source — `app.py` does not need to know what routing.json is or who is notifying it; the generality is intact.

**A pitfall was hit here: `/refresh` was initially written to synchronously wait for `scan_all()` to finish before returning.** `scan_all` runs the `status.sh` of all 6 switches (3 ccr + 3 account), one of which includes a network probe; measured end-to-end 1.7 seconds — too close to ccr's 2-second notification timeout; slip a little and the notification is judged "failed" (the request itself actually succeeded, just slow). After changing to "return 202 immediately on receipt, throw the real scan into a background thread", response time dropped from 1.7s to a few milliseconds and the problem vanished. **Lesson: a cross-container "notification" endpoint must be fire-and-forget and return immediately; don't make the notifier wait for the notified to finish the heavy work.**

The sync chain is now three hops; the first two are automatic, only the last one can't be (see the diagram drawn in the conversation with the user above):
`ccr panel save → routing.json updated + push notification (millisecond-level; when both fail, fallback on page load/30s polling) → .env updated immediately → an already-running claude process must open a new session to read the new value` (the last hop is a direnv limitation, already on record in the repo README, not introduced this time).

### Verification

```bash
source /home/ubuntu/.claude-provider/evidence.env
claude -p "hi" --model opus   --output-format json | grep -o '"canonicalModel":"[^"]*"'
claude -p "hi" --model sonnet --output-format json | grep -o '"canonicalModel":"[^"]*"'
claude -p "hi" --model haiku  --output-format json | grep -o '"canonicalModel":"[^"]*"'
# should hit the opus/sonnet/haikuModel configured in the ccr panel for that group's profile, respectively
```

## Gotcha #3: three real pitfalls of injecting a `NODE_OPTIONS --require` script into the ccr container + cross-container notification

While writing `export-model-routing.cjs` (same technique as `sse-coalesce.cjs`), ccr was taken down twice; later, adding the push notification slowed the response speed to the point of "looking like a failure". Both earlier incidents were reproduced, located, and fixed in an isolated volume copy before being redeployed live. On record here so that next time, before injecting a similar script into this container or adding a cross-container notification, read this first.

### 3.1 A read-only connection itself touches `-wal`/`-shm`; `fs.watch` watching them is a self-triggering infinite loop

`config.sqlite` is WAL mode. Verified by experiment: **even just opening a `{readonly: true}` better-sqlite3 connection, querying once, and closing it causes `config.sqlite-wal`/`config.sqlite-shm` to appear out of thin air on disk** (these two files did not exist before the connection, and appear after). If `fs.watch` counts these two files as "config changed", then its own every read triggers the next read — infinite loop, CPU/IO pegged within seconds, ccr becomes unreachable (connection reset on port).

Also verified: **a real write (`UPDATE` + close connection) triggers a checkpoint, and the main file `config.sqlite`'s mtime genuinely changes**, while a pure read-only connection does not touch the main file. So watching only the main filename (`filename === "config.sqlite"`, not `startsWith`) gets both: your own reads don't self-trigger, real saves are still captured, and the 30s fallback polling backstops it.

Reproduce/fix method: **always experiment on a copy of the volume via `docker volume create` + `cp -a` first**, never trial-and-error on the live container — this time both incidents were fixed in the copy first, then redeployed live with `docker compose up -d`, so the live container never went down a second time during the whole process.

### 3.2 A `--require` script must never use `console.log` (stdout), only `console.error` (stderr)

ccr's own entrypoint runs a node child process to generate the admin panel token, **capturing that child process's stdout verbatim and embedding it directly into the generated nginx config file** (`return 302 ...?ccr_web_token=<here>`). Any `--require` script that prints anything to stdout, and happens to be loaded in the node process doing that token generation, gets its output mixed into the middle of the token string, turning the nginx config into a syntax error — `ccr-nginx` crash-loops repeatedly and the whole gateway is unusable.

`sse-coalesce.cjs` used only `console.error` from the start and never hit this; `export-model-routing.cjs` initially used `console.log` and immediately blew up, then the problem vanished after switching to `console.error`. **Conclusion: any `NODE_OPTIONS --require` script in the container should use only `console.error`, never `console.log`** — when unsure whether a given log line might be parsed downstream as "command output", defaulting to stderr is safest.

### 3.3 A cross-container "notification" endpoint that blocks synchronously disguises "slow" as "failed"

When adding "notify switchboard after writing" to `export-model-routing.cjs`, the first version of `switchboard/app.py`'s `POST /refresh` was synchronous: on receipt it first ran `config.scan_all()` (all 6 switches' `status.sh`, one including a network probe) to completion before returning, measured 1.7s end-to-end. The notifier's client timeout is 2 seconds — the two numbers are too close; slip a little and the notification is judged timed out by `AbortSignal`, and the logs are full of `switchboard notify failed`, looking like the link is broken, while in fact the request itself was fine, just **deliberately made the response slow**.

Fix: `/refresh` returns `202` immediately on receipt, and the real `scan_all()` is thrown into a background thread (`threading.Thread(daemon=True).start()`). Response time dropped from 1.7s to a few milliseconds, and the false alarms vanished. **Conclusion: for any "A notifies B that something happened" endpoint, B should only "acknowledge receipt" and answer immediately, throwing the real heavy work to the background — don't bind the notifier's response time to the notified party's internal work duration; they are two different things.**