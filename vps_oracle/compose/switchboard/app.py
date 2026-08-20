"""Generic config-driven switch UI. GET / re-scans every switch's status.sh
live; nothing is cached. POST /toggle runs the appropriate on.sh/off.sh for
one switch. POST /refresh re-runs the same status scan without rendering a
page — for an external service to call after it changes something a
status.sh might self-heal against (e.g. ccr's export-model-routing.cjs, after
it rewrites routing.json — see
docs/misc/2026-08-20-ccr-third-party-model-compat-lessons.md). Deliberately
generic: this file has no idea what any given switch's status.sh actually
checks or heals, or who calls /refresh — it just re-runs the same status scan
a page load would trigger. See
docs/superpowers/specs/2026-08-13-switchboard-generic-toggle-design.md.
"""
import html
import os
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import config

STATE_LABEL_KEY = {"on": "on_label", "off": "off_label"}


def render_page(switches, scans):
    rows = []
    for s in switches:
        scan = scans[s["id"]]
        state = scan["state"]
        group = html.escape(s["group"])
        name = html.escape(s["label"])
        detail = html.escape(scan["detail"])
        if state == "error":
            state_cell = "ERROR"
            action_cell = ""
        else:
            state_cell = html.escape(s[STATE_LABEL_KEY[state]])
            other = "off" if state == "on" else "on"
            action_label = html.escape(s[STATE_LABEL_KEY[other]])
            action_cell = (
                f'<form method="post" action="/toggle">'
                f'<input type="hidden" name="id" value="{html.escape(s["id"])}">'
                f'<button type="submit">Switch to {action_label}</button></form>'
            )
        rows.append(f"""
        <tr>
          <td>{group}</td>
          <td>{name}</td>
          <td>{state_cell}</td>
          <td>{detail}</td>
          <td>{action_cell}</td>
        </tr>""")
    return f"""<!doctype html><html><head><title>Switchboard</title></head>
<body>
<h1>Switchboard</h1>
<p>State is re-scanned on every page load — nothing here is cached.</p>
<table border="1" cellpadding="6">
<tr><th>Group</th><th>Name</th><th>State</th><th>Detail</th><th>Action</th></tr>
{''.join(rows)}
</table>
</body></html>"""


def render_error_page(switch_id, stderr):
    return f"""<!doctype html><html><head><title>Switchboard — error</title></head>
<body>
<h1>Toggle failed: {html.escape(switch_id)}</h1>
<pre>{html.escape(stderr)}</pre>
<p><a href="/">Back</a></p>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def do_GET(self):
        if self.path != "/":
            self.send_response(404)
            self.end_headers()
            return
        switches = config.load_switches()
        scans = config.scan_all(switches)
        body = render_page(switches, scans).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path == "/refresh":
            # Fire-and-forget: scanning every switch (each spawning a
            # status.sh subprocess, one of which does a network reachability
            # check) takes over a second end to end. The caller (ccr's
            # export-model-routing.cjs) only wants to kick this off, not
            # block on it — an earlier version awaited scan_all() here and
            # regularly blew past the caller's own short client-side
            # timeout, so the "fire" half looked like it was failing when it
            # was just slow. Respond immediately; run the scan in the
            # background instead.
            def run_scan():
                try:
                    config.scan_all(config.load_switches())
                except Exception as exc:
                    print(f"/refresh background scan failed: {exc}", flush=True)

            threading.Thread(target=run_scan, daemon=True).start()
            self.send_response(202)
            self.end_headers()
            return
        if self.path != "/toggle":
            self.send_response(404)
            self.end_headers()
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"bad Content-Length")
            return
        if length < 0:
            length = 0
        raw = self.rfile.read(length) if length else b""
        fields = urllib.parse.parse_qs(raw.decode("utf-8", "replace"))
        switch_id = (fields.get("id") or [""])[0]
        known_ids = {s["id"] for s in config.load_switches()}
        if switch_id not in known_ids:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"unknown switch")
            return
        ok, stderr = config.toggle(switch_id)
        if not ok:
            body = render_error_page(switch_id, stderr).encode()
            self.send_response(500)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(303)
        self.send_header("Location", "/")
        self.end_headers()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    bind_host = os.environ.get("BIND_HOST", "127.0.0.1")
    server = ThreadingHTTPServer((bind_host, port), Handler)
    print(f"listening on {bind_host}:{port}", flush=True)
    server.serve_forever()
