# dify

自建 Dify 1.14.2（社区版），精简自官方 `docker/docker-compose.yaml`。

## 跟官方默认部署的区别

- **不用官方自带的 nginx** —— 官方 nginx 只做按路径转发（`/console/api`、`/api`、`/v1`、`/files`、`/mcp`、`/triggers`、`/openapi` → api；`/e/` → plugin_daemon；其余 → web），全部在同一个域名下。这里改成用 NPM 的 Custom Locations 功能直接照抄这几条转发规则，不用单独起一个 nginx 容器。见下面"接入 NPM 反代"。
- **不部署 sandbox**（代码执行沙箱）—— Workflow 里的 Code 节点会不可用，其余功能不受影响。之后要用再单独加这个容器。
- **不用 certbot** —— 证书统一走 NPM。
- **向量库用 pgvector**，不用官方默认的 weaviate —— 注意 pgvector 是官方 compose 里独立的一个 Postgres 容器（`pgvector` 服务），不是复用 `db_postgres` 这个 Dify 自己的元数据库实例。
- **不用最新的 1.16.x** —— 1.16.0 新增了一整套 "Dify Agent" 子系统（`agent_backend`+`local_sandbox`+`agent_ssrf_proxy`+`api_websocket`），用不上，还多吃内存。
- **锁定 1.14.2，不用 1.15.x** —— 1.15.0 把 `web/hooks/use-timestamp.ts` 改成了用 `react-query` 独立发 `GET /console/api/account/profile`（1.14.x 是直接读已加载好的 app context，不产生额外请求）。这个背景请求只要碰上一次瞬时 401，`web/service/base.ts` 就会无条件把整页硬跳转到 `/signin`（没有做 silent 请求豁免——对应修复 PR #38273 提出了但没合并），跳转后页面重载又重新触发同一个 hook，形成登录后一直重定向的死循环（上游 issue [#38457](https://github.com/langgenius/dify/issues/38457)，同版本同症状）。已经通过直接 diff 1.14.2/1.15.0 源码确认：1.14.2 没有这条额外请求，这个循环的触发路径根本不存在。**如果之后升级到修复此问题的版本，记得把这条注释和下面 URL 那节一起复查。**
- **不开 collaboration（`api_websocket`）** —— 多人协作编辑 workflow 的功能，没有这个需求。

## 架构

| 容器 | 作用 |
|---|---|
| `dify-db` | Dify 自己的元数据 Postgres |
| `dify-pgvector` | 向量库，独立 Postgres 容器 |
| `dify-redis` | 缓存 / Celery broker |
| `dify-ssrf-proxy` | Squid，workflow HTTP 请求节点和插件的出站请求走这里防 SSRF，跟 sandbox 无关，是核心组件 |
| `dify-plugin-daemon` | 插件运行时，**必须有**——1.x 起连 OpenAI/Anthropic 这些 model provider 都是插件实现的 |
| `dify-api` | 后端 API |
| `dify-worker` | Celery worker（跑数据集索引、workflow 异步任务等） |
| `dify-worker-beat` | Celery 定时任务调度 |
| `dify-web` | 前端 |

没有一次性 init 容器：`/app/api/storage` 的权限（api/worker 跑在 uid 1001 下）是在宿主机上直接 `sudo chown -R 1001:1001 /etc/dify/storage` 搞定的，永久生效，不用每次启动跑一个用完就退出的容器。

只有 `dify-web`、`dify-api`、`dify-plugin-daemon` 加入外部网络 `proxy`（给 NPM 转发用），其余容器只在内部网络，不发布任何宿主机端口。

## 给服务接入 NPM 反代

已通过 NPM API（`vps_oracle/npm/.npm-automation.env` 里的自动化账号）配好，proxy host id 24，证书 id 26。跟根目录 README 的通用约定不同 —— 这个服务需要**一个 proxy host + 多条 Custom Locations**，不是简单的单容器单端口转发。以下是实际配置，供之后对照/复查：

**Details 标签页**

| 字段 | 值 |
|---|---|
| Domain Names | `dify.jerome.cloudns.asia` |
| Scheme | `http` |
| Forward Hostname / IP | `dify-web` |
| Forward Port | `3000` |
| Cache Assets | 关闭 |
| Block Common Exploits | 开启 |
| Websockets Support | 开启 |
| Access List | `self-only` |

**Custom Locations**（同一个 proxy host 里加）

| Location | Forward Hostname/IP | Forward Port |
|---|---|---|
| `/console/api` | `dify-api` | `5001` |
| `/api` | `dify-api` | `5001` |
| `/v1` | `dify-api` | `5001` |
| `/files` | `dify-api` | `5001` |
| `/mcp` | `dify-api` | `5001` |
| `/triggers` | `dify-api` | `5001` |
| `/openapi` | `dify-api` | `5001` |
| `/e/` | `dify-plugin-daemon` | `5002` |

SSL 标签页照根目录 README 的通用配置走（Force SSL / HTTP2 / 邮箱固定值），记得保存后重新打开复查那个已知坑。

**另一个坑**：Custom Locations 生成的 nginx 配置是 `proxy_pass http://dify-api:5001;` 这种写死主机名的写法，不是 resolver+变量的动态解析模式——nginx 只在 worker 启动/reload 时解析一次主机名并缓存 IP，不会每个请求都重新查。**每次 `docker compose down && up`（网络重建，容器 IP 会变）之后，如果 `/console/api` 等路径开始 502 而 `/` 正常，先 `docker exec npm nginx -s reload` 让它重新解析。** 平时只是 `docker compose restart` 之类不重建网络的操作不受影响。

## 给新服务加 homepage 卡片

已经按根目录 README 的格式加到 `vps_oracle/homepage/config/services.yaml`。

**踩过的坑**：`dify-web` 的 `server.js` 会绑定到 `$HOSTNAME`（Docker 从 compose 的 `hostname:` 字段自动注入），不是 `0.0.0.0`。不修的话它只监听 `default` 网络那个 IP，`proxy` 网络（也就是 NPM）连不上，表现为除了 `/console/api` 等转发到 `dify-api` 的路径外，首页固定 502。已经在 compose 里给 `web` 显式加了 `HOSTNAME: "0.0.0.0"` 环境变量覆盖掉。

## URL 类配置的内外之分

compose 里几类 `*_URL` 变量,踩过的坑记录一下:

- **内部（容器名:端口，走 docker 网络）**：`DB_HOST`/`REDIS_HOST`/`PGVECTOR_HOST`、`SSRF_PROXY_HTTP(S)_URL`、`PLUGIN_DAEMON_URL`、`DIFY_INNER_API_URL`、`SERVER_CONSOLE_API_URL`（web 的 SSR 阶段拿这个直连 api，容器内没有"当前请求域名"可推断）、`INTERNAL_FILES_URL`（api/worker 用，插件读文件走这个而不是绕一圈公网域名）。前提是双方共享至少一个 docker 网络（都验证过)。
- **外部（真实公网域名，给浏览器/第三方用）**：`CONSOLE_WEB_URL`/`CONSOLE_API_URL`/`SERVICE_API_URL`/`APP_WEB_URL`/`FILES_URL`（api、worker、worker_beat 都要有——注册/邀请/重置密码邮件是 worker 的 Celery 任务发的，图片/文件下载链接也是拼进 API 响应体里给外部客户端用的，不是容器内部用的，必须是能从外面访问到的地址）、`ENDPOINT_URL_TEMPLATE`（插件 Endpoint 类型的回调 URL,比如接 Slack 用的）、`TRIGGER_URL`（插件 Trigger 的回调 URL，对应 NPM 里的 `/triggers`）。这两个一开始漏配，官方默认值是 `http://localhost/...`，如果真去装一个需要 webhook 回调的插件，生成出来的 URL 外部完全打不进来——已经补上。
- **第三方外部（不是我们的基础设施）**：`MARKETPLACE_API_URL`/`MARKETPLACE_URL`（`https://marketplace.dify.ai`，Dify 官方插件市场，浏览器直接访问，不经过我们的容器）。

`PLUGIN_REMOTE_INSTALL_HOST`/`PORT`（api）和 `PLUGIN_REMOTE_INSTALLING_HOST`/`PORT`（plugin_daemon）留着 `localhost`/`0.0.0.0` 没改——这俩是"远程插件调试安装"功能用的，因为没往宿主机发布 5003 端口（按最小暴露原则），这功能本来就连不进来，不是配错，是没启用。

## 首次安装

1. `docker compose up -d`
2. 等 `dify-api`、`dify-web` 都 healthy（`docker compose ps`）
3. 如果是重建过网络（`down` 之后再 `up`），按上面那条坑先 `docker exec npm nginx -s reload`
4. 配好 NPM 反代后访问 `https://dify.jerome.cloudns.asia/install`，用 `.env` 里的 `INIT_PASSWORD` 值设置管理员账号

## 内存占用

部署后建议跑一次 `docker stats --no-stream $(docker compose ps -q)` 记录基线，主机内存本来就偏紧（部署前可用 ~8.9GB）。
