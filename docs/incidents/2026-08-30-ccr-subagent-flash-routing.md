# ccr 把 subagent 的 pro 请求错误路由成 flash

- 日期：2026-08-30
- 环境：VS Code Claude Code（2.1.251）→ ccr（claude-code-router v3.0.20，自建 Docker 镜像）→ byteplus（火山方舟 deepseek-v4 系列）
- 现象：主 session 用 pro（opus 档）正常，但 Task 工具 spawn 的 subagent 请求被降级成 flash，回答明显变快/变笨
- 修复：新增 `vps_oracle/compose/ccr/patch-subagent-routing.cjs`，在 gateway 启动前修掉 server.js 里 `ZPe()` 的一处逻辑；compose 挂载 + `NODE_OPTIONS --require` 注入，运行时自愈、镜像重建不丢

---

## 1. 结论先行

**根因在 ccr 的路由代码，不在 Claude Code。** CC 的 subagent 请求 model 栏位正确填的是 pro（完整名 `byteplus/deepseek-v4-pro-ga-260813`），但 ccr 的 `builtin-agent-claude-code` 规则识别到 subagent 标记后，**无条件禁用「client-model」策略**，导致请求自带的 pro 被无视，落到 profile 兜底 `model`（flash）。

## 2. 证据链

### 2.1 现象复现（request-logs）

主 session 与 subagent 是同一个 CC session，主 session 请求 model=pro，subagent 请求也应该是 pro，但实际路由结果：

```
12203 main         | CC 发 pro   → resolved pro    ✓
12205 SUB(a51eea)  | CC 发 pro   → resolved FLASH  ✗  ← 根因
12206 SUB(a51eea)  | CC 发 pro   → resolved FLASH  ✗
```

同一时刻、同一 session，主 session 走 `default-route`（尊重请求 model=pro），subagent 走 `builtin-agent-claude-code`（强制 profile.model=flash）。

### 2.2 CC 发的 subagent 请求体（记录 proxy 抓包铁证）

`x-anthropic-billing-header: cc_version=...; cc_entrypoint=claude-vscode; cc_is_subagent=true;`

请求体 `model` 字段 = `byteplus/deepseek-v4-pro-ga-260813`（pro），**CC 没有发错**。

### 2.3 ccr 路由决策（trace）

subagent 请求 hop2：`decision builtins.builtin-agent-claude-code → target: flash`

主 session 请求 hop2：`decision builtins.default-route → target: pro`

差异就是 subagent 请求带 `x-claude-code-agent-id` + `cc_is_subagent=true` 标记，触发了 builtin 规则。

## 3. 根因

ccr 的 minified `server.js`（`/app/packages/core/dist/main/server.js`）里，路由决策 `KPe` 的评估链：

```
g = client-model（请求自带的 model，能被 modelRegistry 解析则保留）
p = builtin-agent（eQe → profile.model = flash）
最终 m = A ?? g ?? p
```

其中 `g` 受 `ZPe()` 门控：

```js
function ZPe(e,t,r,n){
  if(!gh(e,t,"claude-code")) return true;
  if(e.builtInClaudeCodeSubagent===!0) return false;   // ← 缺陷
  ...
}
```

subagent 请求（`builtInClaudeCodeSubagent=true`）时，`ZPe` 直接 `return false`，**无条件禁用 client-model**。此时：

- `XPe`（subagent-env 策略）读 `CLAUDE_CODE_SUBAGENT_MODEL` 环境变量 —— 本 repo 的 profile 没设 → 返回 undefined
- 于是评估链一路落到 `p`（`eQe` → `profile.model` = flash）

**缺陷本质**：subagent 时禁用 client-model 应该以「存在 `CLAUDE_CODE_SUBAGENT_MODEL`」为前提，而不是无条件禁用。没有 subagent 专用模型时，应该回落到 client-model（请求自带的 pro）。

## 4. 修复

`patch-subagent-routing.cjs` 在 gateway 启动前（`NODE_OPTIONS --require`）把 `ZPe` 改成：

```js
function ZPe(e,t,r,n){
  if(!gh(e,t,"claude-code")) return true;
  let o=u0(e,t,"claude-code"), i=LP(o?.env?.[w5],t,r);
  if(e.builtInClaudeCodeSubagent===!0) return !i;   // 有 SUBAGENT_MODEL 才禁用 client-model
  return !i || !n || i.canonicalSelector.toLowerCase() !== n.canonicalSelector.toLowerCase();
}
```

即：subagent 时只有在 profile 设了 `CLAUDE_CODE_SUBAGENT_MODEL`（`i` 非空）才禁用 client-model（让 `XPe` 精确匹配接管）；否则保留 client-model，尊重请求自带的 model。**不写死任何模型**，完全动态跟随 CC 按档位发的 model。

### 修复后验证

```
12295 SUB(ac9937) | CC 发 pro → resolved PRO  ✓
12297 SUB(ac9937) | CC 发 pro → resolved PRO  ✓
```

trace 显示 subagent 请求改走 `default-route`（与主 session 一致），不再被 `builtin-agent-claude-code` 强制改 flash。

## 5. 为什么是 patch 脚本而不是改配置

`ZPe` 在镜像层（`/app/packages/core/dist/main/server.js`），没有配置开关。镜像从 pin 死的 git tag v3.0.20 build，所以补丁做成 `--require` 脚本：

- **运行时自愈**：每个 node 进程启动时重新打补丁，`docker compose up -d --build` 镜像重建后第一个 node 进程会自动重新打上（已验证：重建后补丁标记 + 新 ZPe 都在，旧 ZPe 清零）
- **幂等**：检测旧字符串存在才打补丁；已打补丁则跳过；检测不到预期字符串则告警（提示 ccr 可能升级，需人工复核 ZPe 逻辑）
- **git 可审计**：补丁内容在 `vps_oracle/compose/ccr/patch-subagent-routing.cjs`，与 `sse-coalesce.cjs`、`export-model-routing.cjs` 同款 `--require` 模式

## 6. 遗留 / 注意

- 若以后在 ccr 面板给 profile 设了 `CLAUDE_CODE_SUBAGENT_MODEL`，则 subagent 走 `XPe` 精确匹配（`CLAUDE_CODE_SUBAGENT_MODEL == 请求 model` 才命中），不命中仍落 profile.model。这是 ccr 原生设计，本次补丁未改动。
- 若升级 ccr 到新版本，`ZPe` 的 minified 字符串可能变，补丁脚本会告警「ZPe not found in expected form」——此时需重新核对新版逻辑，更新 `OLD_ZPE`/`NEW_ZPE`。
- 主 session 里出现的 `query_source: auto_mode` 的 flash 请求（无 agent-id）是 CC 的 auto mode 行为，与本次 bug 无关。
