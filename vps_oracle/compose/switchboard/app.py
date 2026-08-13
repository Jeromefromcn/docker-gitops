"""Toggle UI for the jerome/bridget Claude provider groups.

Single-file stdlib HTTP server, matching this repo's existing
vikunja-notify-relay pattern. GET / always re-scans; nothing is cached
or remembered between requests, by design (see status.py).
"""
import fcntl
import html
import os
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import status

# CCR_BASE_URL is container-internal (http://ccr:8080) — only used to probe
# CCR's liveness from inside this container. CCR_HOST_BASE_URL is the address
# the HOST-side claude CLI actually uses (via the .env files this UI writes),
# so it — not CCR_BASE_URL — must be what gets written into ANTHROPIC_BASE_URL.
# See the docker-compose.yml comment next to both vars.
CCR_BASE_URL = os.environ["CCR_BASE_URL"]
CCR_HOST_BASE_URL = os.environ["CCR_HOST_BASE_URL"]
CCR_TOKEN = os.environ["CCR_TOKEN"]

# Labels for the two provider states, keyed by "routed". Both the state cell
# and the toggle button's target label are derived from this single mapping
# so they can't drift out of sync with each other.
PROVIDER_LABELS = {True: "CCR", False: "Official"}


def toggle_group(env_path, ccr_base_url, ccr_token):
    lock_path = env_path + ".lock"
    with open(lock_path, "a+") as lock_file:
        # Serializes concurrent /toggle requests for the same group so a
        # read-then-write race can't leave the file in a state neither
        # request intended.
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        current = status.read_config(env_path)
        tmp_path = env_path + ".tmp"
        if current["routed"]:
            content = "# 空 = 走官方订阅 OAuth。provider-switch UI 是唯一应该改写这个文件的东西。\n"
        else:
            content = (
                f"export ANTHROPIC_BASE_URL={ccr_base_url}\n"
                f"export ANTHROPIC_AUTH_TOKEN={ccr_token}\n"
            )
        with open(tmp_path, "w") as f:
            f.write(content)
        os.replace(tmp_path, env_path)


def render_page(scans):
    rows = []
    for s in scans:
        name = html.escape(s["name"])
        state = PROVIDER_LABELS[s["routed"]]
        action_label = PROVIDER_LABELS[not s["routed"]]
        endpoint = html.escape(s["base_url"]) if s["base_url"] else "—"
        health = ("reachable" if s["reachable"] else "UNREACHABLE") if s["routed"] else "—"
        rows.append(f"""
        <tr>
          <td>{name}</td>
          <td>{state}</td>
          <td>{endpoint}</td>
          <td>{health}</td>
          <td><form method="post" action="/toggle"><input type="hidden" name="group" value="{name}">
              <button type="submit">Switch to {action_label}</button></form></td>
        </tr>""")
    return f"""<!doctype html><html><head><title>Claude Provider Switch</title></head>
<body>
<h1>Claude Provider Switch</h1>
<p>State is re-scanned on every page load — nothing here is cached.</p>
<table border="1" cellpadding="6">
<tr><th>Group</th><th>Provider</th><th>Endpoint</th><th>Status</th><th>Action</th></tr>
{''.join(rows)}
</table>
<p>Switching only affects sessions started after the switch.</p>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def do_GET(self):
        if self.path != "/":
            self.send_response(404)
            self.end_headers()
            return
        # Probe CCR once per request, not once per routed group — every group
        # currently routed through CCR shares the same gateway, so the result
        # is identical for all of them.
        ccr_reachable = status.check_connectivity(CCR_BASE_URL)
        scans = [
            status.scan_group(name, cfg["env_path"], ccr_reachable)
            for name, cfg in status.GROUPS.items()
        ]
        body = render_page(scans).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
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
        raw = self.rfile.read(length) if length else b""
        fields = urllib.parse.parse_qs(raw.decode())
        group = (fields.get("group") or [""])[0]
        if group not in status.GROUPS:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"unknown group")
            return
        toggle_group(status.GROUPS[group]["env_path"], CCR_HOST_BASE_URL, CCR_TOKEN)
        self.send_response(303)
        self.send_header("Location", "/")
        self.end_headers()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    # Runs on the proxy bridge network (see docker-compose.yml), alongside
    # CCR (reached as http://ccr:8080) and behind NPM (which reaches this as
    # provider-switch:8091). BIND_HOST defaults to 127.0.0.1 for ad-hoc local
    # runs; the compose stack sets it to 0.0.0.0 — safe because the container
    # is on the proxy bridge only (port not published to the host), so only
    # proxy-network peers + the host itself can connect, and NPM's access list
    # gates who reaches it from outside.
    bind_host = os.environ.get("BIND_HOST", "127.0.0.1")
    server = ThreadingHTTPServer((bind_host, port), Handler)
    print(f"listening on {bind_host}:{port}", flush=True)
    server.serve_forever()
