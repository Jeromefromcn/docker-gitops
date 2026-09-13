# Upstream feedback package: Claude Code VS Code extension per-event rendering bug

Date: 2026-08-15
Source incident: [../incidents/2026-08-15-ccr-vscode-extension-stall.md](../incidents/2026-08-15-ccr-vscode-extension-stall.md) (with the full evidence chain and §9 postscript two)
Purpose: report the upstream defect confirmed in the incident to the right party. This file contains the reporting targets, channels, priorities, and a paste-ready English report body.

## 1. Reporting targets overview

| Target | Channel | Priority | What to report |
|---|---|---|---|
| **anthropics/claude-code** | GitHub issues: <https://github.com/anthropics/claude-code/issues> | **High (the only real fix)** | The VS Code extension renders stream events per event; slow UI rendering stalls the protocol channel, and permission/approval prompts are queued and delayed by minutes to hours. Channel verified: extension 2.1.233's bundled `package.json` `bugs.url` points to this address |
| Same as above | In-extension `/bug` command | Auxiliary | A lightweight report with on-site logs, supplementing (optionally) the GitHub issue |
| Zhipu | bigmodel.cn developer feedback / Coding Plan support channel | Low (optional) | Suggest their `anthropic_messages` endpoint merge consecutive deltas server-side to align with the official API granularity |
| musistudio/claude-code-router | Do not report | — | The gateway forwards per protocol and is not at fault; the problem is not there |
| DeepSeek | Do not report (for now) | — | Not the cause (~2-3 tokens/event), not the current primary upstream, already covered by our middleware |

## 2. Main report: anthropics/claude-code

**Status: submitted** — [#86854](https://github.com/anthropics/claude-code/issues/86854) (2026-08-15 14:21 HKT, label `bug`). Official reply/fix progress will be updated here.

Steps:

1. ~~Search for duplicates first~~ Dedup already done (2026-08-15, see §2.2): **no duplicate**, open a new issue, and cross-reference the related #81425 in the body (§2.1 already includes a Related issues section).
2. Open a new issue using the Bug report template (the GitHub form has three preflight checkboxes at the top: searched existing issues / single bug / using the latest version — check all of them), using the English version in §2.1 below for the title and body (the six body sections are already split according to the `bug_report.yml` template).
3. Fill in the `<...>` placeholder in the body (VS Code client version) with the real value before submitting.
4. Optional: run `/bug` in the extension session where the problem occurred so the maintainers get on-site logs.

### 2.2 Dedup results (2026-08-15)

Keyword combinations: `unknown message ID` / `extension slow` / `streaming delayed` / `webview slow` / `extension stuck generating` / `streaming behind` / `VS Code extension Remote-SSH slow` / `permission prompt delayed` / `ANTHROPIC_BASE_URL extension slow` / `custom endpoint extension lag` / `long conversation extension slow render`, etc., searching both open and closed.

**No duplicate**: no one has reported the combination "fine-grained SSE (per-token delta) + Remote-SSH extension → render backlog → delayed prompts". The three related ones:

| Issue | Status | Relation |
|---|---|---|
| [#81425](https://github.com/anthropics/claude-code/issues/81425) | open | **Most relevant**: same `notification channel error ... id:0` log signature, same family of extension-session hangs; but a different trigger and mechanism (auto-mode classifier decision lost → permanent hang with no timeout, maintainers subscribed + Cursor), complementary to ours — both point to the CLI↔webview channel dropping responses/no-timeout under stress |
| [#27808](https://github.com/anthropics/claude-code/issues/27808) | closed | Same "only in extension, not reproducible in terminal" streaming stall (PreToolUse hook trigger), different mechanism |
| [#8722](https://github.com/anthropics/claude-code/issues/8722) | closed | Long-session performance family (history 700MB OOM crash loop), different failure mode (OOM vs backlog delay) |

Optional action: append a comment to #81425 (draft in §2.3), pointing out that we observe the same channel-error log under a different repro path (fine-grained SSE render backlog) — the two cases corroborate the channel fragility.

### 2.3 Comment draft (to #81425, English)

New issue created: [#86854](https://github.com/anthropics/claude-code/issues/86854); **comment already posted to #81425 at 2026-08-15 14:24 HKT** ([comment 5300925938](https://github.com/anthropics/claude-code/issues/81425#issuecomment-5300925938), body is the draft below). If #86854 / #81425 get new replies, update here accordingly.

> Hello — same webview channel error signature, different repro path, cross-linking for visibility.
>
> We hit this exact log line too, but the trigger was different: a third-party
> Anthropic-compatible provider emitting one SSE `content_block_delta` event
> per token (thinking-heavy turns → ~6300 events per response). The extension
> fell behind the stream (per-event render over Remote-SSH), the CLI blocked
> on stdout backpressure, and permission/plan prompts were displayed
> minutes-to-hours late — while our Notification hook fired on time, proving
> the CLI had already processed the response.
>
> Key data from the affected session:
> - 6400 output tokens → 6314 SSE delta events (~135B each); the official API
>   batches multiple tokens per delta — 1–2 orders of magnitude fewer events.
> - Combination matrix: terminal + provider fine, extension + official fine,
>   extension + provider stalls — only the event granularity varies.
> - A proxy-level SSE coalescing workaround (merge consecutive same-type
>   deltas into time-windowed batches) cut the event rate ~3–23x; the prompt
>   delay went tens of minutes → ~3 min → seconds, with no other variable
>   changed.
>
> Full writeup with the evidence: #86854.
>
> Both cases point at the same CLI↔webview channel dropping/silencing
> responses under stress — in yours the decision never dispatched with no
> timeout; in ours responses arrived after the CLI had already dropped the
> request. Worth fixing together: batch stream-event rendering on the webview
> side, and stop silencing channel errors.

Pre-submit check: do not include API keys / provider account info / transcript originals / private repo links (all evidence is inlined in the body, not dependent on our private repo).

### 2.1 English issue body (paste-ready)

**Title:**

```
VS Code extension (Remote-SSH): per-event stream rendering delays permission prompts by minutes-to-hours with fine-grained SSE providers
```

**Body:**

````markdown
## What's Wrong?

The Claude Code VS Code extension (over Remote-SSH) falls minutes-to-hours
behind the model stream when the endpoint is an Anthropic-compatible provider
that emits one SSE `content_block_delta` event per token. The CLI receives and
processes the complete response within seconds (a Notification-type hook fires
on time), yet the extension keeps showing "working" and permission
requests / AskUserQuestion prompts are displayed extremely late. The same
provider works fine in the terminal, and the extension works fine against the
official API — the failure occurs only when the extension meets a fine-grained
event stream.

## What Should Happen?

- Permission prompts / plan approvals / AskUserQuestion should be displayed
  promptly after the CLI receives them, regardless of stream event granularity.
- The extension's render cost should not scale linearly with the number of
  stream events.
- Control messages should never queue behind content rendering.

## Error Messages/Logs

Extension host log signature (seen at the start of affected sessions):

```
claude-vscode notification channel error: Received a response for an unknown message ID: ... id:0
```

Observations consistent with the failure:

- CLI process alive in S state, **zero TCP connections, zero child processes** —
  not waiting on the network; blocked writing to its own stdout (extension host
  not draining fast enough; 64KB pipe backpressure).
- Session transcript shows the complete assistant response (`stop_reason:
  "tool_use"`, full usage) and a Notification hook fired on time — the CLI had
  already finished the turn — but no terminal `result` event: the turn never
  completed CLI-side.

## Steps to Reproduce

Setup:

- VS Code Remote-SSH to a Linux host with the Claude Code extension.
- Point the extension at a third-party Anthropic-compatible endpoint that emits
  per-token deltas (we use Zhipu GLM coding plan, `anthropic_messages`-style
  streaming, thinking enabled) via a local gateway.
- Use a long conversation with many prior turns.

Steps:

1. Run a long, thinking-heavy agentic turn (e.g., a large file edit plus a
   summarization).
2. Let it reach a permission request or plan approval.
3. Observe: the prompt takes minutes-to-hours to appear in the extension, while
   the session transcript already shows the CLI processed the response; output
   trickles in slowly in the meantime.

Combination matrix (only the event granularity varies):

| Client | Upstream | Result |
|---|---|---|
| Terminal (CLI TUI) | same third-party provider | fine |
| VS Code extension | official Anthropic API | fine |
| VS Code extension | same third-party provider | stalls minutes–hours |

## Claude Code Version

- Extension: 2.1.233 (linux-arm64; CLI bundled with the extension, same version)
- VS Code client: <version>
- Host OS: Linux (Remote-SSH)
- Endpoint: third-party Anthropic-compatible provider (Zhipu GLM), reached
  through a local gateway; thinking enabled

## Additional Information

Event granularity data (captured from the gateway's request logs, SSE bodies):

| Response | output_tokens | SSE delta events | bytes/event |
|---|---|---|---|
| A | 6400 | 6314 | ~135B (855KB total) |
| B | 3822 | 3803 | ~135B |
| C | 2877 | 2720 | ~135B |

Essentially one event per token; ~99% are `thinking_delta` with thinking
enabled. The official API batches multiple tokens per delta — 1–2 orders of
magnitude fewer events.

Mechanism (our analysis): the extension processes each stream event
individually — JSON parse → `postMessage` across the Remote-SSH tunnel to the
local webview → conversation re-render (expensive on long sessions).
Consumption rate falls below the production rate → the CLI's stdout pipe backs
up → the CLI blocks on write → control messages queue behind tens of thousands
of pending events. The `unknown message ID` error above is consistent with
responses arriving after the CLI had already dropped the request.

Workaround that proves the mechanism: a proxy-level SSE coalescing middleware
merges consecutive same-type `content_block_delta` payloads into time-windowed
batches (protocol-safe: same index/type only, order preserved). Cutting the
event rate changed only that variable:

- No coalescing: prompt tens of minutes late.
- ~40ms windows (~3–5x fewer events): ~3 minutes late.
- ~500ms thinking window (~23x fewer events): prompt appears within seconds.

Related issues:

- #81425 — identical channel-error log line, different trigger (auto-mode
  permission classifier decision never dispatched → infinite hang with no
  timeout). Both cases point to the CLI↔webview channel dropping responses
  under stress with errors silenced.
- #27808 — another extension-only streaming stall (PreToolUse hook trigger),
  not reproducible in the CLI.

Happy to provide more data (event captures, timings) if useful.
````

## 3. Secondary (optional): Zhipu

Channel: bigmodel.cn developer feedback entry / GLM Coding Plan support channel (Chinese is fine, no need for English).

Key points (can be expanded into a paragraph):

- Symptom: `anthropic_messages` streaming responses emit roughly one `content_block_delta` per token (~135B/event); with thinking enabled, 99% are `thinking_delta`; a single 6400-token response produces 6314 events.
- Difference: the official Anthropic API batches multiple tokens per delta, with an event rate 1–2 orders of magnitude lower.
- Impact: the Claude Code official VS Code extension renders per event; under a high event rate the UI backs up and prompts are delayed by hours (terminal unaffected).
- Suggestion: server-side, merge consecutive same-type deltas into N-millisecond batches before sending.

## 4. Explicitly not reporting

- **musistudio/claude-code-router**: the gateway forwards per-event in compliance with the protocol, not at fault; our middleware has already resolved it one layer above.
- **DeepSeek**: coarser granularity (~2-3 tokens/event), not the cause, and not the current primary upstream; if it later becomes the primary upstream and the issue reproduces after disabling the middleware, report per the same key points as §3.