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
