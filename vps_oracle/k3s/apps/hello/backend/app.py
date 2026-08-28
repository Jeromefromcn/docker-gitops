#!/usr/bin/env python3
"""hello-backend — lightweight HTTP service for pr-lanes resilience testing.

Serves the static index.html content plus a few deliberately faulty endpoints
so that timeout / retry / circuit-breaker / fault-injection behaviour can be
exercised against a real upstream (see docs/misc/2026-08-28-hello-backend-rpc-spec.md).

Endpoints:
  GET /            -> index.html content, re-read from disk on every request
                     (keeps the canary ConfigMap mechanism working)
  GET /slow        -> 200 after SLOW_DELAY_SECONDS (default 15s)
  GET /fail-503    -> 503 immediately
  GET /fail-500    -> 500 immediately
  GET /healthz     -> 200 (probe endpoint)

Environment:
  INDEX_HTML_PATH   path to the HTML to serve on /  (default /usr/share/nginx/html/index.html)
  SLOW_DELAY_SECONDS seconds to sleep for /slow        (default 15)
  PORT               listen port                       (default 8080)

Runs as an unprivileged user on port 8080 (runAsNonRoot: true).
Stdlib only — no external dependencies.
"""

import http.server
import os
import time

INDEX_HTML_PATH = os.environ.get("INDEX_HTML_PATH", "/usr/share/nginx/html/index.html")
SLOW_DELAY_SECONDS = int(os.environ.get("SLOW_DELAY_SECONDS", "15"))
PORT = int(os.environ.get("PORT", "8080"))


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # Requests are already logged by the waypoint/proxy layer; keep pod logs
        # minimal to stay within the container's small memory/cpu limits.
        return

    def _send(self, status, body=b"", content_type="text/plain; charset=utf-8"):
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            # Client went away mid-response (e.g. Istio timeout cut the stream).
            pass

    def do_GET(self):
        if self.path == "/":
            self._serve_index()
        elif self.path == "/slow":
            self._serve_slow()
        elif self.path == "/fail-503":
            self._send(503, b"service unavailable (intentional)")
        elif self.path == "/fail-500":
            self._send(500, b"internal error (intentional)")
        elif self.path == "/healthz":
            self._send(200, b"ok")
        else:
            self._send(404, b"not found")

    def _serve_index(self):
        try:
            with open(INDEX_HTML_PATH, "rb") as f:
                body = f.read()
        except OSError:
            self._send(500, b"index.html missing")
            return
        self._send(200, body, "text/html; charset=utf-8")

    def _serve_slow(self):
        # ThreadingHTTPServer gives each request its own thread, so a plain
        # sleep only blocks this request's thread — concurrent requests keep
        # being served.
        time.sleep(SLOW_DELAY_SECONDS)
        self._send(200, b"done after %ds" % SLOW_DELAY_SECONDS)


def main():
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
