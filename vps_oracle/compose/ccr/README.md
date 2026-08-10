# vps_oracle/compose/ccr

用 [claude-code-router (CCR)](https://github.com/musistudio/claude-code-router) 把 Claude Code 的后端模型按「项目分组」在**官方订阅**和**第三方 provider（智谱 GLM）**之间切换，并保证**各组互相隔离**——切某一组绝不能影响另一组。

本目录放 CCR 本体；配套的切换 UI 在 `../provider-switch/`。这份 README 是整个分组切换系统的总文档。

## 为什么这样设计

- 订阅 token 不够用，想给「不重要的项目组」改用便宜的智谱 GLM，同时「要高级模型的项目组」继续走官方订阅。
- 关键诉求：**隔离**。降级一组不能静默波及另一组。所以切换的粒度是「目录前缀分组」，而不是全局开关。
- 切换机制用 **direnv**（按当前目录求值环境变量），而不是改 `~/.claude/settings.json` 之类的全局配置——后者一次改全局，正是要避免的。

## 架构：四个零件怎么拼

```
项目目录 ~/jerome/foo/                     项目目录 ~/bridget/bar/
        │                                          │
        │ .envrc (静态)                            │ .envrc (静态)
        ▼                                          ▼
  source_env_if_exists                       source_env_if_exists
  /home/ubuntu/.claude-provider/jerome.env   /home/ubuntu/.claude-provider/bridget.env
        │                                          │
        ▼                                          ▼
  jerome.env: 空(=官方)                      bridget.env: export ANTHROPIC_BASE_URL=…
                                              export ANTHROPIC_AUTH_TOKEN=ccr-profile-…
        │                                          │
        │ direnv 把这两行注入 claude 进程           │
        ▼                                          ▼
  claude 走官方 OAuth                        claude 走 CCR(127.0.0.1:3456) → 智谱
```

四个零件：

1. **静态 `.envrc`**：每个分组目录（`~/jerome/`、`~/bridget/`）根部一个 `.envrc`，内容只有一行 `source_env_if_exists /home/ubuntu/.claude-provider/<组名>.env`。它**永远不变**——所以 `direnv allow` 只在第一次需要，之后切换 provider 不用再 allow。
2. **动态 `.claude-provider/<组名>.env`**：真正被改写的文件。空（或只有注释）= 走官方订阅；有两行 `export ANTHROPIC_BASE_URL=… / ANTHROPIC_AUTH_TOKEN=…` = 走 CCR。**provider-switch UI 是唯一应该改写这个文件的东西。**
3. **CCR**（本目录的 compose 栈）：网关 `127.0.0.1:3456`，管理面板 `127.0.0.1:3458`，容器内 nginx:8080 按路径分流（`/v1/*`、`/messages` 走 gateway，`/`、`/api/ccr/rpc` 走管理面板）。两个宿主端口都只绑 `127.0.0.1`——claude 进程跑在宿主机上、不在容器里，够不到 proxy 网络，只能靠发布的宿主端口；不对外暴露，管理面板要从别的机器访问就走 SSH 端口转发。
4. **provider-switch UI**（`../provider-switch/`）：挂在 `proxy` 网络上的小 HTTP 服务，通过 NPM 反代成 `https://provider.jerome.cloudns.asia`（access list=self-only）。每次打开页面都**实时重扫**（不缓存）各组的 `.env` 状态 + 探测 CCR 是否可达，点按钮就原子地改写对应 `.env`。

direnv 怎么进 claude 进程的两条路：
- **终端**：`~/.claude/direnv-bash-env.sh` 走 `BASH_ENV` 机制，被 claude 起的每个 bash 子 shell source，里面 `. direnv-load.sh` 求值当前目录的 direnv。
- **VSCode 扩展**：机器级设置 `claudeCode.claudeProcessWrapper=/home/ubuntu/.claude/claude-direnv-wrapper.sh`，扩展以 workspace 目录为 cwd 调用 `wrapper <真claude> <args…>`，wrapper 里同样 `. direnv-load.sh` 再 `exec "$@"`，把变量注入 claude 进程本身（不只是子 shell）。

## 当前已配置的分组

| 组名 | 目录 | 默认 provider | 用途 |
|---|---|---|---|
| `jerome` | `~/jerome/` | 官方订阅 | 需要 Opus/Sonnet 的主力项目组 |
| `bridget` | `~/bridget/` | CCR（智谱） | 可以降级到 GLM 的预算组 |

## 加一个新分组（复制即可）

以加一个叫 `alice`、走 CCR 的组为例：

```bash
# 1. 建分组目录 + 静态 .envrc（内容永远不变）
mkdir -p ~/alice
echo 'source_env_if_exists /home/ubuntu/.claude-provider/alice.env' > ~/alice/.envrc

# 2. 建对应的 .env（先空着 = 官方；要走 CCR 用 UI 切，或手写两行 export）
touch /home/ubuntu/.claude-provider/alice.env

# 3. 在 provider-switch 的 status.GROUPS 里登记这个组
#    （编辑 vps_oracle/compose/provider-switch/status.py 的 GROUPS 字典，
#     加 "alice": {"env_path": ".../alice.env"}）

# 4. 重建 provider-switch 让新组出现在 UI 里
cd vps_oracle/compose/provider-switch && docker compose up -d --build
```

然后把这个目录当工作区打开新 claude session 即可。要让这个组走 CCR，去 UI 点按钮，或直接在 `alice.env` 写：
```
export ANTHROPIC_BASE_URL=http://127.0.0.1:3456
export ANTHROPIC_AUTH_TOKEN=<CCR client key>
```

CCR client key（`ccr-profile-…`）在 CCR 管理面板生成；provider-switch 容器通过 `.env` 里的 `CCR_CLIENT_TOKEN` 拿到同一个 key 来写 `.env` 文件。

## 四个坑

1. **`.envrc` 必须保持静态。** 只有它 `source` 的那个 `.env` 文件能变。如果你改了 `.envrc` 本身，direnv 会要求重新 `direnv allow`（信任机制）。所以把可变内容放在 `.env`，`.envrc` 只负责 source。
2. **项目自己的 `.envrc` 会遮蔽分组 env。** direnv 只加载「最深」的那个 `.envrc`，不会自动叠加父目录的。例如 `~/jerome/betting-lab/.envrc` 如果直接 `source ./venv/bin/activate`，就**取代**了 `~/jerome/.envrc`，分组 provider 配置进不来。修法：在项目 `.envrc` 最前面加 `source_up`，先加载父级分组 `.envrc`，再做项目自己的事。
3. **切换只对切换之后新开的 session 生效。** 已经在跑的 claude 进程环境变量已经定型，改 `.env` 不会回头改它。开新 session 才走新 provider。（UI 里那条「Switching only affects sessions started after the switch」就是提醒这个。）
4. **移动项目目录会断 resume 历史。** claude 的 session 历史按项目路径存。把项目从 `~/jerome/x` 挪到 `~/bridget/x` 后，旧 session 记录还在旧路径名下，`claude --resume` 在新路径看不到。切换 provider 不会动历史，但物理移动目录会。

> 注：早期 UI 还有一列「Pending sessions」，想显示「还有几个旧 session 在跑」。从容器的私有 PID 命名空间看不到宿主机进程，要数准得给容器 root + `CAP_SYS_PTRACE` + `pid:host`（被攻破的话能读宿主机进程内存）——代价和这列能提供的安全提示不成比例，所以去掉了，靠上面第 3 条的静态文字承载提醒。

## 验证

```bash
# 1. UI 实时状态（应返回两个组 + 各自 provider + reachable）
curl -sS https://provider.jerome.cloudns.asia/ | grep -oE '<td>(jerome|bridget)</td>|<td>(Official|CCR \(Zhipu\))</td>'

# 2. 某个组目录里 direnv 实际注入了什么（零 token，用真 claude 调用的同款 wrapper）
cd ~/bridget/any-project
/home/ubuntu/.claude/claude-direnv-wrapper.sh env | grep ANTHROPIC

# 3. 隔离：确认改 bridget 不影响 jerome（在 bridget 走 CCR 的同时）
cd ~/jerome && BASH_ENV=/home/ubuntu/.claude/direnv-bash-env.sh bash -c 'echo "${ANTHROPIC_BASE_URL:-(unset=官方)}"'
```

## 重命名 / 删除分组

- **改名**：改 `status.GROUPS` 的 key、把 `~/<旧>/` 目录和 `~/<旧>/.envrc` 一起 `mv` 成新名、`mv /home/ubuntu/.claude-provider/<旧>.env <新>.env`、重建 provider-switch。注意上面第 4 个坑——移动目录会断旧 session 的 resume 历史。
- **删除**：从 `status.GROUPS` 摘掉、删目录和 `.env`、重建 provider-switch。

## 回滚（某组回到官方订阅）

最简单：去 UI 点该组的「Switch to Official」。等价的手动操作是把 `/home/ubuntu/.claude-provider/<组>.env` 清空（只留注释）。已经在跑的 session 仍用旧 provider，开新 session 才回官方。

## CCR 管理面板（改路由 / 加 provider / 生成 client key）

CCR 把管理面板发布在宿主机 `127.0.0.1:3458`（loopback only），需要从本机或 SSH 隧道访问：

```bash
# 在你本地机器上开隧道
ssh -L 3458:127.0.0.1:3458 <server>
# 然后本地浏览器打开 http://127.0.0.1:3458 ，用 .env 里 CCR_WEB_AUTH_TOKEN 的值登录
```

> 没有给 CCR 管理面板单独做 NPM 反代：CCR 容器内 nginx:8080 把 `/v1/*`（模型网关）和 `/`（管理面板）复用在一个端口上，反代过去会把模型网关也一并暴露到公网域名（即便有 access list）。管理面板是低频一次性操作，SSH 隧道够用。所以 homepage 上只有 Provider Switch 卡片，没有 CCR Admin 卡片。

## provider-switch 的 NPM 反代（可复现）

provider-switch 走的是 repo 里所有 NPM 反代服务的标准姿势：挂在 `proxy` 网络，NPM 用容器名 `provider-switch:8091` 反代，access list=`self-only`，HTTPS 用 NPM 自己申请的 Let's Encrypt 证书。一次性创建（token 换取 + 建 proxy host 的完整模式见 `../npm/README.md`）：

```bash
cd ../npm && source .npm-automation.env
docker run --rm --network proxy curlimages/curl:latest sh -c "
TOKEN=\$(curl -sS -X POST http://npm:81/api/tokens -H 'Content-Type: application/json' -d '{\"identity\":\"\$NPM_AUTOMATION_EMAIL\",\"secret\":\"\$NPM_AUTOMATION_PASSWORD\"}' | sed -n 's/.*\"token\":\"\([^\"]*\)\".*/\1/p')
# 1. 先建证书（HTTP-01 challenge，DNS 已有 *.jerome.cloudns.asia 通配）
curl -sS -X POST http://npm:81/api/nginx/certificates -H \"Authorization: Bearer \$TOKEN\" -H 'Content-Type: application/json' -d '{\"provider\":\"letsencrypt\",\"nice_name\":\"provider.jerome.cloudns.asia\",\"domain_names\":[\"provider.jerome.cloudns.asia\"],\"meta\":{\"letsencrypt_agree\":true,\"dns_challenge\":false}}'
# 记下返回的 id（下面 certificate_id 用）
# 2. 再建 proxy host（certificate_id 换成上一步的 id，access_list_id=1 是 self-only）
curl -sS -X POST http://npm:81/api/nginx/proxy-hosts -H \"Authorization: Bearer \$TOKEN\" -H 'Content-Type: application/json' -d '{\"domain_names\":[\"provider.jerome.cloudns.asia\"],\"forward_scheme\":\"http\",\"forward_host\":\"provider-switch\",\"forward_port\":8091,\"certificate_id\":<id>,\"ssl_forced\":true,\"http2_support\":true,\"block_exploits\":true,\"allow_websocket_upgrade\":true,\"access_list_id\":1,\"caching_enabled\":false,\"locations\":[],\"meta\":{\"letsencrypt_agree\":false,\"dns_challenge\":false}}'
"
```

> 为什么 `forward_host` 是容器名 `provider-switch` 而不是 IP：provider-switch 和 NPM 都在 `proxy` 网络上，docker 内嵌 DNS 解析容器名。只有 k3s NodePort 那类宿主机服务才需要填宿主机内网 IP `10.0.0.95`（见根 README 的「反代到 k3s NodePort」坑）。
