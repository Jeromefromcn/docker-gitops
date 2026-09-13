# VS Code Claude Code extension "stall" — investigation and fix record

- Date: 2026-08-15 (early morning UTC+8)
- Environment: VS Code Remote-SSH connecting to an Oracle Linux server, Claude Code switching to a third-party provider via ccr (claude-code-router v3.0.20, self-built Docker image)
- This record: captures the full process from symptom to fix, the pitfalls hit along the way, the evidence data, and process PIDs for later review. **Contains no API keys** (keys are in the container's `/data/.claude-code-router/config.sqlite` and in the `.env` in the same directory as `docker-compose.yml`).

---

## 1. Background and symptoms

Another topic ("planning an 8-day Hong Kong to Malaysia trip") was running in the VS Code extension, and the user observed:

- The session had actually long finished (the user's self-installed `claude-code-notify` hook sent its notification **on time**), but the extension still showed "executing";
- After a while it would **slowly spit out** some old output, and only much later did the extension display CC's question (the ExitPlanMode approval request);
- In the terminal it worked fine; the extension also worked fine with Claude's official model;
- Only the "extension + ccr/third-party provider" combination stalled.

Key clue: **notification on time, UI extremely slow** → not event loss / handshake failure, but **backlog in the pipe, delivered late in order**.

## 2. Investigation (evidence chain)

### 2.1 Stalled session / process snapshot

| Item | Value |
|---|---|
| PID of the stalled extension claude process | 3180047 (parent process exthost 3177808, started around 15:38 local) |
| cwd of that process | `/home/ubuntu/jerome/plans` |
| session transcript | `~/.claude/projects/-home-ubuntu-jerome-plans/972cd377-e7d0-40fb-bc00-8d770f92ffd4.jsonl` |
| another extension session process | 3536341 (cwd `/home/ubuntu/bridget/love-bird-op`) |
| this investigation session (terminal) process | 3743504 |
| stalled process state | alive, S sleeping; **zero TCP connections, zero child processes** → not waiting on network/commands, purely waiting on a local handshake |

(PIDs change across restarts; this is just a snapshot at the time.)

### 2.2 transcript ending: the API response was actually complete

Last record `2026-08-14T16:28:43.970Z` (local 00:28):
- type=`assistant`, stop_reason=`tool_use`, usage complete, msg id `msg_20260815002842588c73b19c0b4bfe` (proxy format, not official);
- the tool to be called is **`ExitPlanMode`** (tool id `call_8fe91198ce904f01a07bea39`, OpenAI-style id — confirming it went through a third-party provider);
- **no `result` end event after it** → that round never ended from inside the CLI.

→ provider/ccr did not lose data; the stall point is after the CLI.

### 2.3 gateway request log: the provider side is not suspect

`/data/.claude-code-router/app-data/request-logs.sqlite` (this database records every request in full):

- that round's request with ExitPlanMode (id 747): created 16:28:42.304 → completed **16:28:44.018 (1.7s)**, 200, `att=1` (no retries), `sat=0` (no credential saturation);
- 186 records in the one-hour window, all 200;
- provider = `Zhipu AI (China) - Coding Plan` (`open.bigmodel.cn/api/anthropic`, anthropic_messages passthrough, no transformer).

### 2.4 Finding the trigger condition: per-token SSE event granularity

From the same request log, pulled the bodies of several streams (stored when capture policy=all):

| row | output_tokens | SSE delta event count | text_delta | avg bytes per event |
|---|---|---|---|---|
| 749 | 6400 | **6314** | 40 | ~135B (855KB total) |
| 745 | 3822 | 3803 | 68 | ~135B |
| 746 | 2877 | 2720 | — | ~135B |

- **almost one delta event per token** (~135B/event), and when thinking is enabled 99% are `thinking_delta` (only a few dozen text_delta).
- The official Anthropic API merges **multiple tokens** into large-block events, with an event rate 1-2 orders of magnitude lower.
- Next to it there are also the auto-mode classifier's small `glm-5.3` requests (non-streaming, out=64, one every 2-8 seconds); the extension-mode request volume is far larger than the terminal's.

### 2.5 Conclusion: the bottleneck is the CLI → extension →(SSH)→ webview segment

Combination matrix (the only variable = event granularity):

| Combination | Result |
|---|---|
| terminal + ccr | normal (local TUI rendering) |
| extension + official API | normal (coarse granularity) |
| **extension + ccr** | **backlog** (fine per-token granularity) |

Mechanism: the extension has to do JSON parsing + `postMessage` over the Remote-SSH tunnel to the local webview + re-render the entire conversation (expensive for long sessions) for every event, so consumption speed < production speed → stdout pipe (64KB) backpressure → CLI stuck on write → control messages (permission/ExitPlanMode requests) queued behind tens of thousands of events → hour-level delay. That line in the extension log — `claude-vscode notification channel error: Received a response for an unknown message ID: ... id:0` — is the side effect of the response arriving late and the CLI already dropping the request.

## 3. Pitfalls hit along the way (in time order)

1. **Initial judgment was "approval handshake lost"** → overturned by new information (notification early, output slowly spit out = backlog not loss).
2. **globalThis.fetch patch ineffective** → ai-gateway uses `require("undici")` then `getGlobalDispatcher().dispatch(...)`, not fetch.
3. **dispatcher-level patch still ineffective** → DeepSeek's provider fetch lands in **`server.js` (ccr-core-server)**, which does not load the preload; only the gateway child process carries `--require`.
4. **adding `NODE_OPTIONS` to compose still ineffective** → `--require` only **loads** the module, does not **call** install(); the module needs to self-start (see below).
5. **editing `/data/.../gateway-proxy-preload.cjs` to add a hook gets overwritten** → `server.js` rebuilds this file with an embedded copy via `writeFileSync` on every startup. The preload-editing approach is not viable.
6. **Zhipu hit the 5-hour quota cap** (`[1308] reached the 5-hour usage limit`, reset 05:22:05 UTC) → switched to DeepSeek to verify (the middleware is provider-agnostic).
7. Pitfalls in the test file itself: directly `JSON.parse`-ing a whole `data: {...}` record fails (must strip the `data:` prefix first); the fake consumer's onData return order was written backwards.

## 4. Architecture points (confirmed during investigation)

- Entry: host `127.0.0.1:3456/3458` → docker-proxy → **in-container nginx(8080)** → path-based routing to gateway(3456) / admin UI(3459).
- Container processes: PM2 manages two apps — `ccr-core-server` (`/app/packages/core/dist/main/server.js`, web+core, **some provider fetches are here**) and nginx; gateway is a child process spawned by server.js (`--require /data/.../gateway-proxy-preload.cjs` then `gateway-bootstrap.js` `require`s ai-gateway in the same process).
- ai-gateway: `/app/node_modules/@the-next-ai/ai-gateway/dist/index.js`, uses `undici.getGlobalDispatcher()`.
- Config: `/data/.claude-code-router/config.sqlite` (`app_config` table, observability etc.); logs: `app-data/request-logs.sqlite` (+admissions/usage).
- Request-log body capture valid values: `all | errors | none | sampled`; has built-in daily retention (`DELETE FROM request_logs WHERE source_usage_id IS NULL AND created_at < threshold`).

## 5. Fix

### 5.1 SSE delta coalescing middleware `sse-coalesce.cjs`

File location (**committed to the repo**): `vps_oracle/compose/ccr/sse-coalesce.cjs`, read-only mounted into the container at `/data/.claude-code-router/sse-coalesce.cjs` (core does not recognize this new file, won't overwrite it; the repo version is the single authority).

Design:
- **Interception layer**: undici `Dispatcher.dispatch` handlers (onHeaders/onData/onComplete), and also patch `globalThis.fetch` and `undici.fetch` as a fallback.
- **Coalescing rule**: only coalesce `content_block_delta` with a string payload (`text_delta→text` / `thinking_delta→thinking` / `input_json_delta→partial_json`); only coalesce consecutive, same-index, same-type; on a 40ms window (`CCR_SSE_COALESCE_MS`) expiry or on any other event (content_block_start/stop, message_delta, message_stop, etc.), flush as one event (payload concatenated). Preserves order and protocol boundaries.
- **ping**: dropped by default (`CCR_SSE_DROP_PINGS=0` to disable), letting coalescing span across keep-alive.
- **compression**: forces request header `accept-encoding: identity`; if the response still carries content-encoding, bypass the whole thing (do not decompress and re-slice, to avoid corruption).
- **content-length**: stripped after coalescing (SSE is chunked anyway).
- **backpressure**: when downstream onData returns false, pause the queue; resume on continue.
- **stats**: `/data/.claude-code-router/sse-coalesce-stats.log`, auto-truncated and rolled over at 256KB.

### 5.2 Loading mechanism (final form)

`docker-compose.yml`:
- `NODE_OPTIONS: "--require /data/.claude-code-router/sse-coalesce.cjs"` — makes **all** node processes in the container load it;
- the module **self-invokes `install()` when loaded** (idempotent), so `--require` takes effect directly, with no dependency on any preload hook.

### 5.3 Log volume reduction

- `observability.requestLogBodyCapture: "all" → "errors"` (only store the body on failure).
- Wiped the bodies of historical successful requests + `VACUUM` + `wal_checkpoint(TRUNCATE)`: `request-logs.sqlite` **156MB → 12MB**.

## 6. Verification results

- Unit tests: all 9 pass (coalescing, content-length, backpressure, compression bypass, cross-index no-merge, ping drop).
- Live test (DeepSeek streaming): a 200-token response's delta events went **85 → 7**; stats recorded `merge in=85 out=11`; response ended normally with `message_delta` + `message_stop`.
- The Zhipu path could not be retested due to the quota (the middleware is provider-agnostic, and DeepSeek already proved end-to-end effectiveness).

## 7. Remaining issues / follow-up

- The extension itself — "slow UI rendering should not stall the protocol channel; should batch-render stream events" — is still an upstream defect, worth reporting to github.com/anthropics/claude-code (attach this case's event-granularity data).
- Committed: c0f970c (`docker-compose.yml`'s `NODE_OPTIONS` + bind mount + new `sse-coalesce.cjs`).
- Container rebuilt and in effect; the image rebuild is equally effective (env in repo, middleware in /data volume + read-only mount).
- Postscript (2026-08-15): the session accumulation caused by this bug triggered a server resource spike the same morning (4-core machine, 5-minute load average 38.7); investigation and handling are in this directory's [2026-08-15-vscode-sessions-resource-spike.md](2026-08-15-vscode-sessions-resource-spike.md).

## 8. Common commands (for review)

```bash
# Find the stalled extension claude process / see what it is waiting on
ps aux | grep vscode-server.*claude
readlink /proc/<pid>/cwd
ps --ppid <pid>; ss -tnp | grep <pid>

# Check whether a session transcript's ending is complete (missing "result" line = that round didn't finish)
tail -n 3 ~/.claude/projects/<dir>/<session>.jsonl | python3 -m json.tool --json-lines

# gateway request log (includes event granularity / duration)
docker exec ccr node -e '...sqlite...'

# middleware stats / status
docker exec ccr cat /data/.claude-code-router/sse-coalesce-stats.log
docker exec ccr sh -c 'echo $NODE_OPTIONS'

# Tune window / disable the middleware
# after changing compose env vars: docker compose up -d
#   CCR_SSE_COALESCE_MS=0  → disabled; CCR_SSE_COALESCE_MS=100 → larger window
```

## 9. Postscript 2 (same afternoon): coalescing-window tuning, coalescing rate 3-5x → 23x

After the fix was deployed the hour-level stall disappeared, but a residual symptom remained: claude-code-notify push arrived on time, while the extension still showed the question options ~3 minutes late (a few tens of minutes before the fix).

### 9.1 Locating the issue: bottleneck position unchanged, the coalescing rate was insufficient

Using an AskUserQuestion at 12:57 (HKT) on 2026-08-15 as evidence (oss-devrel session `d1694d49`):

- in the transcript, AskUserQuestion landed at **04:57:08.748Z**, matching the push time 12:57:08 to the second → provider→ccr→CLI has zero delay end-to-end;
- the next assistant record at 05:01:27Z → **~3 minutes entirely spent on the extension side digesting the backlog**: after coalescing, the last two responses of that round still left ~534 events (stats `out=419` + `out=115`) × ~250-400ms/event;
- full sampling of stats: the actual coalescing rate at a 40ms window was only **3-5x** (`in=3900 out=454`, `in=1893 out=495`). Reason: Zhipu emits one delta per token at 25-50ms intervals, so a 40ms window often only catches 1-2, still 1-2 orders of magnitude off from the official API granularity.

### 9.2 Changes (commit b3046bb)

1. Global window 40→200ms (compose `CCR_SSE_COALESCE_MS`);
2. `sse-coalesce.cjs` supports per-type windows: `CCR_SSE_COALESCE_THINKING_MS=500` (thinking_delta accounts for ~99% of events and its display smoothness doesn't matter), `_TEXT_MS=120`, `_INPUT_JSON_MS` (falls back to global if unset). **per-type unset or ≤0 always falls back to global** — a per-type alone may not be 0, otherwise there is no flush timer and data would be held until stream end; `CCR_SSE_COALESCE_MS=0` remains the overall-disable rollback switch. The coalescer is still a single pending slot + single timer order-preserving design, just that the timer duration is resolved per the pending delta type (`makeWindowResolver`);
3. the stack README adds the "SSE coalescing middleware" doc section, including one gotcha: **editing the `.cjs` content does not trigger a container rebuild** (bind mount does not participate in hashing), while `--require` only loads at process startup — must `docker compose up -d --force-recreate`.

A one-off verification script (19 assertions: coalesced payload == concatenation, thinking/text/stop order, ping drop, index switch immediate flush, backpressure pause/resume, fallback semantics) all passed; the script was left at `/tmp/test-coalesce-pertype.cjs` (not committed to the repo).

### 9.3 Results and remaining

- Live test after deployment: `in=719 out=31` (~23x), `in=337 out=14` (~24x), reaching the ≥15x target;
- To observe: next extension AskUserQuestion, push→options should pop up in seconds;
- The ceiling is still the extension's per-event re-render (upstream defect): locally one can only get closer by reducing the event count. For long sessions, a timely `/compact` also lowers per-event cost.
- Reported upstream: anthropics/claude-code issue [#86854](https://github.com/anthropics/claude-code/issues/86854) (2026-08-15 14:21 HKT); the report body, dedup result, and the #81425 comment draft are in `../misc/2026-08-15-upstream-report-claude-vscode-sse-rendering.md`.

## Appendix: full file list of this fix

- Repo: `vps_oracle/compose/ccr/sse-coalesce.cjs`, `vps_oracle/compose/ccr/docker-compose.yml`
- Container volume `/data/.claude-code-router/`: `sse-coalesce.cjs` (read-only mount), `sse-coalesce-stats.log` (runtime, in the volume)
- Backup: `/data/.claude-code-router/gateway-proxy-preload.cjs.bak-20260815` (stock original, kept for comparison)