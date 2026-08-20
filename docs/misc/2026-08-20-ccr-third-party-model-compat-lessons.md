# CCR 接第三方模型的三个坑：Anthropic 直通吐空 + opus/sonnet/haiku 分档路由失效 + NODE_OPTIONS 注入脚本的两条暗坑

- 日期：2026-08-20
- 触发场景：用户新购了火山方舟（Volcano Engine Ark / Byteplus）的 coding plan，通过 ccr（claude-code-router v3.0.20）接入，经常"发出去没反应"；后续为了让 opus/sonnet/haiku 分档路由生效，又做了一版"ccr 面板唯一权威来源"的架构改造
- 涉及仓库改动：`vps_oracle/compose/ccr/{docker-compose.yml,export-model-routing.cjs,model-routing/}`、`vps_oracle/compose/switchboard/{docker-compose.yml,.env,.env.example}`、`vps_oracle/compose/switchboard/switches/{jerome,bridget,evidence}-ccr/{on.sh,status.sh}`
- 本文档定位：不是某一次具体故障的时间线（那种记法见 `docs/incidents/`），而是接第三方模型这件事本身的经验总结，给以后加新 provider / 排类似故障时直接查

## 结论先行

1. **ccr 里但凡不是官方 Anthropic 的 provider，protocol 一律选 `OpenAI Chat`（`openai_chat_completions`），不要选 `Anthropic Messages`（`anthropic_messages`）。** 直通模式目前对所有测过的第三方（DeepSeek 官方、火山方舟）都不安全。
2. **opus/sonnet/haiku 分档路由，靠的是 Claude Code CLI 自己认的 `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` 环境变量，不是 ccr 网关自动识别请求里的模型名去分流。** 不设这三个环境变量，换模型（`/model opus` 之类）在 ccr 这条链路上是摆设，实际永远打 profile 里的默认 `model`。要让三个目录（jerome/bridget/evidence）各配各的，得在 ccr 面板建三个独立 profile（各绑一把 token），而不是共用一个——见坑二"最终方案"。
3. ccr 改配置（provider 的 `type`、profile 的 `opusModel` 等）**不保证热生效**，运行中的网关进程会把配置缓存在内存里；改完不确定是否生效时，`cd vps_oracle/compose/ccr && docker compose restart` 一下最省事。
4. ccr 内置的 provider"预设模板"（比如"Byteplus"那个）填的接入点路径可能是错的/不完整的（`source: "preset"` 而非 `"detected"`）——加 provider 时优先用会实际探测连通性的方式（勾 Auto detect protocols，或手动填自定义 provider 让 ccr 去 `detected`），不要无条件信预设。
5. **往 ccr 容器塞 `NODE_OPTIONS --require` 脚本：只用 `console.error`（永远不用 `console.log`），且 `fs.watch` 千万别把 `config.sqlite-wal`/`-shm` 也算进去。** 两条都是这次真实把 ccr 搞挂过的坑，细节见坑三。改这类脚本一律先拿卷的副本（`docker volume create` + `cp -a`）在隔离环境里验证，不要直接在线上容器上试错。

## 坑一：Anthropic Messages 直通，第三方模型吐空

### 症状

CC 发一条消息，长时间无响应；同一会话第二条消息又正常。ccr 自己的请求日志显示 200/成功。

### 根因

Claude Code 最近版本（本次是 2.1.237）新增了一个私有 beta 特性——`mid-conversation-system`（请求头 `anthropic-beta: ...mid-conversation-system-2026-04-07...`）。命中这个特性时，CLI 在**会话第一轮**会把 hook（SessionStart 之类）注入的额外上下文包装成 `messages` 数组里的一条：

```json
{"role": "system", "content": "..."}
```

这在标准 Anthropic Messages API 里不合法——`system` 只能是顶层字段，不能出现在 `messages` 数组的 role 里。

第三方模型（本次验证过 DeepSeek 官方自己的 `/anthropic/v1/messages`、以及转卖同一个 DeepSeek 模型的火山方舟）提供的"Anthropic 兼容"接口，都只是给 Claude Code 这类工具接入用的**后加薄壳**，没跟上这个新 beta。壳遇到这条非法消息时**不报错、不忽略，而是返回一个"成功"但完全空的响应**（`200 OK`，`output_tokens: 0`，`content` 是空字符串）。ccr 如实转发这个"成功"响应，从 ccr 的角度确实没有任何异常可报。

同一会话第二条消息不会重新触发 hook 注入，不带那条非法消息，所以能正常回复——这就是"第一条没反应、第二条正常"的来源。

### 为什么换成 OpenAI Chat 就好了

DeepSeek 系模型的**原生、第一方**接口就是 OpenAI Chat Completions 格式（`/v1/chat/completions`）——Anthropic 兼容壳只是后加的。OpenAI 这套格式规范本来就允许 `role: "system"` 出现在 `messages` 数组任意位置（可以有多条），是完全合法的用法。ccr 选 `openai_chat_completions` 时，会把 Anthropic 格式的请求**转换**成 OpenAI 格式再发出去，那条本来"不合规"的消息翻译过去后变成合法写法，模型用它最成熟的原生接口正常处理。

选 `anthropic_messages` 时 ccr 是**直通**（不转换，原样转发），非法消息原样传给那层脆弱的兼容壳，就被吃掉了。

### 排查方法留档

日志层面看不出内容为空的原因——ccr 的 `request-logs.sqlite` 默认 `requestLogBodyCapture: "errors"`（上次事故修复后改的，成功请求不存 body），且这个配置改了也不会热生效（同样是内存缓存的坑）。

真正管用的方法：本地起一个零依赖的 Node 反代（下面代码），把 `ANTHROPIC_BASE_URL` 临时指过去，跑一次 `claude -p "hi"`，就能拿到 CLI 真实发出的完整请求体和 ccr 真实吐回的原始 SSE 字节，不用碰任何共享服务的配置：

```js
// record_proxy.mjs — 纯记录转发，不修改任何请求/响应
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
# /tmp/recorded/req_N.json 是 CLI 真实发出的完整请求体（含 system/tools/messages）
# /tmp/recorded/resp_N.sse 是上游真实返回的原始 SSE 字节
```

拿到真实请求体之后，用 curl 原样重放 + 逐字段做消融（去掉某个字段/头再发一次），比瞎猜快得多——这次就是这样把范围从"是不是 payload 太大"缩小到"就是那条 `role:system` 消息"的。

## 坑二：opus/sonnet/haiku 换模型，ccr 不路由到配置的目标

### 症状

ccr 管理面板里 `profile.claudeCode.opusModel` 明明配的是大模型（比如 `deepseek-v4-pro`），CC 里切 `/model opus` 之后，ccr 网关日志里 `resolved_model` 却还是小模型（`deepseek-v4-flash`）——跟没切一样。

### 根因

ccr 的这套"profile"机制，并不是网关侧收到请求后自己解析 `model` 字段来分流的。它的设计是：ccr 把 `opusModel`/`sonnetModel`/`haikuModel` 三个配置值，转换成 Claude Code CLI **自己原生认的**环境变量：

```
ANTHROPIC_DEFAULT_OPUS_MODEL
ANTHROPIC_DEFAULT_SONNET_MODEL
ANTHROPIC_DEFAULT_HAIKU_MODEL
```

值是 ccr 自己的 `provider/model` 格式（比如 `byteplus/deepseek-v4-pro-ga-260813`）。**CLI 读到这三个环境变量后，才知道"opus 档位实际该发哪个模型名"**，然后把这个字符串原样当 `model` 字段发给 ccr，ccr 网关再按 `/` 拆出目标 provider+model。

本仓库这套 ccr 切换机制（见 `vps_oracle/compose/ccr/README.md`）刻意只用 `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` 两个变量做 provider 切换，没有同步维护这三个模型分档变量——所以 CLI 根本不知道"opus"该发哪个模型名，只能发它自己默认的通用别名（如 `claude-opus-5`），ccr 网关对这种它没见过、没有显式映射的字符串，直接落到 profile 的兜底 `model` 字段（也就是 flash）。

### 第一版修复（已废弃）：写死在 docker-compose 里

最初的做法是在 `switchboard/docker-compose.yml` 里硬编码三个值（`CCR_OPUS_MODEL` 等），`on.sh` 直接抄进 `.env`。**这个做法被推翻了**：ccr 面板改完模型，这份写死的副本不会联动，还得手动回来改 compose、`docker compose up -d --build` 重建——ccr 面板等于摆设。正确的做法应该是让 ccr 面板保持唯一权威来源，见下面的最终方案。

### 最终方案：三个独立 profile + 只读摘要文件 + 自愈

**1. ccr 面板建三个独立的 claude-code profile**（Jerome/Bridget/Evidence），每个绑一把独立 client token，各自的 `opusModel`/`sonnetModel`/`haikuModel` 在 ccr 面板里各配各的，互不干扰。建的时候两个字段要注意：

- **Effect Scope 选 `Only opened from CCR`，不要选 `System default`**：selected 后者会让多个 profile 抢着写同一份 Claude Code 全局 `~/.claude/settings.json`，后建的覆盖先建的。
- **Entry Mode 选哪个都行**（只影响 ccr 自带的"一键打开"便捷按钮，不影响 API 路由）；纯终端场景选 CLI only 更准确。

`api_keys` 表里每把 token 是 `id: "profile:<profile-id>"` 一对一绑定的——这是 ccr 原生支持"每个 client 各一套配置"的机制，不用我们自己额外发明。

**2. ccr 自己导出一份"安全摘要"，不共享敏感数据**

`config.sqlite` 连同它所在目录权限是 `700 root:root`（装着所有 provider 的原始 API key、管理面板密码），其他容器**根本没法挂载读取**（不是不想读，是权限层面读不了，实测验证过）。

于是新增 `vps_oracle/compose/ccr/export-model-routing.cjs`——跟 `sse-coalesce.cjs` 同款手法，经 `NODE_OPTIONS --require` 挂进 ccr 容器每个 node 进程。它只读 `profiles[]` 里 `model`/`opusModel`/`sonnetModel`/`haikuModel` 四个字符串（不碰任何 key），写到一个单独的、非敏感的 bind mount（`vps_oracle/compose/ccr/model-routing/routing.json`，`chmod 644`），跟装 key 的那个具名卷完全隔离。`switchboard/docker-compose.yml` 只读挂载这同一个宿主机目录消费。

监听机制：`fs.watch` 盯 `config.sqlite`（**只盯主文件名，绝不能连 `-wal`/`-shm` 一起盯**——见下面坑三），配 500ms 防抖 + 30s 兜底轮询防止漏事件。

**3. `on.sh`/`status.sh` 从摘要文件里按自己的 profile id 取值**

`on.sh`（切换那一刻）和 `status.sh`（**每次 switchboard 页面加载都会跑**，见 `config.py` 头注"nothing here is cached, by design"）都读 `routing.json`，按各自 profile id 取三档模型写进 `.env`。`status.sh` 顺手做自愈：只要 base_url 显示"on"，就把 `.env` 里那三行跟 `routing.json` 当前值对比、不一致就重写——所以 ccr 面板一改，**不用手动切换开关，下次谁打开 switchboard 页面就自动同步**。`on.sh` 只在切换那一刻管 token/base_url，token 各组独立（`switchboard/.env` 里 `CCR_TOKEN_JEROME`/`CCR_TOKEN_BRIDGET`/`CCR_TOKEN_EVIDENCE`，走 gitignore，不进 git）。

同步链路的三跳，只有最后一跳做不到自动（见上面跟用户对话里画的图）：
`ccr 面板保存 → routing.json 自动更新（秒级）→ .env 下次 status.sh/on.sh 时更新 → 已经在跑的 claude 进程要开新 session 才读到新值`（最后一跳是 direnv 本身的限制，仓库 README 早有记录，不是这次引入的）。

### 验证

```bash
source /home/ubuntu/.claude-provider/evidence.env
claude -p "hi" --model opus   --output-format json | grep -o '"canonicalModel":"[^"]*"'
claude -p "hi" --model sonnet --output-format json | grep -o '"canonicalModel":"[^"]*"'
claude -p "hi" --model haiku  --output-format json | grep -o '"canonicalModel":"[^"]*"'
# 应该分别打到该组 profile 在 ccr 面板里配的 opus/sonnet/haikuModel
```

## 坑三：往 ccr 容器里塞 `NODE_OPTIONS --require` 脚本的两条真实踩坑

写 `export-model-routing.cjs`（同款 `sse-coalesce.cjs` 手法）过程中，两次把 ccr 搞挂，都在隔离的卷副本里复现、定位、修复后才敢重新上线上。记录下来，以后再往这个容器里塞类似脚本时先看这条。

### 3.1 只读连接会自己触碰 `-wal`/`-shm`，`fs.watch` 连着监听就是自触发死循环

`config.sqlite` 是 WAL 模式。实测验证：**哪怕只是开一个 `{readonly: true}` 的 better-sqlite3 连接、查一次、关掉，磁盘上就会凭空多出 `config.sqlite-wal`/`config.sqlite-shm`**（连接前这两个文件不存在，连接后就有了）。如果 `fs.watch` 把这两个文件也算作"配置变了"，自己的每一次读都会触发下一次读——死循环，几秒内 CPU/IO 打满，ccr 直接进不去（端口 connection reset）。

同样验证过：**真正的写入（`UPDATE` + 关闭连接）会触发 checkpoint，主文件 `config.sqlite` 的 mtime 会真实变化**，而单纯的只读连接不会碰主文件。所以只监听主文件名（`filename === "config.sqlite"`，不是 `startsWith`）就能两全：自己的读不会自触发，真正的保存还是能捕捉到，30s 兜底轮询再保底。

复现/修复方法：**永远先拿卷的一份 `docker volume create` + `cp -a` 副本做实验**，不要直接在线上容器上试错——这次两次出问题都是先在副本里验证好了修复方案，再重新 `docker compose up -d` 到线上，全程线上没有反复挂第二次。

### 3.2 `--require` 脚本绝对不能用 `console.log`（stdout），只能 `console.error`（stderr）

ccr 自己的 entrypoint 会跑一个 node 子进程去生成管理面板 token，**把该子进程的 stdout 原样捕获、直接嵌进生成的 nginx 配置文件**（`return 302 ...?ccr_web_token=<这里>`）。任何 `--require` 脚本只要往 stdout 打印任何东西，且恰好在这次 token 生成的那个 node 进程里被加载到，输出就会混进 token 字符串中间，把 nginx 配置文件搅成语法错误，`ccr-nginx` 反复崩溃重启，网关整个不可用。

`sse-coalesce.cjs` 从一开始就只用 `console.error`，从没出过这个问题；这次 `export-model-routing.cjs` 一开始用了 `console.log` 就立刻炸了，改成 `console.error` 后问题消失。**结论：容器里任何 `NODE_OPTIONS --require` 脚本，一律只用 `console.error`，永远不用 `console.log`**——不确定某条日志会不会被下游当成"命令输出"来解析时，默认往 stderr 走最安全。