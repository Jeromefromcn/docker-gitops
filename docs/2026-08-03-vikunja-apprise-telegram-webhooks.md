# Vikunja → Apprise → Telegram notification plumbing

Forwards Vikunja's task events (assigned to me, reminder due, overdue, completed) to each Vikunja account's own Telegram group, with the message carrying the project name, task title, and a task hyperlink. `vikunja-notify-relay` is the second service in the `vps_oracle/compose/vikunja` compose stack (same `docker-compose.yml` as the `vikunja` app itself, code under `vps_oracle/compose/vikunja/notify-relay/`), and there is also the separate `vps_oracle/compose/apprise` stack.

For the investigation, decision rationale, and evolution behind the current design (why routing is per-account, why `task.updated` needed special handling to catch completions without duplicating assignment notices), see [`docs/superpowers/specs/2026-08-12-vikunja-per-user-telegram-routing-design.md`](superpowers/specs/2026-08-12-vikunja-per-user-telegram-routing-design.md).

## Architecture

```
Vikunja (webhook, 4 per project)
  → POST http://vikunja-notify-relay:8080/         (inside the proxy network, direct by container name, raw payload forwarded as-is)
    → relay reads project.title / task.title / task.id from the payload, assembles an HTML message:
      "Project: <b>xxx</b>\nTask: <a href=\"https://vikunja.jerome.cloudns.asia/tasks/{id}\">yyy</a>"
      → POST http://apprise:8000/notify/vikunja-tg-{username}   ({title, body, format:"html"}, no remap; username read from the payload, routed per account)
        → tgram:// target (stored in apprise's persistent store, key=vikunja-tg-{username}, one per Vikunja account)
          → that account's Telegram group (one group per person, task title rendered as a clickable hyperlink)
```

**Why the extra `vikunja-notify-relay` container exists**: the original idea was to use Apprise's `/notify/<key>` field remapping (`:source-path=target-field` in query-string form) to move Vikunja's raw fields onto `title`/`body`, without writing an extra service. But remap can only **rename one-to-one**, not join multiple fields into a single string — and the "project name + task title + task link" requirement inherently needs concatenation (especially the task link, which is itself "fixed prefix + dynamic task id" concatenated; remap can't even do that). Other container-free routes I evaluated:

- stuffing the custom logic into the `apprise` container (via its custom-plugin mechanism) — remap converts the payload to `{title,body}` already at the Django view layer, so a custom plugin never sees the original multi-field JSON; this path is a dead end, and bind-mounting a script into a third-party image is also more fragile.
- running an on-host cron script that polls — this departs from this repo's "every service is a docker-compose stack" convention and requires self-maintaining "where did the polling get to" state, more trouble than a webhook push.

Comparing, a small independent container is actually simplest: `python:3.12.7-alpine3.20` base, no external dependencies, a ~80-line single-file service written with the stdlib `http.server`, no database, no persistence, a very small maintenance surface.

## The four registered events

| Vikunja event | Trigger timing | Notes |
|---|---|---|
| `task.assignee.created` | a task is assigned to someone | sent to whoever it's assigned to, routed by `assignee.username` in the payload (no longer assumes a single-user instance) |
| `task.reminder.fired` | the reminder time set on the task arrives | requires the task to have a reminder set; Vikunja has no built-in "N hours before due date" event |
| `task.overdue` | the task is overdue (not done and past its due date) | see "`task.overdue` trigger timing" below; not fired the instant it goes overdue, but at the per-user-account daily reminder time |
| `task.updated` | the task is marked done (`done` becomes `true`) | relay filters it itself: only when `done_at` falls near the event timestamp does it count as "just completed", notifying all assignees of that task; other `task.updated` (ordinary edits, assignee-triggered side effects, etc.) are ignored — see the update note below |

All delivered to `vikunja-notify-relay`; the relay dispatches by the payload's `event_name` into different message titles (emoji + one line), with the body always the same three-line "project name / task title / link" format.

**`task.updated`: completion detection**: `task.updated` also fires as a side effect of the assignment action itself (Vikunja internal behavior), so simply registering it would yield a duplicate message alongside `task.assignee.created` for every new assignment. To avoid that, the relay does its own "completion detection": only when `data.task.done == true` and `done_at` falls near the event timestamp (`DONE_WINDOW_SECONDS`, default 10 seconds) does it count as "just done" and get forwarded; every other `task.updated` (including the assignee-triggered one) is ignored outright. For the investigation details, decision rationale, and known limitations (`repeat_after` recurring tasks don't get completion notifications), see [`docs/superpowers/specs/2026-08-12-vikunja-per-user-telegram-routing-design.md`](superpowers/specs/2026-08-12-vikunja-per-user-telegram-routing-design.md).

Full event set (`GET /api/v1/webhooks/events`): `project.deleted`, `project.shared.team`, `project.shared.user`, `project.updated`, `task.assignee.created`, `task.assignee.deleted`, `task.attachment.created`, `task.attachment.deleted`, `task.comment.created`, `task.comment.deleted`, `task.comment.edited`, `task.created`, `task.deleted`, `task.overdue`, `task.relation.created`, `task.relation.deleted`, `task.reminder.fired`, `task.updated`, `tasks.overdue`.

## `task.overdue` trigger timing

Checked the Vikunja source (`pkg/models/task_overdue_reminder.go`): `task.overdue` (one per overdue task) and `tasks.overdue` (all of a user's currently-overdue tasks packed into one) are triggered by the same cron job, which scans every minute but only actually dispatches when "current time = this user account's Overdue Tasks Reminder Time setting" (adjustable in Vikunja account settings, default 9:00, in the user's own timezone). In effect it's **once per day per user**, not the moment a task goes overdue. We registered only `task.overdue` (singular, one per task) and not `tasks.overdue` — registering both would produce duplicate messages on the same trigger (individually + one packed).

## Known limitations

1. **Task-completion notification doesn't apply to recurring tasks (`repeat_after`)**: the "task completion" notification shipped 2026-08-12 (`task.updated` completion detection, see the update note above) has a known limitation for recurring tasks with `repeat_after` set — after marking done, Vikunja automatically reopens the task in the same update (`done` flips back to `false`), so the completion detection misses it and no notification is sent. For the tested conclusion and details, see the "Error handling and known limitations" section of [`docs/superpowers/specs/2026-08-12-vikunja-per-user-telegram-routing-design.md`](superpowers/specs/2026-08-12-vikunja-per-user-telegram-routing-design.md).
2. **There is no true "global webhook"**: Vikunja's Settings has a "Webhook Notifications" panel whose UI says "receive events from all your projects" — a genuinely cross-project global webhook — but it can only be configured and invoked through browser login state (JWT): the `PUT /api/v1/user/settings/webhooks` endpoint is denied outright to personal API Tokens (even with all permissions ticked). And that global panel itself only exposes three events to choose from — `task.overdue`, `task.reminder.fired`, `tasks.overdue` — while `task.assignee.created` is not exposed at the global level, so it could only ever be registered per-project anyway. After evaluation, we decided not to use the global panel: `task.assignee.created` must be maintained per-project by script anyway, and moving `task.reminder.fired`/`task.overdue` over to the global panel would only add another config entry point plus a "global + project duplicate sending" risk, so all three events stay registered per-project in `register-telegram-webhooks.sh`.
3. **`VIKUNJA_OUTGOINGREQUESTS_ALLOWNONROUTABLEIPS=true`**: Vikunja ships SSRF protection that by default refuses to deliver webhooks (as well as avatar downloads and migration imports) to private IP ranges (`172.16.0.0/12` etc.), and `vikunja-notify-relay`/`apprise` are both in the same `proxy` network's private range, so this switch must be opened for delivery to succeed. The switch is global and affects more than webhooks; it's an acceptable trade-off for this repo's single-user self-hosted scenario, and has been added to `vps_oracle/compose/vikunja/docker-compose.yml`.
4. **relay and vikunja merged into one compose stack**: `vikunja-notify-relay` was originally a separate directory/stack; later it was merged into `vps_oracle/compose/vikunja/docker-compose.yml` as a second service as requested (this repo's convention already allows "one compose stack can define multiple services"), the code moved to the `vps_oracle/compose/vikunja/notify-relay/` subdirectory with `build:` pointed at it. Container name and network behavior are unchanged — only the file location went from a standalone directory to part of the vikunja stack.

## Reproducing / adding a webhook for a new project

Step 1 configures one `vikunja-tg-<username>` target per Vikunja account. Step 3 registers the four events and is done per-project, unrelated to accounts — a new account only needs step 1 and does not need to re-run step 3 (unless a new project was also created).

```bash
# 1. apprise side: configure one target per Vikunja account (not a shared one),
#    key assembled by convention as vikunja-tg-<username> (username all lowercase)
docker run --rm --network proxy curlimages/curl:8.10.1 -s -X POST \
  --data-urlencode "urls=tgram://<bot_token>/<chat_id>/" \
  http://apprise:8000/add/vikunja-tg-<username>

# 2. vikunja stack: build and start (the vikunja app + vikunja-notify-relay, two services)
cd vps_oracle/compose/vikunja
docker compose up -d --build

# 3. register the four-event webhook for the given project (or no arg = all real projects)
VIKUNJA_TOKEN=tk_xxx ./register-telegram-webhooks.sh          # all
VIKUNJA_TOKEN=tk_xxx ./register-telegram-webhooks.sh 5 7      # only projects 5 and 7
```

Missing step 1 (or a typoed username) produces no visible error — that account's notifications silently vanish, the relay only leaves a single warning line in its own log (`docker logs vikunja-notify-relay`), and nothing looks off on the Apprise/Telegram side. For the naming convention and the currently-configured target list, see the "Apprise target naming convention" section of [`docs/superpowers/specs/2026-08-12-vikunja-per-user-telegram-routing-design.md`](superpowers/specs/2026-08-12-vikunja-per-user-telegram-routing-design.md).

`VIKUNJA_TOKEN` is generated from Vikunja Settings → API Tokens, never written to disk, passed manually each time (usage is low enough that there's no point keeping a high-privilege token resident in `.env`). The Telegram bot token / chat id also never enters git, existing only as runtime data in the apprise store (host path `/etc/apprise/config/store`, outside this repo's scope).

**Before re-running the script, remember to delete old webhooks first**: Vikunja's `PUT .../webhooks` is "create", not "update"; if you change the contents of `register-telegram-webhooks.sh` and re-run without deleting the old records, each event gets registered twice and you receive duplicate messages. To delete: `GET /api/v1/projects/{id}/webhooks` to list ids, then `DELETE /api/v1/projects/{id}/webhooks/{webhook_id}` one by one.

**After changing `notify-relay/app.py`, rebuild**: `docker compose up -d --build` (run under `vps_oracle/compose/vikunja/`); without `--build`, compose won't re-package the image and the container keeps running the old code. `docker compose up -d --build` only rebuilds changed services and won't touch the `vikunja` app itself.

## Verification method

After changing code, first `curl -X POST` the relay's `http://vikunja-notify-relay:8080/` directly with a hand-written fake payload (`{"event_name":"task.assignee.created","data":{"task":{"id":1,"title":"..."},"project":{"title":"..."}}}`), and check `docker logs vikunja-notify-relay` for `forwarded task.assignee.created -> apprise (jerome): 200` (the log format carries the username; see `delivery_log_line` in `app.py`), and whether Telegram received the message; then create a task in a real project, assign it to yourself, and confirm the whole chain (`docker logs vikunja`, `docker logs vikunja-notify-relay`, `docker logs apprise` all need checking for errors). Both stages were tested repeatedly at rollout, including using temporary projects + a temporary http-echo container to capture the real payload structure of `task.assignee.created`/`task.updated`/`task.reminder.fired`/`task.overdue` (deleted immediately after use).