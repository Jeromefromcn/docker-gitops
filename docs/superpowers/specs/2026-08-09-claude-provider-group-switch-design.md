# Claude Code 分组级 Provider 切换 — 设计文档

- 日期：2026-08-09
- 状态：设计已确认，待实施
- 涉及主机：vps_oracle（`instance-20260321-2043`，内网 10.0.0.95）

---

## 1. 背景与动机

Claude Code 官方订阅的 token 额度不够用，而额外购买 token 的单价很高。替代方案是再买一份智谱 AI 的订阅，让 Claude Code 在需要时切换到智谱的模型上跑。

但「切换」不能是全局的。本机 `~/jerome/` 下有约 19 个项目，重要程度和复杂度差别很大：

- 一部分项目（复杂重构、架构设计、生产系统）必须用 Claude 官方的高级模型
- 另一部分（刷题、写文案、实验性项目）用智谱完全够用，能省下大量额度

**核心诉求是隔离**：把 B 组降级到智谱，绝不能顺带把 A 组也降级。用户明确表达的担忧是——「我担心的是我对其中一组降级之后会默认影响到另外一组需要更高级模型的项目」。

这个担忧决定了整个设计的评价标准：**任何会静默串组的机制都不可接受**，哪怕它更简洁。

### 1.1 需求清单

| # | 需求 | 来源 |
|---|---|---|
| R1 | 两组项目的 provider 配置互相隔离 | 用户核心诉求 |
| R2 | 有 UI 可以按分组开关（官方 / CCR） | 用户明确要求 |
| R3 | UI 显示的是**真实情况**，不是「上次点了什么」 | 用户明确要求 |
| R4 | UI 每次打开都现场查询，不记录状态 | 用户明确要求 |
| R5 | CCR 用 Docker 部署，尽量省资源 | 用户明确要求 |
| R6 | 目录级环境切换用 direnv | 用户明确要求（后经验证保留） |

---

## 2. 探索过程

这一节记录设计过程中走过的弯路和拿到的证据。结论不是一开始就对的，中间翻过两次案。

### 2.1 起点：direnv 看起来是显然的答案

用户已经有一套成熟的 direnv 实践，用于按目录隔离 git token：

- `~/.claude/direnv-bash-env.sh`：对当前目录跑 `direnv export bash` 并 eval
- `~/.claude/settings.json` 的 `env` 里设 `BASH_ENV` 指向它

原理是 bash 的内建行为——**非交互式 bash 启动时，若 `BASH_ENV` 已设置，会先 source 它指向的文件**。这恰好匹配 Claude Code 每次 Bash 工具调用都新拉一个 `bash -c` 的模式。该方案已处理两个坑：

1. **无限递归**：`direnv export` 内部会再拉一个 bash 解析 `.envrc`，它继承同一个 `BASH_ENV`，于是又调 `direnv export`……修法是 `BASH_ENV= direnv export bash` 清空这一层
2. **stdin 挂起**：底层给 bash 的 stdin 是不发 EOF 的管道，`direnv export` 会卡死等 stdin。修法是 `</dev/null`

自然的想法是：provider 切换照搬这套即可。

### 2.2 第一次翻案：BASH_ENV 抬不动 provider

查进程树发现问题：

```
3707132  server-main.js                     ← VSCode server，所有窗口共用
└─ 4000770  extensionHost                   ← 连上 SSH 时就启动，环境此后固定
   └─ 4003147  .../native-binary/claude --setting-sources=user,project,local ...
```

用户用的是 VSCode 插件，`claude` 是 extensionHost **直接 spawn** 的子进程，中间**没有 bash**。没有 bash 进程，`BASH_ENV` 这个 bash 内建行为就永远不会触发。

更根本的原因是**进程方向**：

| | git token 场景 | provider 场景 |
|---|---|---|
| 变量消费者 | `git`（bash 的**下游**） | `claude` 进程本身（bash 的**上游**） |
| BASH_ENV 能否覆盖 | ✅ | ❌ 子进程改不了父进程环境 |

实测佐证——`/proc/4004115/environ` 里 `ANTHROPIC*` / `DIRENV*` 一片空白。

同时测出 `BASH_ENV` 机制本身的一个边界：

| 场景 | direnv 变量可见？ |
|---|---|
| Bash 工具子进程，且**启动 cwd 就有 `.envrc`** | ✅ |
| Bash 工具里 `cd` 进去**之后** | ❌ `BASH_ENV` 在进程启动时就跑完了 |

即：`BASH_ENV` 求值的是 bash **启动时**的 cwd，命令内部再 `cd` 不会重新求值。

### 2.3 中途方案：项目级 settings.local.json（后被否决）

注意到命令行有 `--setting-sources=user,project,local`，说明项目级 `.claude/settings.json` / `settings.local.json` 会被读取，而 `env` 是合法键（用户全局配置里就用它设了 `BASH_ENV`）。

用假 endpoint 做 probe 实测（起监听、看 claude 连哪里，请求发不到真 API 所以零 token 成本）：

```
CONNECTED from ('127.0.0.1', 51274)
POST /v1/messages?beta=true HTTP/1.1
Authorization: Bearer dummy-probe-token        ← token 也被覆盖了
User-Agent: claude-cli/2.1.226 (external, claude-vscode, agent-sdk/0.3.226)
```

**确认有效**：项目级 `settings.local.json` 的 `env` 能同时覆盖 endpoint 和 auth token，且对终端和插件两条启动路径都生效。

顺带排除了另一个候选 `claudeCode.environmentVariables`——它是 `"scope": "machine"`，VSCode 里**不能按 workspace 设**，对分组无用；而且它的描述里自己写着 "Prefer setting environment variables in Claude's settings.json"。

当时的结论是放弃 direnv、改用 settings.local.json。**这个结论后来被推翻了。**

### 2.4 第二次翻案：用户反问，找到 claudeProcessWrapper

用户追问：BASH_ENV 那套思路真的不能复用吗？

重新审视后发现——**方向判断没错，但结论收敛太早**。BASH_ENV 抬不动 provider 是对的，但用户的**思路**（找一个每次启动都必经的钩子，在钩子里对当前目录求值 direnv）完全可以移植，只要找到 claude 进程自己的那个钩子。

翻扩展的 `package.json` 找到了：

```json
"claudeCode.claudeProcessWrapper": {
  "type": "string", "scope": "machine",
  "description": "Executable path used to launch the Claude process."
}
```

再从 `extension.js`（2.5MB 压缩代码）里 grep 出 `resolveClaudeBinary()` 的实现：

```js
if (e) return { pathToClaudeCodeExecutable: e,
                executableArgs: r ? (n ? [n, r] : [r]) : [], env: t }
```

`e` 是配置的 wrapper 路径，真 binary 被塞进 `executableArgs` 当参数传给它。**所以 wrapper 只要 `exec "$@"`，不用硬编码 claude 路径，扩展升级也不会坏。**

另外两个前提也验证了：
- claude 进程的 cwd 就是 workspace 目录（`/proc/4003147/cwd -> /home/ubuntu/jerome/docker-gitops`）
- 终端路径本来就有 direnv hook（`~/.bashrc:136` 有 `eval "$(direnv hook bash)"`）

实测 wrapper 机制：

```
CONNECTED
HEAD /api/hello HTTP/1.1
User-Agent: Bun/1.4.0
Host: 127.0.0.1:59998        ← .envrc 里写的地址
```

claude 进程启动后对 `.envrc` 指定的 endpoint 发了连通性预检。**direnv 的变量确实进到了 claude 进程本身。**

于是方案回到 direnv。四种机制的最终对比：

| 机制 | 终端启动 | VSCode 插件 | 能否按目录 |
|---|---|---|---|
| `BASH_ENV` + direnv | ✅ | ❌ 中间没有 bash | ✅ |
| `claudeCode.environmentVariables` | ❌ | ✅ | ❌ machine scope |
| 项目级 `settings.local.json` 的 `env` | ✅ | ✅ | ✅ |
| **`claudeProcessWrapper` + direnv** | ✅（用现成 hook） | ✅ | ✅ |

### 2.5 direnv 胜出的决定性理由

回到 direnv 不只是「也能用」，它比 settings.local.json 强一档，因为 **`.envrc` 可以动态求值**：

```bash
# 项目/顶层目录的 .envrc —— 写一次，永不再改
source_env_if_exists ~/.claude-provider/jerome.env
```

于是**切换一个分组 = 改一个文件**，而不是遍历 19 个项目重写 `settings.local.json`。连带解决三件事：

1. 智谱 key 只存一份，轮换即生效，不会散进 19 个项目、也不会误提交
2. 分组内不可能不一致（所有项目读同一个文件），原本要设计的 `mixed`（组内配置不一致）状态直接消失
3. R4「不记录状态」变成字面真实——UI 读的就是唯一的配置文件，系统里没有任何副本

### 2.6 direnv 信任模型：一条硬约束

UI 要反复改写配置文件，必须先确认 direnv 的信任机制会不会每次都要求重新 `direnv allow`。如果会，开关就没意义了。实测：

| 操作 | 结果 |
|---|---|
| `direnv allow` 后正常读 | `PROVIDER=official` ✅ |
| **改写被 `source_env_if_exists` 引用的文件**（不重新 allow） | `PROVIDER=zhipu` ✅ 立即生效 |
| 改 `.envrc` 本身 | **变量整个消失** ❌ direnv 拒绝加载 |

**由此定死一条设计约束：`.envrc` 必须静态、写一次不动；UI 只改写它 source 的那个文件。**

附带一个好性质：万一 `.envrc` 被改坏，变量是**消失**而非变错，claude 退回官方订阅——失败方向是安全的，不会静默漏到智谱。

### 2.7 CCR 定位的两次翻转

- **一开始**认为 CCR 可能多余：智谱提供 Anthropic 兼容 endpoint，直接设 `ANTHROPIC_BASE_URL` 就能用，省一个容器
- **中途**（settings.local.json 方案下）找到一个支持 CCR 的理由：真 key 会被写进 19 个项目的配置文件，用 CCR 中转则项目里只写本地地址，密钥收敛在容器里
- **最后**这个理由随着 direnv 方案作废了——direnv 下 key 本来就只有一份

最终由用户决定保留 CCR，**唯一理由是模型分流**（把 background / think / longContext 分派给不同档位的模型）。这是一个有意识的取舍：多一个容器和一层故障点，换按任务类型控制成本的能力。

### 2.8 分组方式

考虑过三种：中心 yaml 查表、项目自己声明、路径前缀自动归组。

用户选择路径前缀，并提出一个改进——**不在 `~/jerome/` 下面建子目录，而是在它同级建第二个目录**。这样现有 19 个项目一个都不用动。采纳。

---

## 3. 最终设计

### 3.1 整体数据流

```
启动 claude
 ├─ 终端      → ~/.bashrc 的 direnv hook（已有，不用改）
 └─ VSCode    → claudeCode.claudeProcessWrapper → direnv-load.sh
                        │
                        ↓ direnv 按 cwd 向上找最近的 .envrc
   ~/jerome/.envrc      → source_env_if_exists ~/.claude-provider/jerome.env
   ~/bridget/.envrc     → source_env_if_exists ~/.claude-provider/bridget.env
                        │                          ↑ UI 的唯一写入点
                        ↓ ANTHROPIC_BASE_URL
              ├─ 未设置              → 官方订阅 OAuth（~/.claude/.credentials.json）
              └─ 127.0.0.1:3456     → CCR 容器 → 智谱 GLM（按规则分流）
```

### 3.2 目录布局

```
~/jerome/                 jerome 组，19 个项目原地不动
    .envrc                ← 新增，唯一改动；静态
    quant-trading-system/
    betting-lab/
        .envrc            ← 已存在，需在首行加 source_up
    ...

~/bridget/                bridget 组
    .envrc                ← 静态
    <项目>/

~/.claude-provider/
    jerome.env            ← UI 只改这两个文件
    bridget.env
```

**命名约定**：分组名 = 目录名 = env 文件名（`~/<组名>/` ↔ `~/.claude-provider/<组名>.env`）。加第三组时照此推广，见 3.11。

项目自身**不需要** `.envrc`——direnv 会向上找到最近的一个。

> ⚠️ direnv 取的是**最近的一个** `.envrc`，**不叠加**。项目若有自己的 `.envrc` 会遮蔽顶层的。当前 19 个项目里只有 `betting-lab` 属于这种情况（它的 `.envrc` 内容是 `source ./venv/bin/activate`），需在首行补 `source_up`。

### 3.3 宿主机脚本

三个文件，共享一份逻辑，两个已知的坑（递归、stdin）只收在内核里，只需修一处。

**`~/.claude/direnv-load.sh`** — 唯一的真实逻辑，被 source

```bash
# 对当前目录求值 direnv 并注入环境变量。被 source，不要 exit。
if command -v direnv >/dev/null 2>&1; then
  __d="$(BASH_ENV= timeout 5 direnv export bash 2>/dev/null </dev/null)"
  [ -n "$__d" ] && eval "$__d"
  unset __d
fi
```

**`~/.claude/direnv-bash-env.sh`** — 现有文件瘦身，行为不变

```bash
case $- in *i*) return 0 2>/dev/null || exit 0 ;; esac
. /home/ubuntu/.claude/direnv-load.sh
```

**`~/.claude/claude-direnv-wrapper.sh`** — 新增

```bash
#!/usr/bin/env bash
. /home/ubuntu/.claude/direnv-load.sh
exec "$@"          # 真 binary 由扩展当参数传进来
```

配置：VSCode 设置 `claudeCode.claudeProcessWrapper` = `/home/ubuntu/.claude/claude-direnv-wrapper.sh`（machine scope，在 Remote [SSH] 标签页设），改完 Reload Window。

### 3.4 分组配置文件

`~/.claude-provider/jerome.env`、`~/.claude-provider/bridget.env`。

**初始状态**：`jerome.env` 为官方，`bridget.env` 为 CCR。

**官方状态** = 文件为空（或只有注释）。不设 `ANTHROPIC_*`，claude 走订阅 OAuth。

**CCR 状态**：

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:3456
export ANTHROPIC_AUTH_TOKEN=<CCR 本地口令>
```

`<CCR 本地口令>` 是本机自签的一个随机串，跟智谱 key 无关，作用只是让 CCR 拒绝非本机来源的请求。它同时出现在 `~/.claude-provider/*.env` 和 CCR 的配置里，两处必须一致。真正的智谱 key 只存在 `vps_oracle/compose/ccr/.env`，不进任何分组文件。

> 切回官方是**清空文件**，不是把值设成空字符串。空字符串是否仍会覆盖 OAuth 凭据尚未验证，实施时必须用 2.3 节的 probe 手法实测确认。

### 3.5 CCR 栈

`vps_oracle/compose/ccr/`

- 镜像 pin 具体 tag
- `ports: 127.0.0.1:3456:3456`
- 真智谱 key 放 `vps_oracle/compose/ccr/.env`（`.gitignore` 已覆盖 `.env` 和 `*.env`）
- 分流规则：background 走便宜档，其余走主力档（具体模型待定，见开放项）

> ⚠️ **对仓库约定的有意例外**：README 约定「管理面板/内部服务一律不发布端口，统一走 NPM 反代」。CCR 必须发布端口，因为消费者 `claude` 跑在**宿主机上而非容器里**，走不了 docker 网络。缓解措施是绑 `127.0.0.1`，不对外暴露。这条要写进 compose 文件的注释。

已确认宿主机 3456 端口空闲（`vikunja` 容器内部也用 3456，但没有发布到宿主机，不冲突）。

### 3.6 开关 UI

`vps_oracle/compose/provider-switch/`

沿用仓库里 `vikunja/notify-relay` 的既有模式：**单个 `app.py`，`python:3.12-alpine`，纯标准库无框架**。参考镜像约 88MB，常驻内存十几 MB，满足 R5。

| 端点 | 行为 |
|---|---|
| `GET /` | 现场扫描并返回页面，**不读任何缓存** |
| `POST /toggle` | 原子改写对应分组的 `.env` |

- 挂载 `~/.claude-provider/` 进容器
- `notify-relay` 用 `USER nobody`，但本服务要写宿主机文件，需跑在 uid 1001（`ubuntu`）下

### 3.7 「真实情况」的判定（R3 / R4）

每个分组显示三个独立信号，缺一不可：

1. **配置**：`<group>.env` 里有没有 `ANTHROPIC_BASE_URL`
2. **连通**：真去请求当前指向的 endpoint。CCR 容器挂了就是红灯——只看配置就报「已切到智谱」是假的
3. **待生效**：该分组下**正在运行**的 claude 进程数（`pgrep -f native-binary/claude` 配合比对 `/proc/<pid>/cwd`）

第 3 条是必需的，因为**环境变量在进程启动时读定，切换只对新开的会话生效**。UI 必须让用户看见「还有 N 个会话挂在旧 provider 上」，否则 R3 无法真正满足。

### 3.8 错误处理

- 写文件用「写 tmp + `rename`」原子替换，避免 direnv 读到半个文件
- CCR 探活失败：显示红灯但**不阻止**切换（用户可能正要切走）
- `.envrc` 若被改动导致 direnv 拒绝加载，退化为官方订阅——安全方向

### 3.9 测试策略

| 层 | 方法 |
|---|---|
| 脚本 | 给定 cwd，断言 `direnv export` 后的变量集合正确 |
| UI | 起容器 curl `/` 和 `/toggle`，断言文件内容变化 |
| 端到端 | 切换 → 新开会话 → 查 `/proc/<pid>/environ`，**零 token 成本** |
| wrapper | 分两阶段：先用空转 wrapper（只有 `exec "$@"`）确认 VSCode 能正常启动 claude，再换完整版。回滚 = 删设置 + Reload Window |

### 3.10 仓库约定

两个新栈都需满足 README 约定：`TZ: "Asia/Hong_Kong"`、logging 10m×5、`restart: unless-stopped`、pin 具体 tag、`security_opt: [no-new-privileges:true]`、挂 `proxy` 外部网络。

- UI 接 NPM 反代：`provider.jerome.cloudns.asia`，Access List 选 `self-only`，按 README 的表格配置（注意 Force SSL / HTTP/2 保存后会被静默重置，需复查）
- 两个服务都要加 homepage 卡片（`vps_oracle/compose/homepage/config/services.yaml`），描述用英文
- CCR 的端口发布例外见 3.5

### 3.11 交付物：`vps_oracle/compose/ccr/README.md`

实施收尾必须写这份文档，目标读者是几个月后想加第三个分组的自己。内容要求：

1. **整体原理速览**——一段话说清 direnv → wrapper → CCR 这条链，附 3.1 的数据流图
2. **加一个新分组的完整步骤**，可照抄执行：
   ```bash
   # 以新增 ~/sandbox/ 组为例
   mkdir -p ~/sandbox
   echo 'source_env_if_exists ~/.claude-provider/sandbox.env' > ~/sandbox/.envrc
   direnv allow ~/sandbox
   touch ~/.claude-provider/sandbox.env          # 空 = 走官方订阅
   # 最后在 UI 的分组配置里登记 ~/sandbox，重启 provider-switch 容器
   ```
3. **必须点名的四个坑**（每条一句话 + 后果）：
   - `.envrc` 只能写那一行，**任何后续改动都要重新 `direnv allow`**，否则变量整个失效（依据 2.6）
   - 组内项目若有自己的 `.envrc`，**会遮蔽组级的**，要加 `source_up`（依据 3.2）
   - 切换**只对新开会话生效**，旧进程不受影响（依据 C1）
   - 把已有项目搬进新组会**断开 `--resume` 的会话历史**（依据 C4）
4. **验证方法**——`/proc/<pid>/environ` 那条零成本检查命令，以及怎么确认新组真的挂上了
5. **改组名/删组的操作**，含 `direnv allow` 记录按绝对路径存这件事（依据 C5）
6. **回滚**——怎么把某个组彻底摘掉、怎么停用 wrapper

> 放在 `ccr/` 下是用户指定的位置。`provider-switch/` 那边只放一行指针链接过来，避免两份文档各说各话。

---

## 4. 已知约束与风险

| # | 事项 | 说明 |
|---|---|---|
| C1 | 切换只对**新开会话**生效 | 环境变量在进程启动时读定。UI 需显式提示并显示在跑的会话数 |
| C2 | `.envrc` 必须静态 | 改它本身会触发 direnv 的信任检查，导致变量整个失效（2.6 实测） |
| C3 | 项目自带 `.envrc` 会遮蔽顶层 | 目前仅 `betting-lab`，需加 `source_up` |
| C4 | 搬项目 / 改目录名会断会话历史 | `~/.claude/projects/` 目录名是路径编码的，`--resume` 找不到旧会话 |
| C5 | 改目录名需重新 `direnv allow` | direnv 授权记录按 `.envrc` 的**绝对路径**存（实测确认） |
| C6 | wrapper 会改变权限模式解析路径 | 扩展源码里有 `resolvePermissionModeInCli: !bn("claudeProcessWrapper")`，设了 wrapper 后改由扩展侧解析。看起来良性，但需留意行为变化 |
| C7 | VSCode 是否真会调用 wrapper 尚未端到端验证 | 已验证 wrapper 的调用契约（读源码 + 手工模拟调用成功），但未实际设置配置项并 Reload。这是实施第一步，也是唯一的未知数 |
| C8 | 智谱 key 已出现在对话记录中 | 配置完成后建议在智谱后台轮换一次 |

---

## 5. 开放项

1. **CCR 分流规则的具体模型**——background / think / longContext 各配哪一档，待定。缺省按「background 走便宜档，其余走主力档」实施
2. **哪些现有项目迁到 bridget 组**——待用户决定。可以留空先跑起来，之后再迁；迁移会触发 C4

> 已关闭：目录名定为 `~/bridget/`，分组名 `jerome` / `bridget`，env 文件名与目录名一致。智谱 key 已提供，存 `vps_oracle/compose/ccr/.env`（gitignored）。

---

## 6. 附：关键实证命令

供后续复现或写总结时引用。

```bash
# 进程树：确认 claude 是 extensionHost 的子进程
ps -eo pid,ppid,args | grep -E "claude|extensionHost"

# claude 进程自身的环境与 cwd
tr '\0' '\n' < /proc/<pid>/environ | grep -iE "ANTHROPIC|DIRENV"
readlink /proc/<pid>/cwd

# 扩展源码里的 wrapper 调用语义
EXT=~/.vscode-server/extensions/anthropic.claude-code-<版本>-linux-arm64
grep -o ".\{200\}claudeProcessWrapper.\{400\}" "$EXT/extension.js"

# 零 token 的 endpoint probe：起监听，看 claude 往哪连
python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',59998));s.listen(1);c,_=s.accept();print(c.recv(300).decode())" &
cd <测试目录> && ./wrapper.sh <真claude> -p hi

# direnv 授权记录按绝对路径存
for f in ~/.local/share/direnv/allow/*; do cat "$f"; done
```
