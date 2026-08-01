# docker-gitops

集中管理所有服务器上运行的 Docker Compose 配置，作为唯一可信来源（source of truth）。

## 目录结构

```
docker-gitops/
└── <host>/                # 按服务器分组，如 vps_oracle
    └── <compose>/          # 每个 compose 栈一个目录（可包含多个服务）
        └── docker-compose.yml
```

## 工作方式

仓库目录本身就是服务运行目录，直接在仓库里对应的 compose 目录下执行 compose 命令：

```bash
cd ~/jerome/docker-gitops/<host>/<compose> && docker compose up -d
```

compose 文件里涉及的挂载卷统一用绝对路径（如 `/etc/x-ui/...`），因此工作目录搬到仓库里不影响容器内的数据位置。

## 新增一个服务

1. 在对应 `<host>/` 目录下新建 `<compose>/docker-compose.yml`
2. 在该目录下 `docker compose up -d` 启动
3. `git add` + commit

## 给服务接入 NPM 反代

新增/修改一条 NPM 反代记录时，按下面的配置来，保持跟现有栈风格一致。

**Details 标签页**

| 字段 | 值 |
|---|---|
| Domain Names | `<service>.jerome.cloudns.asia` |
| Scheme | `http` |
| Forward Hostname / IP | 容器名（跟 compose 里的 `container_name` 一致，靠 `proxy` 网络的 Docker DNS 解析，不用填 IP） |
| Forward Port | 容器内部实际监听端口（不是宿主机端口，这些服务本来就不发布端口） |
| Cache Assets | 关闭 |
| Block Common Exploits | 开启 |
| Websockets Support | 开启 |
| Access List | 一律选 `self-only` |

**SSL 标签页**

| 字段 | 值 |
|---|---|
| SSL Certificate | 选跟 Domain Names 一致的证书；新域名选 "Request a new SSL Certificate" |
| Email Address for Let's Encrypt | 固定填 `jeromefromcn@gmail.com`，跟现有证书保持一致，不用再查 |
| Force SSL | 开启 |
| HTTP/2 Support | 开启 |
| HSTS Enabled | 关闭 |

**⚠️ 已知坑**：创建时把 Force SSL / HTTP/2 Support 打开保存，有时会被静默重置回关闭状态。**保存后要重新打开这条记录复查一遍**，发现关掉了就再勾一次并保存。

## 约定

- 不提交任何密钥/密码/token。敏感配置放 `.env` 文件（已在 `.gitignore` 排除），compose 里通过 `env_file` 或环境变量引用
- 镜像版本尽量锁定具体 tag 或 digest，不用 `latest`
- 每次改动尽量小、单一职责，方便 review 和回滚
- 每个 compose 目录对应一个独立的 docker-compose 栈，栈内可以有多个服务，但不同栈的文件不要混放到同一个目录
- **时区**：容器统一用 `environment: TZ: "Asia/Hong_Kong"`，保证日志时间戳跟人对得上。
- **日志大小限制**：每个 service 都要显式声明 `logging`，避免日志把磁盘写满：
  ```yaml
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "5"
  ```
- **端口最少暴露**：宿主机上只发布确实需要直连的端口（如 3x-ui 的节点端口、npm 的 80/443）。管理面板/内部服务（3x-ui 面板、Prometheus、Grafana、Portainer UI 等）一律不发布到宿主机，统一走 NPM 反代到 `proxy` 网络内部端口；应急访问走 SSH + 容器内部 IP，不额外开端口。
- **最小权限**：能力允许的容器加 `security_opt: [no-new-privileges:true]`（monitoring、portainer 已启用）。挂载 `/var/run/docker.sock` 属于已知的高风险例外（如 portainer），要在注释里明确标注原因，不能悄悄引入新的等价挂载。
- **重启策略**：统一 `restart: unless-stopped`，宿主机重启后自动拉起，但手动停止不会被拉回来。
- **网络隔离**：跨栈互通走外部网络 `proxy`（`docker network create proxy` 手动建一次），不需要对外暴露的服务不要挂到 `proxy` 上。
- **暴露内容用英文**：任何会展示给最终用户/访客的内容（如 dashboard 标题、服务卡片描述、UI 文案等）统一用英文；仓库内部的注释、文档、commit message 不受此限，按原有习惯用中文即可。

## Host 列表

| Host | 说明 |
|---|---|
| vps_oracle | Oracle Cloud VPS |
