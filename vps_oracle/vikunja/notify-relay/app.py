#!/usr/bin/env python3
"""Translate Vikunja webhook payloads into formatted Telegram messages via Apprise.

Apprise's /notify field-remap (query-string ":source=target") only supports
one-to-one field renaming, not combining project name + task title + a
constructed task link into one message. This relay does that combination,
then posts a ready-made {title, body} to Apprise so it can stay a dumb sender.
"""
import html
import json
import os
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VIKUNJA_BASE_URL = os.environ["VIKUNJA_BASE_URL"].rstrip("/")
APPRISE_NOTIFY_URL = os.environ["APPRISE_NOTIFY_URL"]

EVENT_TITLES = {
    "task.assignee.created": "📌 Task assigned to you",
    "task.reminder.fired": "⏰ Task due soon",
    "task.overdue": "🔴 Task overdue",
}


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

        link = f"{VIKUNJA_BASE_URL}/tasks/{task_id}"
        body = (
            f"Project: <b>{html.escape(project_title)}</b>\n"
            f'Task: <a href="{html.escape(link)}">{html.escape(task_title)}</a>'
        )

        notify_payload = json.dumps({"title": title, "body": body, "format": "html"}).encode()
        req = urllib.request.Request(
            APPRISE_NOTIFY_URL,
            data=notify_payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                print(f"forwarded {event_name} -> apprise: {resp.status}", flush=True)
        except Exception as exc:
            print(f"error forwarding {event_name} to apprise: {exc}", flush=True)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"listening on :{port}", flush=True)
    server.serve_forever()
