# 上游反馈包：Claude Code VS Code 扩展逐事件渲染 bug

日期：2026-08-15
来源事故：[../incidents/2026-08-15-ccr-vscode-extension-stall.md](../incidents/2026-08-15-ccr-vscode-extension-stall.md)（含完整证据链与 §9 后记二）
用途：把事故中确认的上游缺陷报给正确的对象。本文件含报告对象、渠道、优先级和可直接粘贴的英文报告正文。

## 1. 报告对象总览

| 对象 | 渠道 | 优先级 | 报什么 |
|---|---|---|---|
| **anthropics/claude-code** | GitHub issues：<https://github.com/anthropics/claude-code/issues> | **高（唯一治本）** | VS Code 扩展逐事件渲染流事件，UI 渲染慢拖死协议通道，权限/提问提示被排队延迟分钟到小时级。渠道已验证：扩展 2.1.233 的 `package.json` 自带 `bugs.url` 即此地址 |
| 同上 | 扩展会话内 `/bug` 命令 | 辅助 | 附现场日志的轻量报告，作为 GitHub issue 的补充（可选） |
| Zhipu（智谱） | bigmodel.cn 开发者反馈 / Coding Plan 支持渠道 | 低（可选） | 建议其 `anthropic_messages` 端点对连续 delta 做服务端合并，对齐官方 API 粒度 |
| musistudio/claude-code-router | 不报 | — | 网关转发无责，问题不在它 |
| DeepSeek | 不报（现阶段） | — | 非肇因（~2-3 tokens/事件）、非当前主力上游、已被我方中间件覆盖 |

## 2. 主报告：anthropics/claude-code

**状态：已提交** — [#86854](https://github.com/anthropics/claude-code/issues/86854)（2026-08-15 14:21 HKT，label `bug`）。官方回复/修复进展在此更新。

步骤：

1. ~~先搜重复~~ 已查重（2026-08-15，见 §2.2）：**无重复**，开新 issue，并在正文里交叉引用相关的 #81425（§2.1 已含 Related issues 段）。
2. 按 Bug report 模板开新 issue（GitHub 表单顶部有三个 preflight 勾选框：已搜过现有 issue / 单一 bug / 使用最新版，全部勾上），标题和正文用下面 §2.1 的英文版（正文六节已按模板 `bug_report.yml` 分好）。
3. 把正文中 `<...>` 占位符（VS Code 客户端版本）填上真实值再提交。
4. 可选：在出过问题的扩展会话里跑 `/bug`，让官方拿到现场日志。

### 2.2 查重结果（2026-08-15）

关键词组合：`unknown message ID` / `extension slow` / `streaming delayed` / `webview slow` / `extension stuck generating` / `streaming behind` / `VS Code extension Remote-SSH slow` / `permission prompt delayed` / `ANTHROPIC_BASE_URL extension slow` / `custom endpoint extension lag` / `long conversation extension slow render` 等，open + closed 都搜了。

**没有重复**：没人报过「细粒度 SSE（逐 token delta）+ Remote-SSH 扩展 → 渲染积压 → 提示延迟」这个组合。相关的三个：

| Issue | 状态 | 关系 |
|---|---|---|
| [#81425](https://github.com/anthropics/claude-code/issues/81425) | open | **最相关**：同样的 `notification channel error ... id:0` 日志签名、同为扩展会话挂起家族；但触发与机制不同（auto-mode 分类器决策丢失 → 无超时永久挂起，官方订阅 + Cursor），与我们互补——都指向 CLI↔webview 通道在压力下丢响应/无超时 |
| [#27808](https://github.com/anthropics/claude-code/issues/27808) | closed | 同为「只在扩展、终端不复现」的流式 stall（PreToolUse hook 触发），机制不同 |
| [#8722](https://github.com/anthropics/claude-code/issues/8722) | closed | 长会话性能家族（历史 700MB OOM 崩溃循环），失败模式不同（OOM vs 积压延迟） |

可选动作：在 #81425 下追加一条评论（草稿见 §2.3），指出我们在不同 repro 路径（细粒度 SSE 渲染积压）下观察到同一条 channel error 日志——两个 case 互相印证通道脆弱性。

### 2.3 评论草稿（发到 #81425，英文）

新 issue 已建：[#86854](https://github.com/anthropics/claude-code/issues/86854)；**评论已于 2026-08-15 14:24 HKT 发到 #81425**（[comment 5300925938](https://github.com/anthropics/claude-code/issues/81425#issuecomment-5300925938)，正文即下方草稿）。若 #86854 / #81425 有新回复，同步改这里。

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

提交前检查：不放 API key / provider 账号信息 / transcript 原文 / 私有仓库链接（证据全部内联在正文里，不依赖我们的私有 repo）。

### 2.1 英文 issue 正文（可直接粘贴）

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

## 3. 次要（可选）：Zhipu

渠道：bigmodel.cn 开发者反馈入口 / GLM Coding Plan 支持渠道（中文即可，不必英文）。

要点（可扩写成一段话）：

- 现象：`anthropic_messages` 流式响应基本每 token 一个 `content_block_delta`（~135B/事件），开 thinking 时 99% 是 `thinking_delta`；单次 6400-token 响应产生 6314 个事件。
- 差异：官方 Anthropic API 是多 token 合并的大块 delta，事件率低 1–2 个数量级。
- 影响：Claude Code 官方 VS Code 扩展逐事件渲染，高事件率下 UI 积压，提示延迟小时级（终端不受影响）。
- 建议：服务端把连续同类型 delta 按 N 毫秒批次合并后再下发。

## 4. 明确不报的

- **musistudio/claude-code-router**：网关逐事件转发符合协议，无责；我方中间件已在其外层解决。
- **DeepSeek**：粒度较粗（~2-3 tokens/事件）非肇因，也非当前主力上游；若日后切为主力且关中间件后复现，再按 §3 同款要点反馈。
