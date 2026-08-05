# 2026-08-03 Vikunja → Apprise → Telegram 通知打通

把 Vikunja 的任务事件（指派给我、提醒到期、逾期）转发到 Telegram 群组 "Vikunja Notification"，消息里带项目名、任务标题、任务超链接。`vikunja-notify-relay` 是 `vps_oracle/compose/vikunja` 这个 compose 栈里的第二个 service（跟 `vikunja` 本体同一个 `docker-compose.yml`，代码在 `vps_oracle/compose/vikunja/notify-relay/`），另外还要有 `vps_oracle/compose/apprise` 这个独立栈。

## 架构

```
Vikunja (webhook, 每个 project 3 条)
  → POST http://vikunja-notify-relay:8080/         （proxy 网络内部，容器名直连，原始 payload 直发）
    → relay 从 payload 里取 project.title / task.title / task.id，拼成 HTML 消息：
      "Project: <b>xxx</b>\nTask: <a href=\"https://vikunja.jerome.cloudns.asia/tasks/{id}\">yyy</a>"
      → POST http://apprise:8000/notify/vikunja-tg   （{title, body, format:"html"}，不用 remap）
        → tgram:// 目标（存在 apprise 的持久化 store，key=vikunja-tg）
          → Telegram 群组 "Vikunja Notification"（任务标题渲染成可点的超链接）
```

**为什么多了一个 `vikunja-notify-relay` 容器**：最初想直接用 Apprise `/notify/<key>` 的字段重映射（query string 形式的 `:源路径=目标字段`）把 Vikunja 的原始字段搬到 `title`/`body` 上，不用额外写服务。但 remap 只能**一对一改名**，不能把多个字段拼成一个字符串——而"项目名 + 任务标题 + 任务链接"这个需求，天然需要拼接（尤其任务链接本身就是"固定前缀 + 动态 task id"拼出来的，remap 连这个都做不到）。评估过其他不加容器的路子：

- 把自定义逻辑塞进 `apprise` 容器（用它的自定义 plugin 机制）——remap 在 Django 视图层就已经把 payload 转换成 `{title,body}` 了，自定义 plugin 根本拿不到原始的多字段 JSON，此路不通，而且绑定挂载脚本进第三方镜像本身也更脆弱。
- host 上跑 cron 脚本轮询——脱离这个仓库"每个服务都是 docker-compose 栈"的约定，还要自己维护"轮询到哪了"的状态，比 webhook push 更麻烦。

比较下来一个独立的小容器反而最简单：`python:3.12.7-alpine3.20` 基底，无外部依赖，标准库 `http.server` 写的 ~80 行单文件服务，没有数据库没有持久化，维护面很小。

## 已注册的三个事件

| Vikunja event | 触发时机 | 备注 |
|---|---|---|
| `task.assignee.created` | 任务被指派给某人 | 单用户实例，指派必然是指派给自己 |
| `task.reminder.fired` | 任务上设置的提醒时间到达 | 前提是任务本身设置了 reminder；Vikunja 没有"自动距 due date 还有 N 小时"的内建事件 |
| `task.overdue` | 任务逾期（未完成且过了 due date） | 见下方"`task.overdue` 的触发时机"，不是逾期瞬间触发，是按用户账号设置的每日提醒时间点触发 |

统一发到 `vikunja-notify-relay`，relay 按 payload 里的 `event_name` 分流成不同的消息标题（emoji + 一句话），body 都是同一套"项目名/任务标题/链接"三行格式。

**没有注册 `task.updated`**：早期版本注册过，想用来做"任务完成"通知，但发现指派动作本身也会连带触发 `task.updated`（Vikunja 内部行为），两个事件一起注册会导致指派一次收到两条重复消息。后来改成只用 `task.assignee.created`，`task.updated` 整个拿掉了——目前没有"任务标记完成"这个通知，只有指派/提醒/逾期三种。

事件全集（`GET /api/v1/webhooks/events`）：`project.deleted`、`project.shared.team`、`project.shared.user`、`project.updated`、`task.assignee.created`、`task.assignee.deleted`、`task.attachment.created`、`task.attachment.deleted`、`task.comment.created`、`task.comment.deleted`、`task.comment.edited`、`task.created`、`task.deleted`、`task.overdue`、`task.relation.created`、`task.relation.deleted`、`task.reminder.fired`、`task.updated`、`tasks.overdue`。

## `task.overdue` 的触发时机

查了 Vikunja 源码（`pkg/models/task_overdue_reminder.go`）：`task.overdue`（每个逾期任务一条）和 `tasks.overdue`（一个用户当下所有逾期任务打包成一条）由同一个 cron job 触发，这个 job 每分钟跑一次扫描，但只有在"当前时间 = 这个用户账号设置里的 Overdue Tasks Reminder Time"（Vikunja 账号设置里可调，默认 9:00，按用户自己时区算）时才会真的 dispatch。效果上是**每个用户一天一次**，不是任务一变成逾期就立刻通知。我们只注册了 `task.overdue`（单数，一任务一条），没有注册 `tasks.overdue`——两个都注册会导致同一次触发收到重复信息（一条条 + 一条打包）。

## 已知限制

1. **没有"任务完成"通知**：见上面"没有注册 `task.updated`"，指派和完成没法同时保留而不重复，取舍后留了指派、丢了完成。
2. **没有真正的"全局 webhook"**：Vikunja 的 Settings 里有一个 "Webhook Notifications" 面板，UI 上写明 "receive events from all your projects"，是真正跨 project 生效的全局 webhook，但只能通过浏览器登录态（JWT）配置和调用——`PUT /api/v1/user/settings/webhooks` 这个 API 端点，个人 API Token（即使勾了全部权限）访问一律被拒绝。而且这个全局面板本身能选的事件也只有 `task.overdue`、`task.reminder.fired`、`tasks.overdue` 三个，`task.assignee.created` 不在全局层级开放，本来就只能逐 project 注册。评估后决定不用全局面板：反正 `task.assignee.created` 得靠脚本逐 project 维护，`task.reminder.fired`/`task.overdue` 单独搬去全局面板管理只会多一套配置入口、多一个"全局+project 重复发送"的风险点，所以三个事件统一留在 `register-telegram-webhooks.sh` 里逐 project 注册。
3. **`VIKUNJA_OUTGOINGREQUESTS_ALLOWNONROUTABLEIPS=true`**：Vikunja 自带 SSRF 防护，默认拒绝把 webhook（以及头像下载、迁移导入）发到私网 IP 段（`172.16.0.0/12` 等），而 `vikunja-notify-relay`/`apprise` 都在同一个 `proxy` 网络的私网段里，所以必须放开这个开关才能投递成功。这个开关是全局的，不止影响 webhook，是本仓库单用户自托管场景下可接受的取舍，已加到 `vps_oracle/compose/vikunja/docker-compose.yml`。
4. **relay 和 vikunja 合并成一个 compose 栈**：最初 `vikunja-notify-relay` 是独立目录/独立栈，后来按要求合并进 `vps_oracle/compose/vikunja/docker-compose.yml` 当第二个 service（这个仓库的约定本来就允许"一个 compose 栈可以定义多个 service"），代码搬到 `vps_oracle/compose/vikunja/notify-relay/` 子目录，`build:` 指过去。容器名、网络行为都没变，只是文件位置从独立目录变成 vikunja 栈的一部分。

## 复现 / 给新 project 补 webhook

```bash
# 1. apprise 侧只需配一次：把 tgram:// 目标存进持久化 store
docker run --rm --network proxy curlimages/curl:8.10.1 -s -X POST \
  --data-urlencode "urls=tgram://<bot_token>/<chat_id>/" \
  http://apprise:8000/add/vikunja-tg

# 2. vikunja 栈：构建并启动（vikunja 本体 + vikunja-notify-relay 两个 service）
cd vps_oracle/compose/vikunja
docker compose up -d --build

# 3. 对指定 project（或不传参数=全部真实 project）注册三个事件的 webhook
VIKUNJA_TOKEN=tk_xxx ./register-telegram-webhooks.sh          # 全部
VIKUNJA_TOKEN=tk_xxx ./register-telegram-webhooks.sh 5 7      # 只对 project 5、7
```

`VIKUNJA_TOKEN` 从 Vikunja Settings → API Tokens 生成，不落盘、每次手动传入即可（用量很低，没必要为此在 `.env` 里常驻一个高权限 token）。Telegram bot token / chat id 也不进 git，只作为 apprise store 里的运行时数据存在（宿主机路径 `/etc/apprise/config/store`，不在本仓库范围内）。

**重跑脚本前记得先删旧的 webhook**：Vikunja 的 `PUT .../webhooks` 是"新建"不是"更新"，改了 `register-telegram-webhooks.sh` 里的内容后如果不删旧记录直接重跑，会导致每个事件被注册两次、收到重复消息。删除方式：`GET /api/v1/projects/{id}/webhooks` 列出 id，再逐个 `DELETE /api/v1/projects/{id}/webhooks/{webhook_id}`。

**改 `notify-relay/app.py` 后要重新 build**：`docker compose up -d --build`（在 `vps_oracle/compose/vikunja/` 下跑），不加 `--build` compose 不会重新打包镜像，容器还是跑旧代码。`docker compose up -d --build` 只会重建有变化的 service，不会动 `vikunja` 本体。

## 验证方法

改完代码后先直接 `curl -X POST` relay 的 `http://vikunja-notify-relay:8080/`，带一个手写的假 payload（`{"event_name":"task.assignee.created","data":{"task":{"id":1,"title":"..."},"project":{"title":"..."}}}`），看 `docker logs vikunja-notify-relay` 有没有 `forwarded ... -> apprise: 200`，以及 Telegram 有没有收到消息；再在真实 project 里建一个任务、指派给自己，确认整条链路（`docker logs vikunja`、`docker logs vikunja-notify-relay`、`docker logs apprise` 都要看一遍有没有报错）。上线时两段都反复实测过，包括用临时 project + 临时 http-echo 容器抓过 `task.assignee.created`/`task.updated`/`task.reminder.fired`/`task.overdue` 的真实 payload 结构（用完即删）。
