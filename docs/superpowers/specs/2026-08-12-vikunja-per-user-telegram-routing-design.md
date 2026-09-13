# Vikunja Per-User Telegram Notification Routing + Task-Completion Notification — Design

Date: 2026-08-12

## Background

The Vikunja → `vikunja-notify-relay` → Apprise → Telegram chain established in [2026-08-03-vikunja-apprise-telegram-webhooks.md](../../2026-08-03-vikunja-apprise-telegram-webhooks.md) was originally designed as a "single-user instance": `notify-relay/app.py` hardcodes `APPRISE_NOTIFY_URL` to `http://apprise:8000/notify/vikunja-tg`, so regardless of which project, which event, or who it was assigned to, everything forwarded to the same apprise target and the same Telegram group "Vikunja Notification".

Now Vikunja has a second real account (`bridget`, previously just `jerome`), so notifications for tasks assigned to different accounts need to reach each person's own Telegram. At the same time, we want to add the currently-missing "task marked done" notification type, and the completion notification should go to all of the task's assignees (not just the operator).

## Goals and scope

- The three already-registered events `task.assignee.created` / `task.reminder.fired` / `task.overdue` route to the right person's Telegram based on the user identity carried in the payload.
- New: when a task is marked done, notify **all** of that task's assignees (each routed to their own Telegram), and only fire at the moment it "just became done" — not mistakenly on edits to other fields.
- Support adding more Vikunja accounts in the future without changing relay code.

**Out of scope:**
- No "task reopened (un-done)" notification; only care about the moment it becomes done.
- Not solving the known limitation of "repeating tasks with `repeat_after` being marked done" (see "Known limitations" below) — ship as-is for now, revisit if real-world testing shows it affects common scenarios.
- Not using Vikunja's global per-user webhook panel (`PUT /api/v1/user/settings/webhooks`) — a personal API Token can't reach that endpoint, and [the existing doc](../../2026-08-03-vikunja-apprise-telegram-webhooks.md) already evaluated this; keep the current per-project registration approach.

## Background research: the actual structure of Vikunja webhook payloads

Based on the source tag `v2.4.0` (matching the `vikunja/vikunja:2.4.0` version pinned in compose) — specifically `pkg/models/events.go` / `listeners.go` — not speculation:

- The outer envelope is uniformly `{event_name, time, data}`.
- `task.assignee.created`: `data = {task, assignee, doer}`. Vikunja, in `task_assignees.go`, calls `Dispatch` once **per assignee** (bulk-assigning multiple people also dispatches one by one in a loop); `assignee` is the person being assigned this time.
- `task.reminder.fired` / `task.overdue`: `data = {task, user, project, [reminder]}`. Internally Vikunja marks these two as `RegisterUserDirectedEventForWebhook` ("user-directed event"); `task_reminder.go` / `task_overdue_reminder.go` call `Dispatch` once **per user to be notified** (`user` is that person).
- Key point: our webhook is registered at the **project level** (`register-telegram-webhooks.sh`). Checking `WebhookListener.Handle`'s matching logic — project-level webhooks match only on `project_id`, and receive every event regardless of whether it's user-directed. So all the above "one per person" dispatches hit our single relay URL, each POST carrying a different `user`. **The relay doesn't need to do its own fan-out — Vikunja already sends one event per person at the source.**
- `task.updated`: `data = {task, doer}`, only a full post-update snapshot, **no diff, no marker of "which field changed"**. It's also not a user-directed event; one operation (regardless of assignee count) dispatches once, and it won't auto-route per person. Triggers include: ordinary field edits (`tasks.go`), assignee add/remove (`task_assignees.go`, so the assign action itself also fires a `task.updated`), and Kanban board drag-to-bucket (`kanban_task_bucket.go`, including the "drag into Done bucket auto-sets `done=true`" case).
- `task.done_at`: the server sets this to the current time at the save where the task actually becomes `done=true` ("When the task was marked as done. Set by the server"); non-completion updates do not touch this field. This is the key basis for detecting "just done" (see "Completion detection logic" below).
- `user.User`'s externally visible fields are only `id`, `name`, `username`, `email` (may be empty), `bot_owner_id` (bot users only) — the rest are `json:"-"` and won't appear in the payload.
- The `task.updated` event struct itself carries no `project` field (only `{task, doer}`), but `WebhookListener.Handle` has auto-fill logic for **project-level webhooks**: if the payload has no `project` field and the webhook hangs under a project, it auto-resolves that project into `data.project`. Our webhook is project-level, so the `task.updated` payload we actually receive still carries `data.project` — the completion message body can reuse the existing "Project / Task / link" three-line format without special-casing a missing project.

## Architecture / data flow

No new container; the changes are concentrated in the routing logic of `vps_oracle/compose/vikunja/notify-relay/app.py`, plus creating one apprise target per person.

```
Vikunja
  ├─ task.assignee.created ──┐
  ├─ task.reminder.fired ────┤  Vikunja already dispatches per user,
  ├─ task.overdue ───────────┘  each POST the relay receives corresponds to one person
  │
  └─ task.updated(newly registered)   the relay itself judges "just done",
                                  if so reads task.assignees[] and iterates
        ↓ all POST to the same relay URL (unchanged)
  vikunja-notify-relay:8080
        ↓ two paths by event_name (see below)
        ↓ determine recipient username(s) (one or more) → build apprise target key
  apprise:8000/notify/vikunja-tg-{username}
        ↓
  Telegram(each person's own chat)
```

## Routing logic

### Path 1: `task.assignee.created` / `task.reminder.fired` / `task.overdue`

Vikunja already dispatches "one event per person", so the relay reads a single field without iterating:

| event | field to read |
|---|---|
| `task.assignee.created` | `data.assignee.username` |
| `task.reminder.fired` | `data.user.username` |
| `task.overdue` | `data.user.username` |

After getting the username, normalize with `.lower()`, build `vikunja-tg-{username}`, and POST to apprise (message format same as current: HTML, three lines for project/task/hyperlink).

### Path 2: `task.updated` (completion detection + broadcast to all assignees)

1. **Filter**: only process events where `data.task.done == true` and `abs(payload.time - data.task.done_at) < threshold` (initially 10 seconds, tunable); ignore everything else (log one line explaining the reason, don't forward to apprise). This time-proximity check relies on the `done_at` semantics researched above — non-completion edits don't refresh `done_at`, so it reliably distinguishes "just done" from "edited another field of an already-done task" and from "assign/board-drag fires a related `task.updated`".
2. **Broadcast**: after passing the filter, iterate `data.task.assignees[]` (an array, each element a full user object), build `vikunja-tg-{username}` per assignee, and send each one a "✅ Task completed" message (added to `EVENT_TITLES` in `app.py`).
3. When `assignees` is an empty array (marked done with no one assigned), send nothing, only log.

## Apprise target naming convention (how the user → Telegram mapping is stored)

No explicit id/mapping table; directly use the **Vikunja login username to build the apprise target key**: `vikunja-tg-{username}` (all lowercase). The relay side is zero-state, zero-config — adding a new account only requires `POST /add/vikunja-tg-<username>` on the Apprise side to store a new target; neither relay code nor config changes.

Cost: depends on Vikunja usernames being stable; if a username is renamed, the mapping breaks. But this is a two-person self-hosted service, low probability and easy to diagnose, not worth the maintenance cost of an explicit mapping table.

### Targets needed now

| username | status | bot token | chat_id |
|---|---|---|---|
| `jerome` | an equivalent target already exists (old key is `vikunja-tg`); create `vikunja-tg-jerome` under the new convention (same tgram URL) | reuse existing `alert_jerome_bot` | `-5463203030` (existing "Vikunja Notification" group) |
| `bridget` | brand new | reuse the same `alert_jerome_bot` (token unchanged) | `-5451306307` (group "Vikunja Notifaciton Bridget", found via `getUpdates`; the bot is already a member) |

The bot token goes neither into this doc nor into git; at runtime it lives only in Apprise's persistent store (following the [existing convention](../../2026-08-03-vikunja-apprise-telegram-webhooks.md)).

`vikunja-notify-relay`'s env var `APPRISE_NOTIFY_URL` (currently the hardcoded full path `http://apprise:8000/notify/vikunja-tg`) must change to a base URL (e.g. `APPRISE_BASE_URL=http://apprise:8000`), with the relay code building `f"{APPRISE_BASE_URL}/notify/vikunja-tg-{username}"`.

After the old `vikunja-tg` target's migration is verified, it can be deleted via `POST /del/vikunja-tg` to avoid confusion from coexisting with the new convention (non-blocking; can wait until verification is stable).

## Error handling and known limitations

- **Apprise target not found** (typo'd username, or a new account with no target yet): that POST to apprise gets a non-200, the relay just logs one warning line and skips, without affecting the other assignees in the same batch — especially in path 2 when iterating multiple assignees, one failure shouldn't block the others.
- **Payload missing fields**: same as the current `app.py` logic — log one `ignored: ...` line and return, without crashing the handler.
- **Relay's response behavior to Vikunja unchanged**: returns 200 immediately upon receiving a POST (the current code already does this); Vikunja won't retry, so any relay-internal failure can only be diagnosed from logs after the fact — continuing the existing design, out of scope for this change.
- **Known limitation: repeating tasks with `repeat_after`**: when Vikunja marks such a task done, it auto-reopens it in the same update (`done` flips back to `false`, bumping the due date/reminder along the way), so by the time the `task.updated` event reaches the relay the `done` field may already be `false`, meaning the "completion" of this task can't be detected and no notification is sent. Temporarily accept this limitation; during the testing phase use a real repeating task to gauge the impact, and handle it separately only if it genuinely affects common scenarios.

  **2026-08-12 Task 6 test conclusion: the limitation is real.** Created a task in project 20 with `repeat_after=86400` (daily), `repeat_mode=2` (counts from completion time, i.e. `TaskRepeatModeFromCurrentDate`), and `due_date` set to the next day; assigned it to jerome + bridget, then marked it done via `POST /api/v1/tasks/{id}` with `done:true`. The response and a subsequent `GET` both show `done` already auto-flipped back to `false`, `due_date` pushed to "current time + 86400s" (consistent with the "counts from completion time" semantics), and the `done_at` field retained the timestamp of this completion action. `vikunja-notify-relay` logged `ignored: task.updated for task 65 is not a completion`, and Apprise showed no new send for this operation — confirming no completion notification is received, exactly matching the predicted behavior in this doc. The `repeat_after`/`repeat_mode` of this test task were also zeroed in the same request (turned into `0`/`0` in the response), but this is very likely a side effect of the newly-discovered "partial field update clears unfilled fields" issue (see the Task 6 report for details) rather than an independent "repeating task loses its repeat settings after completion" behavior; confirming it would require a request unaffected by that issue (e.g. explicitly including `repeat_after`/`repeat_mode` in the body). That was not expanded upon this round and does not affect the core "no completion notification received" conclusion above. Keeping the "not handling it for now" decision; if common scenarios turn out to be affected, revisit with compensation logic like "ignore this time but remember the last `due_date`, then re-evaluate on a later same-project same-assignee change within a short window".

## Config changes to sync

- `register-telegram-webhooks.sh`: add back `task.updated` to the `EVENTS` array (currently only assignee/reminder/overdue three).
- The newly created project "Love Bird OP" has no webhook registered yet; it needs the script run once along with the other projects (running the script with no arguments defaults to all real projects, including the new one — no separate handling needed).
- In `docker-compose.yml`, `vikunja-notify-relay`'s env var changes from `APPRISE_NOTIFY_URL` (full path) to `APPRISE_BASE_URL` (base URL).

## Verification steps

1. **Fake payloads straight at the relay**(`docker run --rm --network proxy curlimages/curl ... -X POST http://vikunja-notify-relay:8080/`, no touch on real Vikunja data):
   - `task.assignee.created`, with `assignee.username` set to `jerome`/`bridget` respectively → verify each routes to the right apprise target and each Telegram receives it.
   - `task.updated`, `done:true` with `done_at` equal to now, `assignees` with two people → verify both receive the "✅ completed" message.
   - `task.updated`, `done:false` → verify ignored (visible in logs, Telegram receives nothing).
   - `task.updated`, `done:true` but `done_at` long ago → verify ignored (simulating the "edited another field of a done task" false positive).
   - `assignee.username` set to a fake name with no apprise target → verify a warning is logged, relay doesn't crash, and other requests are unaffected.
2. **Small-scale real-environment verification**: create a task in "Love Bird OP", actually assign it to two accounts, mark it done, set a reminder, and confirm the full chain (`docker logs vikunja` / `vikunja-notify-relay` / `apprise`) is error-free with both people receiving their own Telegram messages. `task.overdue` is a daily cron trigger and hard to verify on demand, so it rides on the symmetry of sharing the same routing-logic code as `task.reminder.fired`, not triggered live specially.
3. Use a task with `repeat_after` to test marking done once, confirm whether the "Known limitations" behavior actually occurs, and record the result for later decide-whether-to-handle.

## Future extensions

- Adding more accounts: just `POST /add/vikunja-tg-<username>` on the Apprise side, no relay code change.
- If we later want routing by "project" rather than "person" (e.g. a project always notifying a team group instead of individuals), the current design doesn't support it and needs a separate evaluation — out of scope.