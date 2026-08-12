# Vikunja 按用户分流 Telegram 通知 + 任务完成通知 — 设计

日期：2026-08-12

## 背景

[2026-08-03-vikunja-apprise-telegram-webhooks.md](../../2026-08-03-vikunja-apprise-telegram-webhooks.md) 打通的 Vikunja → `vikunja-notify-relay` → Apprise → Telegram 链路，当时是按"单用户实例"设计的：`notify-relay/app.py` 里 `APPRISE_NOTIFY_URL` 写死成 `http://apprise:8000/notify/vikunja-tg`，不管哪个 project、哪个事件、指派给谁，一律转发到同一个 apprise target，对应同一个 Telegram 群组"Vikunja Notification"。

现在 Vikunja 上有了第二个真实账号（`bridget`，此前是 `jerome` 一人），需要让指派给不同账号的任务通知，各自进各自的 Telegram；同时想新增"任务被标记完成"这个目前没有的通知类型，且完成通知要发给该任务的所有 assignee（不只是操作者）。

## 目标与范围

- `task.assignee.created` / `task.reminder.fired` / `task.overdue` 三个已注册事件，按 payload 里携带的用户身份路由到对应的人的 Telegram。
- 新增：任务被标记完成时，通知该任务的**所有** assignee（各自路由到各自的 Telegram），且只在"刚变成完成"时发，不因为其他字段编辑而误发。
- 支持未来继续增加 Vikunja 账号，不需要改 relay 代码。

**不在本次范围内**：
- 不做"任务重新打开（未完成）"的通知，只关心变成完成的那一刻。
- 不解决"设了 `repeat_after` 的重复任务标记完成"这个已知限制（见下方"已知限制"）——先按现状上线，之后如果实测发现影响到常用场景再处理。
- 不使用 Vikunja 的全局 per-user webhook 面板（`PUT /api/v1/user/settings/webhooks`）——个人 API Token 访问不了这个端点，[已有文档](../../2026-08-03-vikunja-apprise-telegram-webhooks.md)里已经评估过，维持现状继续用逐 project 注册。

## 背景调研：Vikunja webhook payload 的实际结构

以 `vikunja/vikunja:2.4.0`（compose 里锁定的版本）对应的源码 tag `v2.4.0` 为准（`pkg/models/events.go` / `listeners.go`），不是猜测：

- 外层统一是 `{event_name, time, data}`。
- `task.assignee.created`：`data = {task, assignee, doer}`。Vikunja 在 `task_assignees.go` 里对**每个 assignee 各自 `Dispatch` 一次**（批量指派多人也是循环里一个一个 dispatch），`assignee` 就是这次指派的那个人。
- `task.reminder.fired` / `task.overdue`：`data = {task, user, project, [reminder]}`。这两个在 Vikunja 内部被标记为 `RegisterUserDirectedEventForWebhook`（"user-directed event"），`task_reminder.go` / `task_overdue_reminder.go` 里对**每个该通知的用户各自 `Dispatch` 一次**（`user` 就是那个人）。
- 关键点：我们的 webhook 是注册在 **project 层级**（`register-telegram-webhooks.sh`）。查证了 `WebhookListener.Handle` 的匹配逻辑——project 层级 webhook 只按 `project_id` 匹配，不管事件是不是 user-directed，一律都会收到。也就是说上面这些"每人一份"的 dispatch，全部会打到我们同一个 relay URL，只是每次 POST 携带的 user 不同。**relay 不需要自己做 fan-out，Vikunja 已经在源头按人分开发送了。**
- `task.updated`：`data = {task, doer}`，只有更新后的完整快照，**没有 diff、没有"哪个字段变了"的标记**。而且不是 user-directed 事件，一次操作（不管几个 assignee）只 dispatch 一次，不会自动按人分流。触发点包括：普通字段编辑（`tasks.go`）、assignee 增删（`task_assignees.go`，所以指派动作本身也会连带触发一次 `task.updated`）、Kanban 看板拖动换 bucket（`kanban_task_bucket.go`，含"拖进 Done bucket 自动置 `done=true`"的场景）。
- `task.done_at`：服务器在任务真正变成 `done=true` 的那次保存时设置为当下时间（"When the task was marked as done. Set by the server"），非完成相关的更新不会改动这个字段。这是判断"刚完成"的关键依据（见下方"完成检测逻辑"）。
- `user.User` 对外可见字段只有 `id`、`name`、`username`、`email`（可能为空）、`bot_owner_id`（仅 bot 用户）——其余字段 `json:"-"` 不会出现在 payload 里。
- `task.updated` 的事件结构体本身不带 `project` 字段（只有 `{task, doer}`），但 `WebhookListener.Handle` 对**project 层级的 webhook**有自动补齐逻辑：如果 payload 里没有 `project` 字段而 webhook 是挂在某个 project 下的，会自动查出该 project 塞进 `data.project`。我们的 webhook 就是 project 层级注册的，所以实际收到的 `task.updated` payload 里仍然会带 `data.project`——完成通知的消息 body 可以沿用现有"Project / Task / 链接"三行格式，不需要为这个事件单独处理缺 project 的情况。

## 架构 / 数据流

不新增容器，改动集中在 `vps_oracle/compose/vikunja/notify-relay/app.py` 的路由逻辑，加上 Apprise 里按人各建一个 target。

```
Vikunja
  ├─ task.assignee.created ──┐
  ├─ task.reminder.fired ────┤  Vikunja 已按 user 各自 dispatch，
  ├─ task.overdue ───────────┘  relay 收到的每次 POST 只对应一个人
  │
  └─ task.updated（新注册）      relay 自己判断"是否刚完成"，
                                  是的话读 task.assignees[] 迭代发送
        ↓ 全部 POST 到同一个 relay URL（不变）
  vikunja-notify-relay:8080
        ↓ 按 event_name 分两条路径处理（见下）
        ↓ 决定收件人 username（一个或多个）→ 组 apprise target key
  apprise:8000/notify/vikunja-tg-{username}
        ↓
  Telegram（各自的 chat）
```

## 路由逻辑

### 路径 1：`task.assignee.created` / `task.reminder.fired` / `task.overdue`

Vikunja 已经"一人一个事件"dispatch，relay 直接取单一字段，不用迭代：

| event | 取值 |
|---|---|
| `task.assignee.created` | `data.assignee.username` |
| `task.reminder.fired` | `data.user.username` |
| `task.overdue` | `data.user.username` |

取到 username 后统一 `.lower()` 正规化，组 `vikunja-tg-{username}`，POST 给 apprise（消息格式跟现状一致：HTML，project/task/超链接三行）。

### 路径 2：`task.updated`（完成检测 + 全 assignee 广播）

1. **过滤**：只处理 `data.task.done == true` 且 `abs(payload.time - data.task.done_at) < 阈值`（初定 10 秒，可调）的事件；不满足条件的事件直接忽略（打一行 log 说明忽略原因，不转发到 apprise）。这个时间邻近判断依据上面调研的 `done_at` 语义——非完成相关的编辑不会刷新 `done_at`，所以能可靠地把"刚完成"和"编辑了已完成任务的其他字段"、"指派/看板拖动等连带触发的 `task.updated`"区分开。
2. **广播**：通过过滤后，迭代 `data.task.assignees[]`（数组，每项是完整 user 对象），对每个 assignee 各自组 `vikunja-tg-{username}`，各发一条"✅ Task completed"消息（新增进 `app.py` 的 `EVENT_TITLES`）。
3. `assignees` 为空数组（没人被指派就被标记完成）时不发任何通知，只 log。

## Apprise target 命名约定（用户 → Telegram 映射的存储方式）

不建显式的 id/映射表，直接用 **Vikunja 登录 username 拼 apprise target key**：`vikunja-tg-{username}`（全小写）。relay 端零状态、零配置——加一个新账号，只要在 Apprise 侧 `POST /add/vikunja-tg-<username>` 存一条新 target，relay 代码和配置都不用动。

代价：依赖 Vikunja username 稳定；username 一旦改名，映射会跟着断，但这是双人自建服务场景，概率低、好排查，不需要为此增加显式映射表的维护成本。

### 当前需要的 target

| username | 状态 | bot token | chat_id |
|---|---|---|---|
| `jerome` | 已有等价 target（旧 key 是 `vikunja-tg`），需按新约定补建 `vikunja-tg-jerome`（同一个 tgram URL） | 沿用现有 `alert_jerome_bot` | `-5463203030`（现有"Vikunja Notification"群组） |
| `bridget` | 全新 | 沿用同一个 `alert_jerome_bot`（token 不变） | `-5451306307`（群组"Vikunja Notifaciton Bridget"，已用 `getUpdates` 查到，bot 已是成员） |

Bot token 不进本文档、不进 git，运行时只存在 Apprise 的持久化 store 里（沿用[已有约定](../../2026-08-03-vikunja-apprise-telegram-webhooks.md)）。

`vikunja-notify-relay` 的环境变量 `APPRISE_NOTIFY_URL`（目前是写死的完整路径 `http://apprise:8000/notify/vikunja-tg`）要改成 base URL（如 `APPRISE_BASE_URL=http://apprise:8000`），relay 代码拼 `f"{APPRISE_BASE_URL}/notify/vikunja-tg-{username}"`。

旧的 `vikunja-tg` target 迁移验证完成后可以 `POST /del/vikunja-tg` 删掉，避免和新约定并存造成混淆（非阻塞项，可以在验证稳定后再做）。

## 错误处理与已知限制

- **Apprise target 查无此人**（username 打错、或新账号还没建 target）：那一次 POST 给 apprise 收到非 200，relay 只 log 一行 warning 并跳过，不影响同一批里其他 assignee 的通知——尤其是路径 2 迭代多个 assignee 时，一个失败不该挡住其他人。
- **payload 缺字段**：跟现状 `app.py` 逻辑一致，log 一行 `ignored: ...` 后直接 return，不 crash handler。
- **relay 对 Vikunja 的响应行为不变**：一收到 POST 立刻回 200（现状代码已经是这样），Vikunja 不会重试，所以 relay 内部任何失败都只能靠 log 事后排查——延续现有设计，不在本次改动范围。
- **已知限制：设了 `repeat_after` 的重复任务**：Vikunja 标记这类任务完成时，会在同一次更新里自动重新打开（`done` 又变回 `false`，顺便推后到期日/提醒），`task.updated` 事件到达 relay 时 `done` 字段有可能已经是 `false`，导致这类任务的"完成"检测不到、收不到通知。暂时接受这个限制，实测阶段用一个真实的重复任务验证影响范围，如果确实影响常用场景再另外处理。

## 需要同步的配置改动

- `register-telegram-webhooks.sh`：`EVENTS` 数组补回 `task.updated`（现在只有 assignee/reminder/overdue 三个）。
- 新建的 project「Love Bird OP」目前还没注册任何 webhook，需要和其他 project 一起跑一次脚本（脚本不传参数时默认对所有真实 project 生效，包含新建的，不需要单独处理）。
- `docker-compose.yml` 里 `vikunja-notify-relay` 的环境变量从 `APPRISE_NOTIFY_URL`（完整路径）改成 `APPRISE_BASE_URL`（base URL）。

## 验证步骤

1. **假 payload 直接打 relay**（`docker run --rm --network proxy curlimages/curl ... -X POST http://vikunja-notify-relay:8080/`，不碰真实 Vikunja 数据）：
   - `task.assignee.created`，`assignee.username` 分别填 `jerome`/`bridget` → 验证各自路由到对的 apprise target、对应 Telegram 各自收到。
   - `task.updated`，`done:true` 且 `done_at` 等于当前时间、`assignees` 填两人 → 验证两人都收到"✅ 完成"消息。
   - `task.updated`，`done:false` → 验证被忽略（log 可见，Telegram 不收到）。
   - `task.updated`，`done:true` 但 `done_at` 是很久以前 → 验证被忽略（模拟"已完成任务改了别的字段"这种假阳性）。
   - `assignee.username` 填一个没建 apprise target 的假名字 → 验证 log 出 warning、relay 不 crash、不影响其他请求。
2. **真实环境小范围验证**：在「Love Bird OP」建一个任务，实际指派给两个账号、标记完成、设一个提醒，确认全链路（`docker logs vikunja` / `vikunja-notify-relay` / `apprise`）无报错，两人 Telegram 各自收到消息。`task.overdue` 因为是每日 cron 触发、不好即时验证，靠跟 `task.reminder.fired` 共用同一段路由逻辑代码的对称性带过，不特别现场触发。
3. 用一个设了 `repeat_after` 的任务测一次标记完成，确认"已知限制"里描述的现象是否真的发生，记录结果供之后决定要不要处理。

## 未来扩展

- 继续加账号：只要在 Apprise 侧 `POST /add/vikunja-tg-<username>`，relay 不需要改代码。
- 如果以后要按"项目"而不是"人"分流（比如某个 project 固定发到团队群而不是个人），当前设计不支持，需要另外评估——不在本次范围内。
