import os
import sys
import unittest
import urllib.request
from http.server import ThreadingHTTPServer
from threading import Thread

# app.py reads these at import time. CCR_BASE_URL points at a closed local
# port (127.0.0.1:1, same pattern as test_status.py's dead-endpoint test) so
# any connectivity probe against it fails fast via connection-refused rather
# than a DNS lookup or timeout. CCR_HOST_BASE_URL is deliberately a different
# value so TestDoPostWiring can tell the two apart.
os.environ.setdefault("CCR_BASE_URL", "http://127.0.0.1:1")
os.environ.setdefault("CCR_HOST_BASE_URL", "http://127.0.0.1:3456")
os.environ.setdefault("CCR_TOKEN", "test-token")

sys.path.insert(0, os.path.dirname(__file__))
import app


class TestToggle(unittest.TestCase):
    def setUp(self):
        self.path = "/tmp/test-toggle.env"
        open(self.path, "w").write("")
        self.addCleanup(lambda: os.path.exists(self.path) and os.remove(self.path))

    def test_toggle_from_official_writes_ccr_block(self):
        app.toggle_group(self.path, ccr_base_url="http://127.0.0.1:3456", ccr_token="tok-abc")
        content = open(self.path).read()
        self.assertIn("ANTHROPIC_BASE_URL=http://127.0.0.1:3456", content)
        self.assertIn("ANTHROPIC_AUTH_TOKEN=tok-abc", content)

    def test_toggle_from_ccr_clears_file(self):
        open(self.path, "w").write(
            "export ANTHROPIC_BASE_URL=http://127.0.0.1:3456\n"
            "export ANTHROPIC_AUTH_TOKEN=tok-abc\n"
        )
        app.toggle_group(self.path, ccr_base_url="http://127.0.0.1:3456", ccr_token="tok-abc")
        content = open(self.path).read()
        self.assertNotIn("ANTHROPIC_BASE_URL", content)
        self.assertNotIn("ANTHROPIC_AUTH_TOKEN", content)

    def test_toggle_is_atomic_no_tmp_file_left_behind(self):
        app.toggle_group(self.path, ccr_base_url="http://127.0.0.1:3456", ccr_token="tok-abc")
        self.assertFalse(os.path.exists(self.path + ".tmp"))


class TestDoPostWiring(unittest.TestCase):
    """Exercises the real HTTP handler end-to-end, not toggle_group() in
    isolation — this is the level at which the app once passed the
    container-only CCR_BASE_URL into the host-facing .env file instead of
    CCR_HOST_BASE_URL. TestToggle above wouldn't catch that class of bug
    since it calls toggle_group() directly with a hand-picked URL."""

    def setUp(self):
        self.env_path = "/tmp/test-do-post-toggle.env"
        open(self.env_path, "w").write("")
        self.addCleanup(lambda: os.path.exists(self.env_path) and os.remove(self.env_path))
        self.addCleanup(lambda: os.path.exists(self.env_path + ".lock") and os.remove(self.env_path + ".lock"))

        original_groups = app.status.GROUPS
        app.status.GROUPS = {"testgroup": {"env_path": self.env_path}}
        self.addCleanup(lambda: setattr(app.status, "GROUPS", original_groups))

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
        self.port = self.server.server_port
        Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)

    def test_toggle_writes_host_reachable_url_not_container_url(self):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/toggle",
            data=b"group=testgroup",
            method="POST",
        )
        urllib.request.urlopen(req)
        content = open(self.env_path).read()
        self.assertIn(f"ANTHROPIC_BASE_URL={app.CCR_HOST_BASE_URL}", content)
        self.assertNotIn(app.CCR_BASE_URL, content)


if __name__ == "__main__":
    unittest.main()
