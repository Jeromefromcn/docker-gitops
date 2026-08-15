# vps_oracle/compose/switchboard

通用的、配置驱动的开关 UI（stdlib，`app.py` + `config.py`）。挂在 `proxy` 网络上，NPM 反代成 `https://switchboard.jerome.cloudns.asia`（access list=self-only）。

引擎本身不知道任何具体开关是什么——它只读 `switches.ini` 拿到开关清单，对每个开关的 `switches/<id>/{status,on,off}.sh` 三个脚本发号施令：`GET /` 现场跑一遍每个开关的 `status.sh`（不缓存），`POST /toggle` 按当前状态跑 `on.sh` 或 `off.sh`。新增/删除开关只需要加/删一个 `switches/<id>/` 目录 + 三个脚本 + `switches.ini` 里的一个 section，不需要改 `app.py`/`config.py`（但如果新开关要用到新的宿主机路径或密钥，还得改 `docker-compose.yml` 的 volumes/environment 并重建镜像——不是纯配置就够）。设计细节见 [`../../../docs/superpowers/specs/2026-08-13-switchboard-generic-toggle-design.md`](../../../docs/superpowers/specs/2026-08-13-switchboard-generic-toggle-design.md)。

`status.sh` 的退出码是三态契约：exit 0 = **on**；exit 2 = **error**（脚本自己发现的异常，比如读配置文件时的权限错误——跟超时/脚本不存在一样归入 ERROR，绝不能被误读成"安全地关闭了"）；其余非 0 = **off**。`on.sh`/`off.sh` 只有两态：exit 0 = 成功，非 0 = 失败。

`status.sh` 的退出码是三态契约：exit 0 = **on**；exit 2 = **error**（脚本自己发现的异常，比如读配置文件时的权限错误——跟超时/脚本不存在一样归入 ERROR，绝不能被误读成"安全地关闭了"）；其余非 0 = **off**。`on.sh`/`off.sh` 只有两态：exit 0 = 成功，非 0 = 失败。

当前登记的开关：

| id | 说明 |
|---|---|
| `jerome-ccr` | jerome 组的 Claude provider 切换（Official ↔ CCR） |
| `bridget-ccr` | bridget 组的 Claude provider 切换（Official ↔ CCR） |
| `evidence-ccr` | evidence 组的 Claude provider 切换（Official ↔ CCR） |

> CCR = [claude-code-router](https://github.com/musistudio/claude-code-router) 路由网关，可路由到**任意** OpenAI 兼容 provider（智谱 GLM、DeepSeek、Qwen……）。智谱只是当前的上游配置，不是 CCR 本身；换上游在 CCR 管理面板改 provider 即可，CCR 开关不用动（详见 [`../ccr/README.md`](../ccr/README.md)）。
| `jerome-account` | jerome 组的 Claude 订阅账号切换（Jerome ↔ Charles，`CLAUDE_CONFIG_DIR` 指针；正交于 provider 切换） |
| `bridget-account` | bridget 组的 Claude 订阅账号切换（Jerome ↔ Charles，`CLAUDE_CONFIG_DIR` 指针；正交于 provider 切换） |
| `evidence-account` | evidence 组的 Claude 订阅账号切换（Jerome ↔ Charles，`CLAUDE_CONFIG_DIR` 指针；正交于 provider 切换） |

这些开关所属的整个分组切换系统（direnv + 分组 env + CCR + 本 UI + NPM）的完整文档、加新分组的步骤、已知的坑、回滚等，见 [`../ccr/README.md`](../ccr/README.md)；多订阅账号切换（`<组>-account` 开关）的机制与一次性设定见 [`../ccr/ACCOUNTS.md`](../ccr/ACCOUNTS.md)。

## 账号相关文件清单（Jerome ↔ Yin/Charles，2026-08-16 起 sub2 = 全盘镜像）

两个账号的隔离锚点只剩登录 token。`~/.claude-configs/sub2/`（Charles/Yin 的 `CLAUDE_CONFIG_DIR`）
里，除 `.credentials.json` 和 `.claude.json` 外的所有条目都软链到 `~/.claude`——**切账号 =
只换 token**，环境/记忆/历史同一份。

> **维护规则**：`~/.claude` 每出现一个**顶层新条目**，都要补一条 `ln -s ~/.claude/<新条目> sub2/`，
> 否则 Charles 侧读不到，镜像悄悄失同步（无报错）。`plugins/`、`hooks/`、`scripts/`、`CLAUDE.md`、
> `settings.json` 的**内容**变化不需要动——它们是目录内内容，经已有软链自动同步。

### configDir 内（`~/.claude-configs/sub2/`）

| 条目 | 类型 | 归属 | 说明 |
|---|---|---|---|
| `.credentials.json` | 真文件 | **Yin 独享** | OAuth 登录 token，账号唯一身份锚点，永不软链 |
| `.claude.json` | 真文件 | **Yin 独享** | 账号 profile 缓存（email/套餐 tier/rate-limit）+ `modelAccessCache`/eligibility 缓存。共享会让两个账号的准入缓存互相串号，故保留本地 |
| `CLAUDE.md` `settings.json` `hooks/` `plugins/` `scripts/` | 软链 → `~/.claude` | 共享 | 全局配置/插件/钩子 |
| `projects/` | 软链 → `~/.claude` | 共享 | **memory**（`projects/<路径>/memory/`）+ 每会话转录 `.jsonl` |
| `sessions/` `history.jsonl` `session-env/` `shell-snapshots/` `file-history/` | 软链 → `~/.claude` | 共享 | **会话索引/全局历史/环境快照/文件编辑历史** |
| `cache/` `telemetry/` `stats-cache.json` `downloads/` `backups/` `auto-job-log/` `channels/` `plans/` `tasks/` `ide/` | 软链 → `~/.claude` | 共享 | 缓存/日志/应用状态，覆盖无害 |
| `.last-cleanup` `.last-update-result.json` `.claude-code-notify-hooks.json` | 软链 → `~/.claude` | 共享 | 清理/更新/notify 状态 |
| `claude-direnv-wrapper.sh` `direnv-bash-env.sh` `direnv-load.sh` | 软链 → `~/.claude` | 共享 | 分组注入 wrapper 及 helper（实际按绝对路径引用，链了也不碍事） |

### configDir 外、账号切换相关

| 路径 | 类型 | 归属 | 说明 |
|---|---|---|---|
| `~/.claude.json`（HOME 根） | 真文件 | **Jerome 独享** | Jerome 的全局状态（默认 configDir 的状态文件在 HOME 根，不在 `~/.claude/` 内） |
| `~/.claude-configs/sub2/.claude.json` | 真文件 | **Yin 独享** | 见上表 |
| `~/.claude-account/<组>.env` | 真文件 | **switchboard 可写** | 账号指针：`export CLAUDE_CONFIG_DIR=…sub2` = Yin，空 = Jerome。容器只 mount 此目录 |
| `~/.claude-provider/<组>.env` | 真文件 | **switchboard 可写** | provider 指针（CCR） |
| `<组>/.envrc` | 真文件 | 组静态配置 | 只 `source_env_if_exists ~/.claude-account/<组>.env`，永不被 UI 改写 |
