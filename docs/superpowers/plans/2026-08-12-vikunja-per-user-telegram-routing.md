# Vikunja Per-User Telegram Routing + Task-Completed Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route Vikunja's Telegram notifications to each Vikunja account's own Telegram chat instead of one shared chat, and add a new "task completed" notification fanned out to every assignee.

**Architecture:** `vikunja-notify-relay` (a single-file Python stdlib HTTP server) keeps translating raw Vikunja webhook payloads into `{title, body}` for Apprise, but now derives the Apprise target key from the Vikunja username embedded in each payload (`vikunja-tg-{username.lower()}`) instead of a single hardcoded target. `task.updated` is registered as a fourth webhook event and treated as a "task completed" signal only when `task.done` just flipped true (detected via `done_at` being within a few seconds of the event's own timestamp — no relay-side state needed), then fanned out to every entry in `task.assignees[]`.

**Tech Stack:** Python 3.12 stdlib only (`http.server`, `urllib.request`, `unittest`) — no new dependencies. Docker Compose. Apprise API (`caronc/apprise-api`) as the outbound Telegram sender.

## Global Constraints

- No new containers — all changes are confined to `vps_oracle/compose/vikunja/notify-relay/app.py`, `vps_oracle/compose/vikunja/docker-compose.yml`, `vps_oracle/compose/vikunja/register-telegram-webhooks.sh`, plus runtime-only Apprise store entries (never committed to git).
- `notify-relay` stays dependency-free stdlib Python — do not add `requirements.txt` or third-party packages.
- Apprise target naming convention: `vikunja-tg-{username}`, username always lowercased before use, on both the relay side and when creating targets in Apprise.
- Done-completion detection window: `DONE_WINDOW_SECONDS = 10`.
- Never write a live Telegram bot token or Vikunja API token into any file that gets committed — extract into shell variables at execution time only, matching the existing convention in [2026-08-03-vikunja-apprise-telegram-webhooks.md](../../2026-08-03-vikunja-apprise-telegram-webhooks.md).
- Spec: [2026-08-12-vikunja-per-user-telegram-routing-design.md](../specs/2026-08-12-vikunja-per-user-telegram-routing-design.md).

## Reference data gathered during planning

Read directly from the live Vikunja sqlite DB (`/etc/vikunja/db/vikunja.db`, read-only) so the tasks below use real IDs instead of "look it up yourself":

- Users: `jerome` (id 1), `Bridget` (id 3). There is also a built-in `Demo` account (id 2) — out of scope, not one of the two accounts being routed.
- jerome-owned projects (already have `task.assignee.created`/`task.reminder.fired`/`task.overdue` webhooks registered, **do not** rerun the full script on these — it would duplicate them): `1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 17, 18`.
- Bridget-owned projects (**zero** webhooks registered so far — not just "Love Bird OP" as originally mentioned, all four of her projects are missing registration): `19` (Inbox), `20` (Love Bird OP), `21` (RedNode-Personal-OP), `22` (As Youtuber).
- Project `2` is `Demo`'s personal Inbox — out of scope, leave it alone.
- `jerome` and `bridget` are separate accounts with no shared/cross-owned projects observed, so `GET /api/v1/projects` under one account's API token will not return the other's projects — each needs their own `VIKUNJA_TOKEN` for the webhook-registration task.
- Pre-existing, unrelated stray data: webhook id `134` targets a nonexistent `project_id=15` pointing at a long-gone `webhook-echo-tmp2` test container (leftover from the original integration testing in the 2026-08-03 doc, never cleaned up). It's inert (the project doesn't exist) and out of scope for this plan — not touched here.
- Existing Apprise target `vikunja-tg` (jerome's current single target): `tgram://<bot_token>/-5463203030/` — bot is `alert_jerome_bot`.
- New Telegram group for Bridget: "Vikunja Notifaciton Bridget", `chat_id = -5451306307` (found via `getUpdates` on the existing bot, which is already a member — same bot token is reused, no new bot needed).

---

### Task 1: Per-user routing + done-detection logic in the relay

**Files:**
- Modify: `vps_oracle/compose/vikunja/notify-relay/app.py`
- Create: `vps_oracle/compose/vikunja/notify-relay/test_app.py`

**Interfaces:**
- Produces (used by Task 2's runtime config and by Task 6's live verification):
  - `app.APPRISE_BASE_URL` — module-level constant read from env var `APPRISE_BASE_URL` (replaces the old `APPRISE_NOTIFY_URL`).
  - `app.apprise_target_url(username: str) -> str`
  - `app.single_event_recipient(event_name: str, data: dict) -> str | None`
  - `app.is_task_just_completed(event_time: str, task: dict) -> bool`
  - `app.completed_assignee_usernames(task: dict) -> list[str]`
  - `app.build_body(project_title: str, task_title: str, task_link: str) -> str`
  - `app.EVENT_TITLES` — now includes `"task.updated": "✅ Task completed"`.

- [ ] **Step 1: Write the failing tests**

Create `vps_oracle/compose/vikunja/notify-relay/test_app.py`:

```python
import os

os.environ.setdefault("VIKUNJA_BASE_URL", "https://vikunja.example")
os.environ.setdefault("APPRISE_BASE_URL", "http://apprise:8000")

import unittest

import app


class TestAppriseTargetUrl(unittest.TestCase):
    def test_lowercases_and_prefixes_username(self):
        self.assertEqual(
            app.apprise_target_url("Jerome"),
            "http://apprise:8000/notify/vikunja-tg-jerome",
        )


class TestSingleEventRecipient(unittest.TestCase):
    def test_assignee_created_reads_assignee_field(self):
        data = {"assignee": {"username": "bridget"}, "doer": {"username": "jerome"}}
        self.assertEqual(app.single_event_recipient("task.assignee.created", data), "bridget")

    def test_reminder_fired_reads_user_field(self):
        data = {"user": {"username": "jerome"}}
        self.assertEqual(app.single_event_recipient("task.reminder.fired", data), "jerome")

    def test_overdue_reads_user_field(self):
        data = {"user": {"username": "jerome"}}
        self.assertEqual(app.single_event_recipient("task.overdue", data), "jerome")

    def test_unknown_event_returns_none(self):
        data = {"doer": {"username": "jerome"}}
        self.assertIsNone(app.single_event_recipient("task.updated", data))

    def test_missing_user_object_returns_none(self):
        self.assertIsNone(app.single_event_recipient("task.assignee.created", {}))


class TestIsTaskJustCompleted(unittest.TestCase):
    def test_true_when_done_and_done_at_matches_event_time(self):
        task = {"done": True, "done_at": "2026-08-12T09:00:02.123456789+08:00"}
        self.assertTrue(app.is_task_just_completed("2026-08-12T09:00:00+08:00", task))

    def test_false_when_not_done(self):
        task = {"done": False, "done_at": "2026-08-12T09:00:00+08:00"}
        self.assertFalse(app.is_task_just_completed("2026-08-12T09:00:00+08:00", task))

    def test_false_when_done_at_far_from_event_time(self):
        task = {"done": True, "done_at": "2026-08-01T09:00:00+08:00"}
        self.assertFalse(app.is_task_just_completed("2026-08-12T09:00:00+08:00", task))

    def test_false_when_done_at_missing(self):
        task = {"done": True}
        self.assertFalse(app.is_task_just_completed("2026-08-12T09:00:00+08:00", task))


class TestCompletedAssigneeUsernames(unittest.TestCase):
    def test_extracts_usernames_from_assignee_list(self):
        task = {"assignees": [{"username": "jerome"}, {"username": "Bridget"}]}
        self.assertEqual(app.completed_assignee_usernames(task), ["jerome", "Bridget"])

    def test_empty_when_no_assignees(self):
        self.assertEqual(app.completed_assignee_usernames({}), [])

    def test_skips_entries_without_username(self):
        task = {"assignees": [{"id": 1}, {"username": "jerome"}]}
        self.assertEqual(app.completed_assignee_usernames(task), ["jerome"])


class TestBuildBody(unittest.TestCase):
    def test_escapes_html_and_formats_lines(self):
        body = app.build_body("<Proj>", "Buy milk & eggs", "https://vikunja.example/tasks/5")
        self.assertIn("Project: <b>&lt;Proj&gt;</b>", body)
        self.assertIn("Buy milk &amp; eggs", body)
        self.assertIn('href="https://vikunja.example/tasks/5"', body)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd vps_oracle/compose/vikunja/notify-relay && python3 -m unittest test_app.py -v`
Expected: FAIL/ERROR — `AttributeError: module 'app' has no attribute 'apprise_target_url'` (and similarly for the other new functions; the current `app.py` doesn't have them yet).

- [ ] **Step 3: Rewrite `app.py`**

Replace the full contents of `vps_oracle/compose/vikunja/notify-relay/app.py` with:

```python
#!/usr/bin/env python3
"""Translate Vikunja webhook payloads into formatted Telegram messages via Apprise.

Apprise's /notify field-remap (query-string ":source=target") only supports
one-to-one field renaming, not combining project name + task title + a
constructed task link into one message. This relay does that combination,
then posts a ready-made {title, body} to Apprise so it can stay a dumb sender.

Routing: each Vikunja user gets their own Apprise target, named
"vikunja-tg-{username}" (lowercased). task.assignee.created / task.reminder.fired /
task.overdue already arrive one-per-user from Vikunja, so the relay just reads
the embedded user off each request. task.updated has no such per-user
delivery and carries the full post-update task snapshot with no diff, so the
relay treats it as a "task completed" notification only when task.done is
true and done_at is within DONE_WINDOW_SECONDS of the event's own timestamp,
then fans out to every current assignee.
"""
import html
import json
import os
import re
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VIKUNJA_BASE_URL = os.environ["VIKUNJA_BASE_URL"].rstrip("/")
APPRISE_BASE_URL = os.environ["APPRISE_BASE_URL"].rstrip("/")

DONE_WINDOW_SECONDS = 10

EVENT_TITLES = {
    "task.assignee.created": "📌 Task assigned to you",
    "task.reminder.fired": "⏰ Task due soon",
    "task.overdue": "🔴 Task overdue",
    "task.updated": "✅ Task completed",
}

# Events that Vikunja already dispatches once per recipient (one webhook
# delivery per user), keyed to where that user's object lives in `data`.
SINGLE_USER_FIELD = {
    "task.assignee.created": "assignee",
    "task.reminder.fired": "user",
    "task.overdue": "user",
}

_FRACTION_RE = re.compile(r"(\.\d{1,6})\d*")


def _parse_go_time(value):
    """Parse a Go RFC3339Nano timestamp (up to 9 fractional digits) into a datetime."""
    return datetime.fromisoformat(_FRACTION_RE.sub(r"\1", value))


def apprise_target_url(username):
    return f"{APPRISE_BASE_URL}/notify/vikunja-tg-{username.strip().lower()}"


def single_event_recipient(event_name, data):
    """Return the username this single-user event is for, or None."""
    field = SINGLE_USER_FIELD.get(event_name)
    if field is None:
        return None
    user = data.get(field) or {}
    return user.get("username")


def is_task_just_completed(event_time, task):
    """True if `task` transitioned to done at (approximately) `event_time`."""
    if not task.get("done"):
        return False
    done_at = task.get("done_at")
    if not done_at:
        return False
    try:
        delta = abs((_parse_go_time(event_time) - _parse_go_time(done_at)).total_seconds())
    except (ValueError, TypeError):
        return False
    return delta < DONE_WINDOW_SECONDS


def completed_assignee_usernames(task):
    return [a["username"] for a in task.get("assignees") or [] if a.get("username")]


def build_body(project_title, task_title, task_link):
    return (
        f"Project: <b>{html.escape(project_title)}</b>\n"
        f'Task: <a href="{html.escape(task_link)}">{html.escape(task_title)}</a>'
    )


def send_to_apprise(username, title, body):
    url = apprise_target_url(username)
    notify_payload = json.dumps({"title": title, "body": body, "format": "html"}).encode()
    req = urllib.request.Request(
        url,
        data=notify_payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.status


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        self.send_response(200)
        self.end_headers()

        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            print("ignored: invalid JSON body", flush=True)
            return

        event_name = payload.get("event_name")
        title = EVENT_TITLES.get(event_name)
        if title is None:
            print(f"ignored: unhandled event {event_name!r}", flush=True)
            return

        data = payload.get("data") or {}
        task = data.get("task") or {}
        project = data.get("project") or {}

        task_title = task.get("title")
        task_id = task.get("id")
        project_title = project.get("title", "")

        if not task_title or not task_id:
            print(f"ignored: {event_name} payload missing task title/id", flush=True)
            return

        if event_name == "task.updated":
            event_time = payload.get("time")
            if not event_time or not is_task_just_completed(event_time, task):
                print(f"ignored: task.updated for task {task_id} is not a completion", flush=True)
                return
            recipients = completed_assignee_usernames(task)
            if not recipients:
                print(f"ignored: task {task_id} completed with no assignees", flush=True)
                return
        else:
            username = single_event_recipient(event_name, data)
            if not username:
                print(f"ignored: {event_name} payload missing recipient user", flush=True)
                return
            recipients = [username]

        link = f"{VIKUNJA_BASE_URL}/tasks/{task_id}"
        body = build_body(project_title, task_title, link)

        for username in recipients:
            try:
                status = send_to_apprise(username, title, body)
                print(f"forwarded {event_name} -> apprise ({username}): {status}", flush=True)
            except Exception as exc:
                print(f"error forwarding {event_name} to apprise ({username}): {exc}", flush=True)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"listening on :{port}", flush=True)
    server.serve_forever()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd vps_oracle/compose/vikunja/notify-relay && python3 -m unittest test_app.py -v`
Expected: all tests `PASS` (14 tests: 1 + 5 + 4 + 3 + 1).

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/vikunja/notify-relay/app.py vps_oracle/compose/vikunja/notify-relay/test_app.py
git commit -m "Route vikunja notifications per-user and add task-completed detection"
```

---

### Task 2: Wire the relay's runtime config to the new routing

**Files:**
- Modify: `vps_oracle/compose/vikunja/docker-compose.yml`

**Interfaces:**
- Consumes: `app.APPRISE_BASE_URL` env var name from Task 1.
- Produces: running `vikunja-notify-relay` container with the new code + config live, which Task 5/6 depend on.

- [ ] **Step 1: Update the `vikunja-notify-relay` service environment**

In `vps_oracle/compose/vikunja/docker-compose.yml`, replace:

```yaml
    image: vikunja-notify-relay:1.0.0
```

with:

```yaml
    image: vikunja-notify-relay:1.1.0
```

and replace:

```yaml
      APPRISE_NOTIFY_URL: "http://apprise:8000/notify/vikunja-tg"
```

with:

```yaml
      APPRISE_BASE_URL: "http://apprise:8000"
```

- [ ] **Step 2: Rebuild and restart the relay**

Run:
```bash
cd vps_oracle/compose/vikunja
docker compose up -d --build vikunja-notify-relay
```

- [ ] **Step 3: Verify it starts cleanly**

Run: `docker logs vikunja-notify-relay --tail 20`
Expected: `listening on :8080` with no `KeyError` traceback (a `KeyError: 'APPRISE_NOTIFY_URL'` here would mean the old env var name is still referenced somewhere, or `APPRISE_BASE_URL` didn't get picked up — check `docker compose config` output for the service if so).

- [ ] **Step 4: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/vikunja/docker-compose.yml
git commit -m "Point vikunja-notify-relay at APPRISE_BASE_URL instead of a fixed target"
```

---

### Task 3: Register `task.updated` as a webhook event

**Files:**
- Modify: `vps_oracle/compose/vikunja/register-telegram-webhooks.sh`

**Interfaces:**
- Produces: updated `EVENTS` array, consumed by Task 5 when the script is actually run against Bridget's projects.

- [ ] **Step 1: Add `task.updated` to the events list**

In `vps_oracle/compose/vikunja/register-telegram-webhooks.sh`, replace:

```bash
# 三个事件都发到同一个 relay 地址，relay 自己根据 payload 里的 event_name 分流格式化。
EVENTS=("task.assignee.created" "task.reminder.fired" "task.overdue")
```

with:

```bash
# 四个事件都发到同一个 relay 地址，relay 自己根据 payload 里的 event_name 分流格式化。
EVENTS=("task.assignee.created" "task.reminder.fired" "task.overdue" "task.updated")
```

- [ ] **Step 2: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/vikunja/register-telegram-webhooks.sh
git commit -m "Register task.updated webhook for the new task-completed notification"
```

(No live run yet — running this script against projects that already have the other three events registered would duplicate them. Task 5 handles the actual rollout, split by which projects already have webhooks.)

---

### Task 4: Create per-user Apprise targets

No repo files change in this task — Apprise's persistent store is runtime-only, matching the existing convention that Telegram credentials never enter git.

**Interfaces:**
- Produces: Apprise targets `vikunja-tg-jerome` and `vikunja-tg-bridget`, consumed by `app.apprise_target_url()` at runtime and by Task 6's verification.

- [ ] **Step 1: Extract the existing bot token into a shell variable (do not print or save it to a file)**

```bash
BOT_URL=$(docker run --rm --network proxy curlimages/curl:8.10.1 -s \
  http://apprise:8000/json/urls/vikunja-tg | python3 -c \
  "import sys, json; print(json.load(sys.stdin)['urls'][0]['url'])")
BOT_TOKEN=$(python3 -c "
import urllib.parse as u
print(u.unquote(u.urlparse('${BOT_URL}').netloc))
")
```

- [ ] **Step 2: Create `vikunja-tg-jerome` (same chat as the current `vikunja-tg` target)**

```bash
docker run --rm --network proxy curlimages/curl:8.10.1 -s -X POST \
  --data-urlencode "urls=tgram://${BOT_TOKEN}/-5463203030/" \
  http://apprise:8000/add/vikunja-tg-jerome
```

- [ ] **Step 3: Create `vikunja-tg-bridget` (new group "Vikunja Notifaciton Bridget")**

```bash
docker run --rm --network proxy curlimages/curl:8.10.1 -s -X POST \
  --data-urlencode "urls=tgram://${BOT_TOKEN}/-5451306307/" \
  http://apprise:8000/add/vikunja-tg-bridget
```

- [ ] **Step 4: Verify both targets are stored**

```bash
docker run --rm --network proxy curlimages/curl:8.10.1 -s http://apprise:8000/json/urls/vikunja-tg-jerome
docker run --rm --network proxy curlimages/curl:8.10.1 -s http://apprise:8000/json/urls/vikunja-tg-bridget
```

Expected: both return a JSON object with a `urls` array containing one `service_name: "Telegram"` entry each, `enabled: true`.

(Nothing to commit — this step only writes to Apprise's runtime store.)

---

### Task 5: Roll out the `task.updated` webhook across all real projects

**Files:** none (API calls against the running Vikunja container only).

**Interfaces:**
- Consumes: `EVENTS` array from Task 3 (for Bridget's projects), the relay URL `http://vikunja-notify-relay:8080/` (unchanged), project/user IDs from "Reference data gathered during planning" above.

- [ ] **Step 1: Register all four events on Bridget's four projects (currently zero webhooks)**

Generate a Vikunja API token under **Bridget's own login** (Settings → API Tokens), then:

```bash
cd vps_oracle/compose/vikunja
VIKUNJA_TOKEN=<bridget's token> ./register-telegram-webhooks.sh 19 20 21 22
```

Expected: for each of the 4 project IDs, all 4 events print `200`.

- [ ] **Step 2: Add only `task.updated` to jerome's 14 already-registered projects**

Generate a Vikunja API token under **jerome's own login**, then run this loop directly (do **not** rerun the full script here — it would duplicate the three already-registered events):

```bash
VIKUNJA_TOKEN=<jerome's token>
for PID in 1 3 4 5 6 7 8 9 10 11 12 13 17 18; do
  STATUS=$(docker run --rm --network proxy curlimages/curl:8.10.1 -s -X PUT \
    -H "Authorization: Bearer ${VIKUNJA_TOKEN}" -H "Content-Type: application/json" \
    -d '{"target_url":"http://vikunja-notify-relay:8080/","events":["task.updated"]}' \
    -o /dev/null -w "%{http_code}" \
    "http://vikunja:3456/api/v1/projects/${PID}/webhooks")
  echo "project ${PID}: ${STATUS}"
done
```

Expected: `200` printed for all 14 project IDs.

- [ ] **Step 3: Verify the end state (read-only DB check)**

```bash
sudo python3 -c "
import sqlite3
con = sqlite3.connect('/etc/vikunja/db/vikunja.db')
cur = con.cursor()
for row in cur.execute('SELECT project_id, events FROM webhooks WHERE target_url LIKE \"%vikunja-notify-relay%\" ORDER BY project_id'):
    print(row)
"
```

Expected: every project ID in `{1,3,4,...,13,17,18,19,20,21,22}` appears with exactly 4 rows (one per event), each `events` column showing a single-element JSON array (`register-telegram-webhooks.sh` and the raw `PUT` above both register one event per call, not a combined array).

(No git commit — this task only mutates Vikunja's live webhook registrations.)

---

### Task 6: End-to-end verification

**Files:** none (manual/live verification, matching the existing project convention documented in [2026-08-03-vikunja-apprise-telegram-webhooks.md](../../2026-08-03-vikunja-apprise-telegram-webhooks.md)).

- [ ] **Step 1: Fake-payload tests against the live relay**

Run each of these (all via `docker run --rm --network proxy curlimages/curl:8.10.1 -s -X POST -H "Content-Type: application/json" -d '<json>' http://vikunja-notify-relay:8080/`), then check `docker logs vikunja-notify-relay --tail 20` after each:

1. Assignee routing — `assignee.username` = `bridget`:
   ```json
   {"event_name":"task.assignee.created","data":{"task":{"id":1,"title":"Test task"},"project":{"title":"Test project"},"assignee":{"username":"bridget"},"doer":{"username":"jerome"}}}
   ```
   Expected log: `forwarded task.assignee.created -> apprise (bridget): 200`, and the Bridget Telegram group receives the message.

2. Task completed, both assignees (use a `done_at` equal to "now" in RFC3339 — e.g. `date -u +%Y-%m-%dT%H:%M:%SZ`):
   ```json
   {"event_name":"task.updated","time":"<now>","data":{"task":{"id":1,"title":"Test task","done":true,"done_at":"<now>","assignees":[{"username":"jerome"},{"username":"bridget"}]},"project":{"title":"Test project"},"doer":{"username":"jerome"}}}
   ```
   Expected log: two `forwarded task.updated -> apprise (...): 200` lines, one per username; both Telegram chats receive "✅ Task completed".

3. Not done — same payload as #2 but `"done":false`:
   Expected log: `ignored: task.updated for task 1 is not a completion`; no Telegram messages.

4. Stale `done_at` — same as #2 but `"done_at":"2020-01-01T00:00:00Z"`:
   Expected log: `ignored: task.updated for task 1 is not a completion`; no Telegram messages.

5. Unknown recipient — assignee.created with `"username":"nobody"`:
   Expected log: `error forwarding task.assignee.created to apprise (nobody): ...` (non-200 from Apprise), relay process keeps running (verify with a follow-up request from case 1 that it still responds).

- [ ] **Step 2: Real task in Vikunja**

In project 20 ("Love Bird OP"), create a task, assign it to both `jerome` and `bridget`, set a reminder a minute out, then mark it done. Check `docker logs vikunja`, `docker logs vikunja-notify-relay`, `docker logs apprise` for errors, and confirm both Telegram chats receive the assignment message, the reminder, and the completion message.

- [ ] **Step 3: Repeat-task check (documents the known limitation, doesn't need to pass)**

Create a task with `repeat_after` set (e.g. repeats daily) in the same project, assign it, mark it done. Check whether a completion notification arrives. Record the outcome in a follow-up note to `docs/superpowers/specs/2026-08-12-vikunja-per-user-telegram-routing-design.md`'s "已知限制" section — confirming either that the limitation is real (no notification, as predicted) or that it doesn't apply to this Vikunja version (notification arrives).

- [ ] **Step 4 (optional, non-blocking): retire the old shared target**

Once the above is stable for a few days:

```bash
docker run --rm --network proxy curlimages/curl:8.10.1 -s -X POST http://apprise:8000/del/vikunja-tg
```
