# vps_oracle/compose/ccr

用 [claude-code-router (CCR)](https://github.com/musistudio/claude-code-router) 把 Claude Code 的后端模型按「项目分组」在**官方订阅**和**第三方 provider（智谱 GLM）**之间切换，并保证**各组互相隔离**——切某一组绝不能影响另一组。

本目录放 CCR 本体；配套的切换 UI 在 `../switchboard/`（一个通用的配置驱动开关框架，jerome-ccr/bridget-ccr 只是其中两个开关）。这份 README 是整个分组切换系统的总文档。

> 想给不同分组绑**不同的 Claude 订阅账号**（目录隔离）？见 [`ACCOUNTS.md`](ACCOUNTS.md)——靠 `CLAUDE_CONFIG_DIR`，和 provider 切换正交、可叠加。

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
2. **动态 `.claude-provider/<组名>.env`**：真正被改写的文件。空（或只有注释）= 走官方订阅；有两行 `export ANTHROPIC_BASE_URL=… / ANTHROPIC_AUTH_TOKEN=…` = 走 CCR。**switchboard 的 `jerome-ccr`/`bridget-ccr` 开关是唯一应该改写这个文件的东西。**
3. **CCR**（本目录的 compose 栈）：网关 `127.0.0.1:3456`，管理面板 `127.0.0.1:3458`，容器内 nginx:8080 按路径分流（`/v1/*`、`/messages` 走 gateway，`/`、`/api/ccr/rpc` 走管理面板）。两个宿主端口都只绑 `127.0.0.1`——claude 进程跑在宿主机上、不在容器里，够不到 proxy 网络，只能靠发布的宿主端口；这两个宿主端口本身不对外暴露；管理面板从别的机器访问的两条路（NPM 反代 / SSH 端口转发）见下面「CCR 管理面板」一节。
4. **switchboard UI**（`../switchboard/`）：挂在 `proxy` 网络上的通用配置驱动开关服务，通过 NPM 反代成 `https://switchboard.jerome.cloudns.asia`（access list=self-only）。jerome/bridget 的 CCR 切换是它登记的两个开关（`jerome-ccr`/`bridget-ccr`）。每次打开页面都**实时重扫**（不缓存）每个开关的状态；点按钮就跑对应开关的 `on.sh`/`off.sh` 原子改写对应 `.env`。

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

# 3. 在 switchboard 里登记一个新开关 alice-ccr：
#    - 复制 vps_oracle/compose/switchboard/switches/jerome-ccr/ 整个目录为
#      switches/alice-ccr/，把三个脚本里的 jerome.env 路径改成 alice.env
#    - 在 switches.ini 里加一个 section：
#      [alice-ccr]
#      group = Provider
#      label = alice
#      on_label = CCR
#      off_label = Official

# 4. 重建 switchboard 让新开关出现在 UI 里
cd vps_oracle/compose/switchboard && docker compose up -d --build
```

然后把这个目录当工作区打开新 claude session 即可。要让这个组走 CCR，去 UI 点按钮，或直接在 `alice.env` 写：
```
export ANTHROPIC_BASE_URL=http://127.0.0.1:3456
export ANTHROPIC_AUTH_TOKEN=<CCR client key>
```

CCR client key（`ccr-profile-…`）在 CCR 管理面板生成；switchboard 容器通过 `.env` 里的 `CCR_CLIENT_TOKEN` 拿到同一个 key，`alice-ccr` 开关的 `on.sh` 用它写 `.env` 文件。

## 四个坑

1. **`.envrc` 必须保持静态。** 只有它 `source` 的那个 `.env` 文件能变。如果你改了 `.envrc` 本身，direnv 会要求重新 `direnv allow`（信任机制）。所以把可变内容放在 `.env`，`.envrc` 只负责 source。
2. **项目自己的 `.envrc` 会遮蔽分组 env。** direnv 只加载「最深」的那个 `.envrc`，不会自动叠加父目录的。例如 `~/jerome/betting-lab/.envrc` 如果直接 `source ./venv/bin/activate`，就**取代**了 `~/jerome/.envrc`，分组 provider 配置进不来。修法：在项目 `.envrc` 最前面加 `source_up`，先加载父级分组 `.envrc`，再做项目自己的事。
3. **切换只对切换之后新开的 session 生效。** 已经在跑的 claude 进程环境变量已经定型，改 `.env` 不会回头改它。开新 session 才走新 provider。
4. **移动项目目录会断 resume 历史。** claude 的 session 历史按项目路径存。把项目从 `~/jerome/x` 挪到 `~/bridget/x` 后，旧 session 记录还在旧路径名下，`claude --resume` 在新路径看不到。切换 provider 不会动历史，但物理移动目录会。

> 注：早期 UI 还有一列「Pending sessions」，想显示「还有几个旧 session 在跑」。从容器的私有 PID 命名空间看不到宿主机进程，要数准得给容器 root + `CAP_SYS_PTRACE` + `pid:host`（被攻破的话能读宿主机进程内存）——代价和这列能提供的安全提示不成比例，所以去掉了，靠上面第 3 条的静态文字承载提醒。

## 验证

```bash
# 1. UI 实时状态（应返回两个组 + 各自 provider + reachable）
curl -sS https://switchboard.jerome.cloudns.asia/ | grep -oE '<td>(jerome|bridget)</td>|<td>(Official|CCR)</td>'

# 2. 某个组目录里 direnv 实际注入了什么（零 token，用真 claude 调用的同款 wrapper）
cd ~/bridget/any-project
/home/ubuntu/.claude/claude-direnv-wrapper.sh env | grep ANTHROPIC

# 3. 隔离：确认改 bridget 不影响 jerome（在 bridget 走 CCR 的同时）
cd ~/jerome && BASH_ENV=/home/ubuntu/.claude/direnv-bash-env.sh bash -c 'echo "${ANTHROPIC_BASE_URL:-(unset=官方)}"'
```

## 重命名 / 删除分组

- **改名**：把 `switches/<旧>-ccr/` 目录连同 `switches.ini` 里对应的 section 一起改名、把 `~/<旧>/` 目录和 `~/<旧>/.envrc` 一起 `mv` 成新名、`mv /home/ubuntu/.claude-provider/<旧>.env <新>.env`（脚本里硬编码的路径也要跟着改）、重建 switchboard。注意上面第 4 个坑——移动目录会断旧 session 的 resume 历史。
- **删除**：从 `switches.ini` 摘掉对应 section、删 `switches/<组>-ccr/` 目录、删 `~/<组>/` 目录和 `.env`、重建 switchboard。

## 回滚（某组回到官方订阅）

最简单：去 UI 点该组的「Switch to Official」。等价的手动操作是把 `/home/ubuntu/.claude-provider/<组>.env` 清空（只留注释）。已经在跑的 session 仍用旧 provider，开新 session 才回官方。

## CCR 管理面板（改路由 / 加 provider / 生成 client key）

两条路都能到：

- **NPM 反代**：`https://ccr.jerome.cloudns.asia`（homepage 上的 `CCR Admin` 卡片就是这个），`access_list_id=1`（`self-only`：只放行 3x-ui 容器 IP `172.19.0.2` 和服务器自己的公网出口 IP）挡住一般公网访客。用 `.env` 里 `CCR_WEB_AUTH_TOKEN` 的值登录。
- **SSH 隧道**（不经过 3x-ui 时的备用路径）：

  ```bash
  ssh -L 3458:127.0.0.1:3458 <server>
  # 然后本地浏览器打开 http://127.0.0.1:3458 ，用 .env 里 CCR_WEB_AUTH_TOKEN 的值登录
  ```

> 2026-08-10 之前没有给 CCR 管理面板单独做 NPM 反代：CCR 容器内 nginx:8080 把 `/v1/*`（模型网关）和 `/`（管理面板）复用在一个端口上，反代过去会把模型网关也一并暴露到公网域名。后来还是决定接上——跟仓库里其它管理面板（npm 自己、portainer、grafana……）同样的姿势用 `self-only` 挡住一般公网访客，暴露的只是"域名存在"这件事，不是无限制访问。

## CCR 的 NPM 反代（可复现）

跟 switchboard 一样的标准姿势：挂在 `proxy` 网络，NPM 用容器名 `ccr:8080` 反代（**不是**宿主机端口 3456/3458——NPM 跟 ccr 都在 `proxy` 网络上，走 Docker 内嵌 DNS，直接用容器名+容器内部端口），access list=`self-only`，HTTPS 用 NPM 自己申请的 Let's Encrypt 证书：

```bash
cd ../npm && source .npm-automation.env
docker run --rm --network proxy curlimages/curl:latest sh -c "
TOKEN=\$(curl -sS -X POST http://npm:81/api/tokens -H 'Content-Type: application/json' -d '{\"identity\":\"\$NPM_AUTOMATION_EMAIL\",\"secret\":\"\$NPM_AUTOMATION_PASSWORD\"}' | sed -n 's/.*\"token\":\"\([^\"]*\)\".*/\1/p')
# 1. 先建证书
curl -sS -X POST http://npm:81/api/nginx/certificates -H \"Authorization: Bearer \$TOKEN\" -H 'Content-Type: application/json' -d '{\"provider\":\"letsencrypt\",\"nice_name\":\"ccr.jerome.cloudns.asia\",\"domain_names\":[\"ccr.jerome.cloudns.asia\"],\"meta\":{\"letsencrypt_email\":\"jeromefromcn@gmail.com\",\"letsencrypt_agree\":true,\"dns_challenge\":false}}'
# 2. 再建 proxy host（certificate_id 换成上一步的 id，access_list_id=1 是 self-only）
curl -sS -X POST http://npm:81/api/nginx/proxy-hosts -H \"Authorization: Bearer \$TOKEN\" -H 'Content-Type: application/json' -d '{\"domain_names\":[\"ccr.jerome.cloudns.asia\"],\"forward_scheme\":\"http\",\"forward_host\":\"ccr\",\"forward_port\":8080,\"certificate_id\":<id>,\"ssl_forced\":true,\"http2_support\":true,\"block_exploits\":true,\"allow_websocket_upgrade\":true,\"access_list_id\":1,\"caching_enabled\":false,\"locations\":[],\"meta\":{\"letsencrypt_agree\":false,\"dns_challenge\":false}}'
"
```

## switchboard 的 NPM 反代（可复现）

switchboard 走的是 repo 里所有 NPM 反代服务的标准姿势：挂在 `proxy` 网络，NPM 用容器名 `switchboard:8091` 反代，access list=`self-only`，HTTPS 用 NPM 自己申请的 Let's Encrypt 证书。一次性创建（token 换取 + 建 proxy host 的完整模式见 `../npm/README.md`）：

```bash
cd ../npm && source .npm-automation.env
docker run --rm --network proxy curlimages/curl:latest sh -c "
TOKEN=\$(curl -sS -X POST http://npm:81/api/tokens -H 'Content-Type: application/json' -d '{\"identity\":\"\$NPM_AUTOMATION_EMAIL\",\"secret\":\"\$NPM_AUTOMATION_PASSWORD\"}' | sed -n 's/.*\"token\":\"\([^\"]*\)\".*/\1/p')
# 1. 先建证书（HTTP-01 challenge，DNS 已有 *.jerome.cloudns.asia 通配）
curl -sS -X POST http://npm:81/api/nginx/certificates -H \"Authorization: Bearer \$TOKEN\" -H 'Content-Type: application/json' -d '{\"provider\":\"letsencrypt\",\"nice_name\":\"switchboard.jerome.cloudns.asia\",\"domain_names\":[\"switchboard.jerome.cloudns.asia\"],\"meta\":{\"letsencrypt_agree\":true,\"dns_challenge\":false}}'
# 记下返回的 id（下面 certificate_id 用）
# 2. 再建 proxy host（certificate_id 换成上一步的 id，access_list_id=1 是 self-only）
curl -sS -X POST http://npm:81/api/nginx/proxy-hosts -H \"Authorization: Bearer \$TOKEN\" -H 'Content-Type: application/json' -d '{\"domain_names\":[\"switchboard.jerome.cloudns.asia\"],\"forward_scheme\":\"http\",\"forward_host\":\"switchboard\",\"forward_port\":8091,\"certificate_id\":<id>,\"ssl_forced\":true,\"http2_support\":true,\"block_exploits\":true,\"allow_websocket_upgrade\":true,\"access_list_id\":1,\"caching_enabled\":false,\"locations\":[],\"meta\":{\"letsencrypt_agree\":false,\"dns_challenge\":false}}'
"
```

> 为什么 `forward_host` 是容器名 `switchboard` 而不是 IP：switchboard 和 NPM 都在 `proxy` 网络上，docker 内嵌 DNS 解析容器名。只有 k3s NodePort 那类宿主机服务才需要填宿主机内网 IP `10.0.0.95`（见根 README 的「反代到 k3s NodePort」坑）。
>
> 旧的 `provider.jerome.cloudns.asia` proxy host 和证书在完成 Manual Follow-up 的 NPM 切换后需要在 NPM 里手动删除/停用（仓库里没有对应的删除 API 调用记录）。

## provider-switch → switchboard 首次部署收尾清单

`provider-switch` 改名/重写成 `switchboard` 之后，几件一次性的人工收尾事项：

1. **先拷贝 `.env`**：`vps_oracle/compose/provider-switch/.env`（gitignored，装着 `CCR_CLIENT_TOKEN`）不会随 `git mv` 自动出现在 `vps_oracle/compose/switchboard/.env`——部署前手动拷贝一份，否则 `docker compose up -d --build` 会因为缺 `env_file` 直接失败。
2. **切换完成后清理旧容器/镜像**：`provider-switch` 的容器和镜像不会自动消失，`docker compose -p provider-switch down` 之后确认 `docker images` 里旧镜像也删掉；旧目录下残留的 `.env`、`__pycache__/` 是孤儿文件，一并清掉。
3. **清理旧锁文件**：`/home/ubuntu/.claude-provider/jerome.env.lock`、`/home/ubuntu/.claude-provider/bridget.env.lock`（旧 `status.py` 把锁放在 `env_path + ".lock"`）切到 switchboard 后不会再被用到——新引擎的锁改放到 `LOCK_DIR`（默认 `/tmp/switchboard-locks`）。这两个旧文件是孤儿，可以手动删掉。
