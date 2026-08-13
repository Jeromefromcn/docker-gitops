# 多账号目录隔离（CLAUDE_CONFIG_DIR）

给不同的项目分组绑**不同的 Claude 订阅账号**，和 provider 切换（官方↔CCR）正交、可叠加。机制是给每个账号一个独立的 `CLAUDE_CONFIG_DIR`，靠 direnv 按目录注入——cd 进哪个目录就是哪个账号。

官方文档：`CLAUDE_CONFIG_DIR` 覆盖默认的 `~/.claude`，**登录态、设置、session 历史、插件全部**存在这个目录下（见 [env-vars 文档](https://code.claude.com/docs/en/env-vars)）。所以每个独立 configDir = 一个独立登录的账号。

## 为什么和 provider 切换正交

- provider 切换改的是动态 `.env` 里的 `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`（走 CCR 时这两行覆盖 OAuth）。
- 账号绑定改的是**静态 `.envrc`** 里的 `CLAUDE_CONFIG_DIR`（指向各自的配置目录）。
- 两者写在不同的文件、不同的层：`.envrc` 永远静态（账号是目录的结构属性），`.env` 才被 UI 改写（provider 是可切的）。所以 **switchboard UI 不用改**。

## 布局（主账号零改动，只给第二个账号开独立目录）

| 分组 | `.envrc` | configDir | 账号 |
|---|---|---|---|
| `~/jerome/` | 维持现状 | 默认 `~/.claude` | 账号A（现有登录/设置/memory 全保留） |
| `~/bridget/` | 加一行 `export CLAUDE_CONFIG_DIR=…` + 原 `source_env_if_exists` | `~/.claude-configs/bridget` | 账号B |

`~/bridget/.envrc` 完整内容：

```bash
export CLAUDE_CONFIG_DIR="$HOME/.claude-configs/bridget"
source_env_if_exists /home/ubuntu/.claude-provider/bridget.env
```

## 一次性登录（每个独立账号做一次）

```bash
mkdir -p ~/.claude-configs/bridget
cd ~/bridget            # direnv 已把 CLAUDE_CONFIG_DIR 注入
direnv allow            # 改了 .envrc 要重新信任一次
claude login            # OAuth 存进 ~/.claude-configs/bridget，绑死账号B
```

之后任何在 `~/bridget/` 下开的 claude session 都用账号B。

## 结果矩阵（每目录 = 固定账号 × 可切 provider）

| 目录 | 官方模式 | CCR 模式 |
|---|---|---|
| `~/jerome/` | 账号A 订阅 | 智谱（账号无关，env 覆盖 OAuth） |
| `~/bridget/` | 账号B 订阅 | 智谱（账号无关） |

走 CCR 时 `ANTHROPIC_BASE_URL` / `AUTH_TOKEN` 覆盖掉 OAuth，configDir 里绑的是哪个账号都不重要——CCR 用自己的智谱 key。

## 坑

1. **configDir 是整盘切，不只是登录态。** `CLAUDE_CONFIG_DIR` 把设置、全局 `CLAUDE.md`、项目 memory（`projects/…`）、MCP 配置、插件**全部**搬走。所以 `~/bridget/` 默认读不到你全局的 `~/.claude/CLAUDE.md` 和 `settings.json`——要保留就软链或复制过去（**别软链 `.credentials.json`**，否则账号隔离就失效了）：

   ```bash
   cd ~/.claude-configs/bridget
   ln -s ~/.claude/CLAUDE.md .
   ln -s ~/.claude/settings.json .   # 想各账号各自改就复制而非软链
   ```

   （`jerome` 走默认 `~/.claude`，不受影响。）

2. **VSCode 扩展有已知 bug（[#30538](https://github.com/anthropics/claude-code/issues/30538)）：扩展自己的 `environmentVariables` 设置不认 `CLAUDE_CONFIG_DIR`。** 但本仓库的注入路径不走那条——`claudeProcessWrapper` 在 shell 层 export 后再 `exec claude`，claude 进程从自己的环境里读到，应能绕开。**接好后务必在 VSCode 里验证账号是否切对**（终端路径不受此 bug 影响）。

3. **`CLAUDE_CONFIG_DIR` 设了仍可能在项目目录留下空 `.claude/`（[#3833](https://github.com/anthropics/claude-code/issues/3833)）。** 只是外观问题，不影响隔离——真正生效的配置仍来自 configDir。

4. **账号是静态的，不像 provider 能 UI 实时切。** 切账号 = cd 到另一个目录（direnv 换 configDir）。已经在跑的 session 环境已定型，开新 session 才生效（和 provider 切换同理）。

## 加第三个账号

```bash
mkdir -p ~/carol ~/.claude-configs/carol
cat > ~/carol/.envrc <<'EOF'
export CLAUDE_CONFIG_DIR="$HOME/.claude-configs/carol"
source_env_if_exists /home/ubuntu/.claude-provider/carol.env
EOF
touch /home/ubuntu/.claude-provider/carol.env
cd ~/carol && direnv allow && claude login
# 再去 switchboard 里登记 carol-ccr 开关 + 重建 switchboard（见 ../README.md「加一个新分组」）
```

## 可选：UI 实时切账号（通常没必要）

若想在**同一个目录**里用 UI 来回切账号（而非靠 cd），得改 switchboard 让它 toggle `CLAUDE_CONFIG_DIR` 在两个预登录的 configDir 之间——但这要求两个 configDir 都先 `claude login` 好，且 switchboard 得改写 `.envrc`（静态文件），会触发 direnv 重新 `allow`，和 README 里「`.envrc` 必须静态」那条原则冲突。目录隔离本身已经够用，不推荐。

## 验证

```bash
# 在 bridget 某项目目录里，确认 configDir 注入对了（用真 claude 同款 wrapper）
cd ~/bridget/any-project
/home/ubuntu/.claude/claude-direnv-wrapper.sh env | grep CLAUDE_CONFIG_DIR
# 应输出 CLAUDE_CONFIG_DIR=/home/ubuntu/.claude-configs/bridget

# 切到 jerome 目录应没有这一行（走默认 ~/.claude）
cd ~/jerome && /home/ubuntu/.claude/claude-direnv-wrapper.sh env | grep CLAUDE_CONFIG_DIR || echo '(unset = 默认 ~/.claude，账号A)'
```
