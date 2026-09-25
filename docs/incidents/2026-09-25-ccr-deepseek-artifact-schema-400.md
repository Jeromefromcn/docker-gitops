# Resuming an older Claude Code session on the DeepSeek route 400s on every turn: DeepSeek's validator rejects the `\0` escape in a tool `pattern`, and the offending Artifact schema is frozen into the session

- Date: 2026-09-25
- Environment: `vps_oracle`, ccr stack (`claude-code-router:3.1.1`, Claude Code CLI 2.1.280 via `claude-vscode`), provider `deepseek::anthropic_messages` (`deepseek-flash`), group `jerome` (session in `~/jerome/docker-gitops`)
- Symptom: after switching the group's backend to ccr/DeepSeek, continuing a session that had originally run on a Claude model failed every turn with `API Error: 400 All target providers failed.` Opening a new session in the same directory worked fine. Upgrading ccr from v3.0.20 to v3.1.1 did not help
- Fix: added `vps_oracle/compose/ccr/sanitize-tool-schema.cjs`, a `NODE_OPTIONS --require` preload that rewrites the `\0` escape in outgoing tool-schema `pattern` values to the equivalent `\u0000`

---

## 1. Conclusion first

**The root cause is the tool schema the session sends, not the session history and not ccr.** DeepSeek's request validator refuses JSON-Schema `pattern` values that use the `\0` escape, and refuses them by rejecting the whole request:

```
Invalid schema for function 'Artifact': {"type":"string","minLength":1,"maxLength":1024,
"pattern":"^[^\\0]*$"} is not valid under any of the schemas listed in the 'anyOf' keyword
```

`\0` is a legal regex escape for NUL, and `\u0000` means exactly the same thing — but only the long form is accepted.

Why only old sessions hit it: Claude Code's `Artifact` tool exists in two variants, and the richer one carries `file_paths.items.pattern = "^[^\0]*$"`. The variant a session gets is **frozen into that session's `prompt_snapshot`** when the session is created and re-sent on every resume. A session created while the richer variant was in play therefore keeps sending it forever, no matter which provider it is pointed at afterwards. A session created later never has the field, so it works — which is exactly the "new session is fine" symptom.

**A ccr upgrade cannot fix this**, because the incompatibility is in the request payload the client sends, not in ccr.

## 2. Evidence chain

### 2.1 The 400 is recorded with its body

ccr's `requestLogBodyCapture` policy is `"errors"`, so failed requests keep their bodies. Reading them out of the container:

```bash
docker exec -e NODE_PATH=/app/node_modules ccr node -e '...'
# provider            requested_model            status  req_bytes
# deepseek::anthropic_messages  deepseek-flash    400     966550
# response_body_text:
#   {"error":{"message":"Invalid schema for function 'Artifact': {\"type\":\"string\",
#    \"minLength\":1,\"maxLength\":1024,\"pattern\":\"^[^\\\\0]*$\"} is not valid
#    under any of the schemas listed in the 'anyOf' keyword ...
```

The stored `request_body_text` is a head+tail *preview* (`... 802710 bytes omitted from preview ...`), so the tool array is not visible there — that needs the capture below instead.

### 2.2 Minimal ablation: the trigger is the `\0` escape and nothing else

Posting a small request straight at the gateway (`http://127.0.0.1:3456/v1/messages`), varying only the tool schema:

| property schema | result |
|---|---|
| `{"type":"string","minLength":1,"maxLength":1024,"pattern":"^[a-z]*$"}` | 200 |
| `{"type":"string","minLength":1,"maxLength":1024}` | 200 |
| `{"type":"string","pattern":"^\\w+$"}` | 200 |
| `{"type":"string","pattern":"^[^\\d]*$"}` | 200 |
| `{"type":"string","pattern":"^[^\\u0000]*$"}` | 200 |
| `{"type":"string","pattern":"^[^\\0]*$"}` | **400** |

So it is not `pattern`, not `minLength`/`maxLength`, and not backslash escapes in general — only `\0`.

> Lesson worth keeping: the first version of this table came out wrong because a heredoc quoted with `<<'SH'` plus shell single-quotes turned `\\\\0` into four backslashes, i.e. a *different* regex (`[^\\0]` = "not backslash and not zero"). Always confirm the bytes that actually went out — a passing probe proves nothing if it did not carry the bytes you meant.

### 2.3 Where the offending schema comes from: the session's own prompt snapshot

Claude Code writes a `prompt_snapshot` attachment into each session `.jsonl`, holding the system prompt and the **tools** used. Comparing the failing session with a fresh, working one:

| | fresh session (works) | old session (400s) |
|---|---|---|
| tools in snapshot | 29 | 12 (+ `ToolSearch`) |
| `Artifact` properties | action, file_path, favicon, icon, files, root, … | plus **`asset`, `file_paths`, `from_url`, `asset_ids`** |
| `pattern` with `\0` | none | `file_paths.items.pattern = "^[^\0]*$"` |

Sweeping every `prompt_snapshot` on the machine shows the split is systematic rather than a one-off:

```
2.1.276|claude-vscode|rich=true |tools=12     ← 12-tool / deferred-tools mode → has the field
2.1.281|claude-vscode|rich=true |tools=12
2.1.282|claude-vscode|rich=true |tools=12
2.1.281|claude-vscode|rich=false|tools=29     ← 29-tool mode → no such field
```

The snapshot is re-emitted on resume with its original content, so an old session keeps the old tool schema.

### 2.4 Reproduction, and the exact request

A recording proxy (the method from `docs/misc/2026-08-20-ccr-third-party-model-compat-lessons.md`) captured the real request the resumed session sends: **968,376 bytes**, 26 tools, 598 messages, 0 content blocks carrying a `signature`. Scanning every `pattern` in it:

```
!! 含 \0   tools[1].input_schema.properties.file_paths.items.pattern = "^[^\\0]*$"
           tools[1].input_schema.properties.asset_ids.items.pattern = "^[0-9a-f]{32}$"
           tools[3].input_schema.properties.writes.items.properties.collection.pattern = "^(?!\\.\\.?(?:\\/|$))..."
           tools[19].input_schema.properties.to.allOf[0].pattern = "^[^\\n\\r]*$"
           ...
```

Exactly one of the 26 tool definitions carries the offending escape. Replaying that body with **only** that escape changed gave `HTTP 200` and DeepSeek consumed 258,772 input tokens — the fix was proven before any code was written.

`claude --resume <id> --fork-session -p "hi"` against DeepSeek reproduced the 400 with an identical message, and after the fix returned a normal completion.

### 2.5 Provider requests do not go through `globalThis.fetch`

Instrumenting `globalThis.fetch` and `Dispatcher.dispatch` inside the container showed the only `fetch` the gateway makes is its own upload:

```
[gateway] [dbg-upstream] fetch globalThis http://127.0.0.1:3456/__ccr/raw-trace-sync init.body=[object String] len=2791
[gateway] [dbg-upstream] dispatch global body=[object AsyncGenerator]
```

Provider traffic goes out through **undici's `Dispatcher.dispatch`**, with `opts.body` an `AsyncGenerator`. This is worth recording on its own: any future middleware that wants to touch the *outgoing* request body must hook `dispatch`, not `fetch`. (`sse-coalesce.cjs` says as much in its header comment, for the response side.)

## 3. Root cause

Three independent facts compose into the failure:

1. Claude Code's `Artifact` tool, in the variant that ships with the 12-tool / deferred-tools mode, declares `file_paths.items.pattern = "^[^\0]*$"` — a NUL-excluding regex written with the short escape.
2. DeepSeek's request validator does not accept the `\0` escape in a `pattern`, and fails the entire request rather than the offending field. `\u0000` is accepted.
3. A session's tool definitions are frozen in its `prompt_snapshot` at creation and re-sent on resume, so the incompatibility is bound to the *session*, not to the current provider or ccr version.

Switching provider mid-session therefore changes the tunnel but not the payload: the old session keeps sending a schema DeepSeek will not parse, while a new session never had the field in the first place.

## 4. Fix

`vps_oracle/compose/ccr/sanitize-tool-schema.cjs`, mounted into every node process via `NODE_OPTIONS --require` alongside the three existing preloads, plus a unit test and a README section:

- hooks `Dispatcher.dispatch` (primary) and `globalThis.fetch` (defence in depth);
- rewrites **only** `pattern` values under `tools[].input_schema` and `tools[].function.parameters` — a `\0` in message text, a system prompt or a tool description is left alone, because this middleware sits in front of all provider traffic and rewriting prose would silently alter conversation content;
- buffers the body to parse it as a whole (cap: 64 MiB, `CCR_SCHEMA_SANITIZE_MAX_BYTES`), re-serialising only when something actually changed;
- drops `content-length` and `content-encoding` from the outgoing headers, since the body gets longer (3 → 7 bytes per escape) and any length the caller computed would be stale — the same reasoning `sse-coalesce.cjs` applies on the response side;
- falls back to the original bytes on any error, unknown chunk type, over-cap body or unparseable JSON.

Alternatives considered and rejected:

- **Switch the provider to `openai_chat_completions`.** The repo already requires that for third parties on other grounds, and it was the first thing tried — but the tool schema is converted, not dropped, so the same `pattern` would still be sent and the same validator would still refuse it. Changing the protocol does not touch the actual defect.
- **Tell users to open new sessions.** Unreliable: the rich Artifact variant is what most current sessions get (see the table in §2.3), so a "new" session can land in the same trap. It also means abandoning session history.
- **Buffer-and-rewrite only when the escape is present.** This is what the middleware does; the `indexOf` fast path means the overwhelming majority of requests are never parsed or copied.

## 5. Verification

```
$ cd vps_oracle/compose/ccr && node sanitize-tool-schema.test.cjs
✓ 1  tool pattern 的 \0 被改寫成 \u0000（語義相同）
✓ 2  \012（八進位）同 \d \. 等轉義原封不動
✓ 3  對話內容、system prompt、tool description 裡的 \0 一律唔碰
✓ 4  OpenAI 形狀（tools[].function.parameters）一樣處理
✓ 5  串流重組：1 byte ~ 64KB 切塊結果全部一致，且 CJK 內容零損傷
✓ 6  binary content-type 完全唔碰
✓ 7  超出 size cap 的 body 原樣轉發（唔會無上限緩衝）
✓ 8  非 UTF-8 位元組、未知 chunk 型別唔會拋錯，且原樣保留、次序不變
✓ 9  fetch wrapper：要改嘅改、唔使改嘅原物件通過
✓ 10 stdout 乾淨（--require 腳本的硬性要求）
```

Staged on an isolated container built from a **copy** of the ccr volume (`docker volume create` + `cp -a`), per the rule in the compat-lessons doc, before anything touched the live container. Same 968 KB request, five times each:

```
unpatched container:  400 400 400 400 400   (upstream_response / Upstream request failed)
patched container:    200 200 200 200 200
```

Then against the live gateway after `docker compose up -d`, plus a real `claude --resume <old-id> --fork-session -p "…"`, which produced a normal completion on the old session's context.

`docker logs ccr | grep sanitize-tool-schema` shows one `rewrote N pattern value(s)` line per rewritten request — expect to see one for each turn of an affected session, and none for sessions whose tools are clean.

## 6. Leftovers / lessons

- **Not fully explained: why a session gets the rich or lean `Artifact` variant.** The correlation with the tool count (12/deferred vs 29) is exact across every snapshot on this machine, but the mechanism behind that split was not chased down. It does not matter for the fix — the middleware is variant-agnostic — but it does mean the "which sessions are affected" question can only be answered by inspecting a session's snapshot, not predicted.
- **One unexplained 502.** During staging, the first streaming implementation returned `502 upstream_connect / Failed to reach upstream provider` twice, then, after `content-length` stripping was added, 10/10 and 5/5 succeeded. The logged header list contained no `content-length`, so the strip was a no-op on that path and cannot be shown to be the cause. Treat the 502 as unexplained; if it recurs, instrument `dispatch` before assuming the body rewrite is sound.
- **Only `\0` is handled.** If another provider turns out to reject a different escape, the fix is the same shape but the escape table needs extending. Consider generalising `DECODED_ESCAPE` to a configurable set before adding a second case.
- **An inspector check would fit here.** A check over ccr's `request-logs.sqlite` for non-2xx rows whose body contains `Invalid schema for function` would have caught this the day the group was switched, instead of leaving it to be noticed as "old sessions are broken". Not added yet.
