# dotfiles

这台机器（`vps_oracle`）上一部分不属于 docker compose、也不属于 k3s 的**本机配置**，用软链的方式纳入本仓库管理：真身放在这个目录下由 git 追踪，原本的位置（`$HOME` 或系统目录）变成指向这里的软链。这样编辑、看历史、回滚都走 git，不用记两份。

## 谁链到哪、是什么

| 仓库内路径 | 软链到（系统里的真实路径） | 是什么 |
|---|---|---|
| `claude/CLAUDE.md` | `~/.claude/CLAUDE.md` | Claude Code 全局助理指令（跨所有项目生效，不只是这个仓库）：沟通风格、任务前先讲approach、git/shell/testing/security 的默认规矩、以及一条 Superpowers Policy（K8s/Compose/YAML 这类明确的运维改动不用跑 superpowers 流程，逻辑代码改动按需跑，混合/不确定的情况先问）。里面关于"绝对路径要配重建脚本"那条就是因为搭这套 dotfiles 方案才加的 |
| `claude/claude-direnv-wrapper.sh` | `~/.claude/claude-direnv-wrapper.sh` | VS Code 扩展 `claudeCode.claudeProcessWrapper` 设置指向的包装脚本：`source direnv-load.sh` 后 `exec` 真正的 claude 进程，让 claude 进程也能吃到当前目录的 direnv 环境变量。若扩展没能把 claude 二进制路径当第一个参数传进来（2026-08-23 实际复现过一次：扩展自己解析内建二进制路径失败，静默漏传路径参数，`$1` 直接变成一个 `--xxx` flag），bash 的 `exec` 内建会把这个 flag 误当成自己的选项解析，报 `exec: --: invalid option`——补了个判断：`$1` 不是真实可执行文件时退回 PATH 里的 `claude`，不会整个 spawn 失败 |
| `claude/direnv-load.sh` | `~/.claude/direnv-load.sh` | 对当前目录跑 `direnv export bash` 并 `eval` 结果，`timeout 5` 防止 direnv 卡住；没装 direnv 或没有 `.envrc` 时安静跳过。被下面两个脚本和 wrapper 脚本 source |
| `claude/direnv-bash-env.sh` | `~/.claude/direnv-bash-env.sh` | 非交互 bash 的 `$BASH_ENV`：交互式 shell（`$-` 里带 `i`）直接 return，只在非交互场景（Claude Code 的 Bash 工具起的子进程、claude 进程本身）自动 source `direnv-load.sh`，让这些非交互场景也能拿到当前目录的 direnv 环境变量 |
| `claude/settings.json` | `~/.claude/settings.json` | Claude Code 的权限规则（allow 列表）、hooks 注册、`enabledPlugins`/`extraKnownMarketplaces` 这些真正值得纳管的部分。`claude-code-notify` 的 `install.sh` 部署时会往这个文件的 `hooks.Stop`/`hooks.StopFailure`/`hooks.PermissionRequest` 里自动写入三条 command hook（指向 `~/.claude/claude-code-notify/hooks/*.sh`），软链之后这个自动改写照常发生在仓库里的真身上，改动会体现在 `git diff` 里，不需要手动同步。**但整份文件是唯一一份 `~/.claude/settings.json`**，Claude Code 没有 global 层级的 `settings.local.json` 可拆分易变字段，所以 `model`/`theme`/`tui`/`effortLevel`/`switchModelsOnFlag`/`remoteControlAtStartup`/`agentPushNotifEnabled`/`autoMode.environment` 这些纯 CLI 会话偏好也被一起带进了 git（`/model`、`/theme` 之类交互操作会直接写盘到这份文件，是 Claude Code 自身的行为，改不了）。这些字段的 diff 没有配置审计价值，不用为它们专门找 commit 时机，等下次因为 permissions/hooks 有实质变化要提交时顺手带上就行；`model` 这个字段尤其可以直接忽略——`ANTHROPIC_MODEL` 环境变量的优先级高于这里的 `model` key，真要固定默认模型应该设在 `shell/.bashrc`（也在本仓库纳管）里，而不是靠这个 key |
| `claude-code-notify/.claude-code-notify-hooks.json` | `~/.claude/.claude-code-notify-hooks.json` | **不是要手动编辑的配置，是 `claude-code-notify` 的 `install.sh`/`installer.py` 自己管理的状态文件**（`installer.py` 里 `STATE_FILENAME = ".claude-code-notify-hooks.json"`，`load_state`/`save_state` 读写它）：记录它在 `settings.json` 里注册了哪些 hook 条目，方便下次 reinstall/uninstall 时准确识别哪些是自己装的、能安全移除。纳管这份的价值是留一份"当前实际注册了哪些 hook"的历史记录，不是给人改的 |
| `claude-code-notify/config.env` | `~/.claude/claude-code-notify/config.env` | **真身，不进 git**（原因见下一节）。`ROUTE_<n>_DIR`/`ROUTE_<n>_CHAT_ID`/`ROUTE_<n>_BOT_TOKEN` 用最长前缀匹配决定某个目录下跑的 session 该通知到哪个 Telegram chat、用哪个 bot，未命中的目录退回文件开头 `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID` 这两个全局默认值 |
| `claude-code-notify/config.env.example` | （不软链，直接进 git） | 上面那份的占位符模板：保留 `ROUTE_<n>_DIR` 结构（哪些目录配了独立路由这件事本身有记录价值）和非敏感项（`NOTIFY_RATELIMIT_SECONDS` 等），但 `CHAT_ID`/`BOT_TOKEN` 换成占位符 |
| `shell/.bashrc` | `~/.bashrc` | bash 交互式 shell 启动配置。前 117 行是 Debian 默认模板（history、彩色 prompt、`ls`/`grep` 系列 alias、bash completion），没改过；后面是这台机器加的：`bun`/`nvm`/`opencode` 的 PATH、`direnv hook bash`、`sdkman`（官方要求必须放文件最后）、`KUBECONFIG`，以及 `ds-on`/`ds-off` 这对 alias——临时把 `~/.claude/.credentials.json` 挪开、改用 `ANTHROPIC_BASE_URL` 指向 DeepSeek 网关，`ds-off` 再挪回来切回官方订阅。`ds-on` 原本把 DeepSeek key 直接写死在这里，2026-08-23 发现后拆到了 `.bash_secrets`（见下） |
| `shell/.bash_aliases` | `~/.bash_aliases` | 被 `.bashrc` 顺手 source。四条 alias：`clauded`（`claude --dangerously-skip-permissions` 的简写）、`tmuxac`/`tmuxkc`（attach/kill 名叫 `claude` 的 tmux session）、`tmuxec`（跑 `~/claude/jerome/start-claude.sh`） |
| `shell/.bash_secrets` | `~/.bash_secrets` | **真身，不进 git**。目前只有一行：`ds-on`/`ds-off` 用的 `DEEPSEEK_API_KEY`。`.bashrc` 用 `[ -f ~/.bash_secrets ] && . ~/.bash_secrets` 引入，不存在时安静跳过（不会导致 shell 启动失败） |
| `shell/.bash_secrets.example` | （不软链，直接进 git） | 上面那份的占位符模板 |
| `shell/.profile` | `~/.profile` | login shell 环境变量。标准 Debian 模板（source `.bashrc`、把 `~/bin`、`~/.local/bin` 加进 PATH）+ JetBrains Toolbox 加的一行 PATH + `KUBECONFIG` |
| `git/.gitconfig` | `~/.gitconfig` | **故意不设全局 `user`/`credential`**——只有 `~/jerome/`、`~/bridget/`、`~/evidence/` 三个 account 目录能提交（各自 includeIf 提供身份）。非 account 目录下 commit 会 `fatal: 无 user.name`，这是有意的安全约束，防止用错误身份提交；以后需要新的提交目录就加一条 includeIf |
| `git/.gitconfig-jerome` | `~/.gitconfig-jerome` | jerome account 的 git 身份（`Jerome Jiang`）和 credential helper 指向 `git-credential-gh-token`（动态读 `~/.gh-token-jerome`）。被 `includeIf gitdir:~/jerome/` 引用。与 bridget/evidence 结构完全对称 |
| `git/.gitconfig-bridget` | `~/.gitconfig-bridget` | bridget account 的 git 身份（`Bridget Lai`）和 credential helper 指向 `git-credential-gh-token`（动态读 `~/.gh-token-bridget`）。被 `includeIf gitdir:~/bridget/` 引用 |
| `git/.gitconfig-evidence` | `~/.gitconfig-evidence` | evidence account 的 git 身份（`Jerome Jiang`）和 credential helper 指向 `git-credential-gh-token`（动态读 `~/.gh-token-evidence`）。被 `includeIf gitdir:~/evidence/` 引用 |
| `git/git-credential-gh-token` | （不软链，直接进 git） | **git credential helper**：认证时根据当前 repo 目录自动判断 account（`~/jerome/`/`~/bridget/`/`~/evidence/`），从 `~/.gh-token-<account>` 实时读 token 拼出凭据。token 唯一来源是 `~/.gh-token-*`，**没有 `.git-credentials-*` 文件**，换 token 只改一处下次 git 自动用新的 |
| `shell-env/bridget.envrc` | `~/bridget/.envrc` | bridget 项目目录的 direnv 环境：source `~/.claude-provider/bridget.env` + `~/.claude-account/bridget.env`（这两个是真密钥，不纳管）、`GH_TOKEN` 运行时 cat `~/.gh-token-bridget`。内容无字面密钥，直接进 git |
| `shell-env/jerome.envrc` | `~/jerome/.envrc` | jerome 项目目录的 direnv 环境：source claude provider/account env + `GH_TOKEN` 运行时 cat `~/.gh-token-jerome`（与 bridget/evidence 结构完全对称） |
| `shell-env/evidence.envrc` | `~/evidence/.envrc` | evidence 项目目录的 direnv 环境：source claude provider/account env + `GH_TOKEN` 运行时 cat `~/.gh-token-evidence` |
| `claude-jerome/CLAUDE.md` | `~/claude/jerome/CLAUDE.md` | `tmuxac` alias 启动的独立 Claude 实例（DevOps persona）的项目级指令 |
| `claude-jerome/start-claude.sh` | `~/claude/jerome/start-claude.sh` | 在 tmux session 里启动那个独立 Claude 实例的脚本（被 `.bash_aliases` 的 `tmuxac` 引用） |
| `claude-jerome/.claude/settings.local.json` | `~/claude/jerome/.claude/settings.local.json` | 那个实例的 Claude Code 权限规则（大量 docker/journalctl 只读 allow）。无密钥，纳管；靠 `.gitignore` 的 `!` 例外绕开全局 `settings.local.json` 忽略规则 |
| `config/git-ignore` | `~/.config/git/ignore` | git 全局忽略规则（当前只有一条 `**/.claude/settings.local.json`） |
| `config/rclone.conf` | `~/.config/rclone/rclone.conf` | rclone 配置。含 OAuth token，**真身 gitignore 挡，只 `rclone.conf.example` 进 git**（见下） |
| `config/gh-config.yml` | `~/.config/gh/config.yml` | GitHub CLI 的全局配置（git_protocol、editor、aliases 等），无密钥 |
| `config/gh-hosts.yml` | `~/.config/gh/hosts.yml` | GitHub CLI 的主机认证信息，含 `oauth_token`，**真身 gitignore 挡，只 `gh-hosts.yml.example` 进 git** |
| `config/helm-repositories.yaml` | `~/.config/helm/repositories.yaml` | helm 的 repo 列表（cilium/argo/kyverno/trivy-operator/sealed-secrets/aqua），无密钥 |
| `vscode/machine-settings.json` | `~/.vscode-server/data/Machine/settings.json` | VS Code Server 机器级设置：`claudeCode.claudeProcessWrapper` 指向上面那支 wrapper 脚本、`claudeCode.allowDangerouslySkipPermissions`、`claudeCode.useTerminal`、git 默认 clone 目录等。注意这是 `~/.vscode-server/` 里当前这一份 server 数据目录下的文件，不是随扩展版本升级的东西 |
| `link.sh` | — | 重建以上所有软链的脚本，见下 |

**没有纳管、以后也不要往这个目录塞的东西**：`~/.claude/.credentials.json`、`~/.claude/history.jsonl`、`~/.claude/stats-cache.json`、`~/.claude.json`、`~/.gh-token-*`、`~/.git-credentials-*`、`~/.bash_history`、`~/.viminfo` 这类真密钥或纯本机生成状态——即使软链也不该进 git，仓库 `.gitignore` 也没有为它们开例外。`claude-code-notify` 工具本体（`~/.claude/claude-code-notify/` 里的 `claude_code_notify/`、`hooks/`、`state/`、`debug.log`）是另一个独立仓库（`~/jerome/claude-code-notify`）`install.sh` 部署出来的产物，这里只管它的**配置**，不管它本身。

## GitHub token 的单一来源（每个账号一个 token，一处存储）

三个 account（jerome/bridget/evidence）各有一个 GitHub token，**只存在 `~/.gh-token-<account>` 一处**（裸 token）。两个消费者都从这里读：

| 消费者 | 怎么读 |
|---|---|
| `.envrc` `export GH_TOKEN` | `cat ~/.gh-token-<account>`（给 gh CLI 等）|
| git https 认证 | `git/git-credential-gh-token` helper：git 认证时实时 `cat ~/.gh-token-<account>` 拼出凭据 |

**没有 `.git-credentials-*` 文件**——git 不再用 `store` helper，改用自定义 helper 动态读。**换 token 只改 `~/.gh-token-<account>` 一处**，git 下次认证自动用新值，不需要任何同步步骤。

helper 里写死了"account → GitHub 用户名"映射（jerome→Jeromefromcn、bridget→BridgetLai、evidence→Jeromefromcn），加新 account 要在 `git-credential-gh-token` 里加映射、加一条 includeIf、建 `.envrc`。

## 带密钥的文件怎么处理：真身 + `.example`

`config.env`（Telegram bot token）、`.bash_secrets`（DeepSeek API key）、`config/rclone.conf`（gdrive OAuth token）、`config/gh-hosts.yml`（GitHub CLI oauth_token）都属于"文件大部分内容值得纳管，但里面混了真密钥"的情况，处理方式跟本仓库每个 compose 栈自己的 `.env` 一样：真身放仓库里但被 `.gitignore` 挡住（`config.env` 靠 `*.env` 规则、`.bash_secrets` 靠专门加的 `.bash_secrets` 规则、`rclone.conf`/`gh-hosts.yml` 靠专门加的路径规则，`git add --dry-run` 可以验证——`git check-ignore` 在只匹配到 `.gitignore` 里 `!` 开头的排除规则时，非 verbose 和 `-v` 两种模式给的 exit code 不一致，容易看错，别用它做最终判断），只有占位符版本的 `*.example` 进 git 留个结构记录。改真实值就改真身（软链目标那份），结构变了（比如加一条新的 `ROUTE_N`、换一个 gdrive 账号）记得同步更新 `.example`。

`.bashrc` 是反过来的处理方式：整份文件本身没有秘密性，只是其中一行字面值是密钥，所以没有整份拆两份，而是把那一行单独抽到 `.bash_secrets` 里，`.bashrc` 改成引用变量（`$DEEPSEEK_API_KEY`）而不是字面值——`.bashrc` 本身照常进 git，看得到 `ds-on` 这个 alias 的完整逻辑，只是取不到真实 key。

## VS Code 的 reconnection-grace-time（记一笔，这台机器上管不到）

VS Code 断线重连的宽限时间目前被设成 24 小时（`ps aux` 能看到跑起来的 `code-* command-shell --reconnection-grace-time 86400`，即 `VSCODE_RECONNECTION_GRACE_TIME=86400000ms`；VS Code Server 自己的内建默认值只有 3 小时，`108e5ms`，明显是被覆盖过的）。

查过：这个 `command-shell --reconnection-grace-time 86400` 是本机 VS Code 客户端 SSH 连进来时自己组出来送过来执行的命令行参数，**不是这台服务器上任何文件配置出来的**——这台机器上只看得到执行结果（`ps aux`、日志里的 `VSCODE_RECONNECTION_GRACE_TIME`），看不到设置来源。真正的开关大概率在本机 VS Code 的 User Settings（`remote.SSH.*` 之类）或本机 SSH config 里，那份配置活在本机，这台服务器上没有对应的文件，`vscode/machine-settings.json`（远端 Machine 级设置）管不到它，这套 dotfiles 机制也纳管不了。以后再想不起"24 小时那个是哪里设的"，先看这条，别再满机器搜一遍。

## 用 link.sh 重建软链

这个目录本身可以移动（仓库整个搬家，或者换一台新机器重新 clone），但软链里存的是当时的绝对路径，搬完不会自动跟着变。跑一次 `link.sh` 就会把上表里每一项重新连好：

```bash
./link.sh          # 只处理"目标路径不存在"或"软链指向别处"的情况，不碰已经存在的真实文件
./link.sh --force  # 连真实文件也覆盖（新机器上原本就有一份默认 .bashrc 之类，需要这个才会覆盖）
```

新机器上第一次跑，大概率需要 `--force`——系统会自带一份默认的 `.bashrc`/`.gitconfig` 之类，不是软链，脚本默认不会动它。

## 加一个新文件进来

1. 确认不含真实密钥（含密钥的按 `config.env` 的模式拆成真身 + `.example`）
2. 复制到这个目录下对应的子目录（没有合适的子目录就新建一个），保留原文件名
3. 用 `ln -sf <仓库里的路径> <系统里的原路径>` 把原路径接管成软链，`readlink` 确认一下
4. 把新文件加进 `link.sh` 的 `PAIRS` 数组，加进上面的表格
5. `git add` 对应文件（`.example` 记得也一起加，真身会被 `.gitignore` 自动挡掉）
