"""Toggle UI for the jerome/bridget Claude provider groups.

Single-file stdlib HTTP server, matching this repo's existing
vikunja-notify-relay pattern. GET / always re-scans; nothing is cached
or remembered between requests, by design (see status.py).
"""
import os
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import status

CCR_BASE_URL = os.environ["CCR_BASE_URL"]
CCR_TOKEN = os.environ["CCR_TOKEN"]


def toggle_group(env_path, ccr_base_url, ccr_token):
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
        state = "CCR (Zhipu)" if s["routed"] else "Official"
        health = "reachable" if s["reachable"] else "UNREACHABLE"
        pending = s["pending_official_sessions"]
        pending_note = f"{pending} session(s) still running with the old provider" if pending else "no running sessions"
        rows.append(f"""
        <tr>
          <td>{s['name']}</td>
          <td>{state}</td>
          <td>{health}</td>
          <td>{pending_note}</td>
          <td><form method="post" action="/toggle"><input type="hidden" name="group" value="{s['name']}">
              <button type="submit">Switch to {"Official" if s["routed"] else "CCR (Zhipu)"}</button></form></td>
        </tr>""")
    return f"""<!doctype html><html><head><title>Claude Provider Switch</title></head>
<body>
<h1>Claude Provider Switch</h1>
<p>State is re-scanned on every page load — nothing here is cached.</p>
<table border="1" cellpadding="6">
<tr><th>Group</th><th>Provider</th><th>Endpoint</th><th>Pending sessions</th><th>Action</th></tr>
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
        scans = [
            status.scan_group(name, cfg["env_path"], cfg["group_dir"])
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
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        fields = urllib.parse.parse_qs(raw.decode())
        group = (fields.get("group") or [""])[0]
        if group not in status.GROUPS:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"unknown group")
            return
        toggle_group(status.GROUPS[group]["env_path"], CCR_BASE_URL, CCR_TOKEN)
        self.send_response(303)
        self.send_header("Location", "/")
        self.end_headers()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"listening on :{port}", flush=True)
    server.serve_forever()
