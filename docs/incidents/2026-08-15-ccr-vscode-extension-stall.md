# VS Code Claude Code 插件「卡死」排查与修复记录

- 日期：2026-08-15（UTC+8 凌晨）
- 环境：VS Code Remote-SSH 连到 Oracle Linux 服务器，Claude Code 通过 ccr（claude-code-router v3.0.20，自建 Docker 镜像）切换到第三方 provider
- 本文档：把从现象到修复的全过程、中间踩的坑、证据数据、进程 PID 都记录下来，便于复查。**不包含任何 API key**（key 在容器 `/data/.claude-code-router/config.sqlite` 和 `docker-compose.yml` 同目录 `.env` 里）。

---

## 1. 背景与现象

另一个 topic（「规划香港到马来西亚 8 天行程」）在 VS Code 扩展里执行，用户观察到：

- 会话实际早已结束（用户自装的 `claude-code-notify` hook **准时**发来了通知），但扩展仍显示「正在执行」；
- 过一段时间会**慢慢吐出**一些旧输出，过了很久扩展才把 CC 的提问（ExitPlanMode 批准请求）显示出来；
- 终端里用没问题；用 Claude 官方模型时扩展也没问题；
- 只有「扩展 + ccr/第三方 provider」这个组合会卡。

关键线索：**通知准时、UI 极慢** → 不是事件丢失/握手失效，而是**管道里积压、按顺序晚送达**。

## 2. 排查过程（证据链）

### 2.1 卡住的 session / 进程快照

| 项 | 值 |
|---|---|
| 卡住的扩展 claude 进程 PID | 3180047（父进程 exthost 3177808，启动于约 15:38 本地） |
| 该进程 cwd | `/home/ubuntu/jerome/plans` |
| session transcript | `~/.claude/projects/-home-ubuntu-jerome-plans/972cd377-e7d0-40fb-bc00-8d770f92ffd4.jsonl` |
| 另一扩展 session 进程 | 3536341（cwd `/home/ubuntu/bridget/love-bird-op`） |
| 本次排查会话（终端）进程 | 3743504 |
| 卡住进程状态 | 存活、S 睡眠；**零 TCP 连接、零子进程** → 不在等网络/命令，纯等本地握手 |

（PID 会随重启变化，仅作当时快照。）

### 2.2 transcript 结尾：API 响应其实是完整的

最后一条记录 `2026-08-14T16:28:43.970Z`（本地 00:28）：
- type=`assistant`，stop_reason=`tool_use`，usage 齐全，msg id `msg_20260815002842588c73b19c0b4bfe`（代理格式，非官方）；
- 要调用的 tool 是 **`ExitPlanMode`**（tool id `call_8fe91198ce904f01a07bea39`，OpenAI 风格 id —— 证实走的是第三方 provider）；
- **后面没有 `result` 结束事件** → 那一轮从 CLI 内部就没有结束。

→ provider/ccr 这段没有丢数据；卡点在 CLI 之后。

### 2.3 gateway 请求日志：provider 段无嫌疑

`/data/.claude-code-router/app-data/request-logs.sqlite`（该库全量记录每次请求）：

- 那轮带 ExitPlanMode 的请求（id 747）：created 16:28:42.304 → completed **16:28:44.018（1.7s）**，200，`att=1`（无重试）、`sat=0`（无凭证饱和）；
- 一小时窗口 186 条全部 200；
- provider = `Zhipu AI (China) - Coding Plan`（`open.bigmodel.cn/api/anthropic`，anthropic_messages 直通，无 transformer）。

### 2.4 找到触发条件：逐 token 的 SSE 事件粒度

同一请求日志里取几条流的 body（capture policy=all 时存的）：

| 行 | output_tokens | SSE delta 事件数 | text_delta | 事件平均字节 |
|---|---|---|---|---|
| 749 | 6400 | **6314** | 40 | ~135B（整条 855KB） |
| 745 | 3822 | 3803 | 68 | ~135B |
| 746 | 2877 | 2720 | — | ~135B |

- **几乎每个 token 一个 delta 事件**（~135B/事件），且 thinking 开启时 99% 是 `thinking_delta`（text_delta 只有几十个）。
- 官方 Anthropic API 是**多 token 合并**的大块事件，事件率低 1–2 个数量级。
- 旁边还有 auto-mode 分类器的 `glm-5.3` 小请求（非流式、out=64，每 2–8 秒一条），扩展模式请求量远大于终端。

### 2.5 结论：瓶颈在 CLI → 扩展 →(SSH)→ webview 这段

组合矩阵（唯一变量 = 事件粒度）：

| 组合 | 结果 |
|---|---|
| 终端 + ccr | 正常（本地 TUI 渲染） |
| 扩展 + 官方 API | 正常（粗粒度） |
| **扩展 + ccr** | **积压**（逐 token 细粒度） |

机制：扩展对每个事件要做 JSON 解析 + `postMessage` 过 Remote-SSH 隧道到本地 webview + 整段对话重渲染（长 session 下很贵），消费速度 < 生产速度 → stdout pipe（64KB）背压 → CLI 卡在 write → 控制消息（权限/ExitPlanMode 请求）排在几万事件后面 → 小时级延迟。扩展日志里那条 `claude-vscode notification channel error: Received a response for an unknown message ID: ... id:0` 就是响应晚到、CLI 已丢请求的副产物。

## 3. 中间踩的坑（按时间顺序）

1. **初判为「批准握手丢失」** → 被新信息推翻（通知早到、输出慢吐 = 积压不是丢失）。
2. **globalThis.fetch patch 无效** → ai-gateway 是 `require("undici")` 后用 `getGlobalDispatcher().dispatch(...)`，不走 fetch。
3. **dispatcher 层 patch 仍无效** → DeepSeek 的 provider fetch 落在 **`server.js`（ccr-core-server）**，它没加载 preload；只有 gateway 子进程带 `--require`。
4. **compose 加 `NODE_OPTIONS` 后仍无效** → `--require` 只**载入**模块、不**调用** install()；模块需要自启动（见后）。
5. **改 `/data/.../gateway-proxy-preload.cjs` 加 hook 会被覆盖** → `server.js` 每次启动都会 `writeFileSync` 用内嵌副本重建这个文件。改 preload 的路子不可行。
6. **Zhipu 撞 5 小时配额上限**（`[1308] 已达到 5 小时的使用上限`，05:22:05 UTC 重置）→ 改用 DeepSeek 验证（中间件不挑 provider）。
7. 测试文件本身的坑：对 `data: {...}` 整条记录直接 `JSON.parse` 会失败（要先去 `data:` 前缀）；假消费者 onData 的返回顺序写反。

## 4. 架构要点（排查中确认）

- 入口：宿主机 `127.0.0.1:3456/3458` → docker-proxy → **容器内 nginx(8080)** → 按路径分流到 gateway(3456) / 管理 UI(3459)。
- 容器进程：PM2 管两个 app —— `ccr-core-server`（`/app/packages/core/dist/main/server.js`，web+core，**部分 provider fetch 在这**）和 nginx；gateway 是 server.js spawn 的子进程（`--require /data/.../gateway-proxy-preload.cjs` 后 `gateway-bootstrap.js` 同进程 `require` ai-gateway）。
- ai-gateway：`/app/node_modules/@the-next-ai/ai-gateway/dist/index.js`，用 `undici.getGlobalDispatcher()`。
- 配置：`/data/.claude-code-router/config.sqlite`（`app_config` 表，observability 等）；日志：`app-data/request-logs.sqlite`（+admissions/usage）。
- 请求日志 body 捕获合法值：`all | errors | none | sampled`；有内建每日 retention（`DELETE FROM request_logs WHERE source_usage_id IS NULL AND created_at < 阈值`）。

## 5. 修复

### 5.1 SSE delta 合并中间件 `sse-coalesce.cjs`

文件位置（**入库**）：`vps_oracle/compose/ccr/sse-coalesce.cjs`，只读挂载到容器 `/data/.claude-code-router/sse-coalesce.cjs`（core 不认这个新文件，不会覆盖；仓库版本是唯一权威）。

设计：
- **拦截层**：undici `Dispatcher.dispatch` 的 handlers（onHeaders/onData/onComplete），顺带 patch `globalThis.fetch`、`undici.fetch` 兜底。
- **合并规则**：只合并 `content_block_delta` 且带字符串载荷（`text_delta→text` / `thinking_delta→thinking` / `input_json_delta→partial_json`）；连续、同 index、同类型才合并；40ms 窗口（`CCR_SSE_COALESCE_MS`）到期或遇到任何其他事件（content_block_start/stop、message_delta、message_stop 等）时 flush 成一条（载荷拼接）。保序、保协议边界。
- **ping**：默认丢弃（`CCR_SSE_DROP_PINGS=0` 关闭），让合并且跨过 keep-alive 继续。
- **压缩**：请求头强制 `accept-encoding: identity`；若响应仍带 content-encoding 则整条 bypass（不解压重切，避免损坏）。
- **content-length**：合并后摘除（SSE 本来就 chunked）。
- **背压**：下游 onData 返回 false 时暂停队列，resume 时续传。
- **统计**：`/data/.claude-code-router/sse-coalesce-stats.log`，超 256KB 自动截断滚动。

### 5.2 加载机制（最终形态）

`docker-compose.yml`：
- `NODE_OPTIONS: "--require /data/.claude-code-router/sse-coalesce.cjs"` —— 让容器内**所有** node 进程都加载；
- 模块**加载时自调用 `install()`**（幂等），所以 `--require` 直接生效，不依赖任何 preload hook。

### 5.3 日志减量

- `observability.requestLogBodyCapture: "all" → "errors"`（只在失败时存 body）。
- 抹掉历史成功请求的 body + `VACUUM` + `wal_checkpoint(TRUNCATE)`：`request-logs.sqlite` **156MB → 12MB**。

## 6. 验证结果

- 单元测试 9 项全过（合併、content-length、背压、压缩绕过、跨 index 不误合、ping 丢弃）。
- 线上实测（DeepSeek 流式）：一次 200-token 响应 delta 事件 **85 → 7**；stats 记录 `merge in=85 out=11`；响应正常 `message_delta` + `message_stop` 结尾。
- Zhipu 路径因配额未能复测（中间件与 provider 无关，DeepSeek 已证明端到端生效）。

## 7. 遗留问题 / 后续

- 扩展本身「UI 渲染慢不应拖死协议通道、应对流事件批量渲染」仍是上游缺陷，值得报 github.com/anthropics/claude-code（附本 case 的事件粒度数据）。
- 已提交：无。`docker-gitops` 工作区改动 = `docker-compose.yml`（NODE_OPTIONS + bind mount）+ 新增 `sse-coalesce.cjs`。**未提交**。
- 容器已重建生效；镜像重建后同样有效（env 在仓库、中间件在 /data 卷 + 只读挂载）。
- 后记（2026-08-15）：该 bug 造成的会话堆积于当天上午引发服务器资源尖峰（4 核机器 5 分钟负载均值 38.7），排查与处置见本目录 [2026-08-15-vscode-sessions-resource-spike.md](2026-08-15-vscode-sessions-resource-spike.md)。

## 8. 常用命令（复查用）

```bash
# 找卡住的扩展 claude 进程 / 看它在等什么
ps aux | grep vscode-server.*claude
readlink /proc/<pid>/cwd
ps --ppid <pid>; ss -tnp | grep <pid>

# 看某 session transcript 结尾是否完整（缺 "result" 行 = 那轮没结束）
tail -n 3 ~/.claude/projects/<dir>/<session>.jsonl | python3 -m json.tool --json-lines

# gateway 请求日志（含事件粒度/耗时）
docker exec ccr node -e '...sqlite...'

# 中间件统计 / 状态
docker exec ccr cat /data/.claude-code-router/sse-coalesce-stats.log
docker exec ccr sh -c 'echo $NODE_OPTIONS'

# 调窗口 / 关掉中间件
# 改 compose 环境变量后：docker compose up -d
#   CCR_SSE_COALESCE_MS=0  → 禁用；CCR_SSE_COALESCE_MS=100 → 更大窗口
```

## 附：本次修复的完整文件清单

- 仓库（未提交）：`vps_oracle/compose/ccr/sse-coalesce.cjs`、`vps_oracle/compose/ccr/docker-compose.yml`
- 容器卷 `/data/.claude-code-router/`：`sse-coalesce.cjs`（只读挂载）、`sse-coalesce-stats.log`（运行态，卷内）
- 备份：`/data/.claude-code-router/gateway-proxy-preload.cjs.bak-20260815`（stock 原版，作对比用）
