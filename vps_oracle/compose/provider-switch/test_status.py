import os
import subprocess
import sys
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread

sys.path.insert(0, os.path.dirname(__file__))
import status


class TestReadConfig(unittest.TestCase):
    def test_empty_file_is_official(self):
        path = "/tmp/test-empty.env"
        open(path, "w").write("# just a comment\n")
        self.addCleanup(os.remove, path)
        result = status.read_config(path)
        self.assertEqual(result, {"routed": False, "base_url": None})

    def test_missing_file_is_official(self):
        result = status.read_config("/tmp/does-not-exist.env")
        self.assertEqual(result, {"routed": False, "base_url": None})

    def test_export_line_is_routed(self):
        path = "/tmp/test-routed.env"
        open(path, "w").write(
            "export ANTHROPIC_BASE_URL=http://127.0.0.1:3456\n"
            "export ANTHROPIC_AUTH_TOKEN=abc123\n"
        )
        self.addCleanup(os.remove, path)
        result = status.read_config(path)
        self.assertEqual(result, {"routed": True, "base_url": "http://127.0.0.1:3456"})

    def test_bare_assignment_without_export_also_counts(self):
        path = "/tmp/test-bare.env"
        open(path, "w").write("ANTHROPIC_BASE_URL=http://127.0.0.1:3456\n")
        self.addCleanup(os.remove, path)
        result = status.read_config(path)
        self.assertTrue(result["routed"])


class TestConnectivity(unittest.TestCase):
    def test_official_always_reachable(self):
        self.assertTrue(status.check_connectivity(None))

    def test_live_endpoint_is_reachable(self):
        server = HTTPServer(("127.0.0.1", 0), BaseHTTPRequestHandler)
        port = server.server_port
        Thread(target=server.handle_request, daemon=True).start()
        time.sleep(0.1)
        self.assertTrue(status.check_connectivity(f"http://127.0.0.1:{port}"))
        server.server_close()

    def test_dead_endpoint_is_unreachable(self):
        self.assertFalse(status.check_connectivity("http://127.0.0.1:1", timeout=0.5))


class TestPendingSessions(unittest.TestCase):
    def test_counts_zero_when_nothing_running(self):
        count = status.count_pending_sessions("/tmp/definitely-no-claude-here")
        self.assertEqual(count, 0)


class TestScanGroup(unittest.TestCase):
    def test_official_group_shape(self):
        path = "/tmp/test-scan-official.env"
        open(path, "w").write("")
        self.addCleanup(os.remove, path)
        result = status.scan_group("jerome", path, "/tmp/nonexistent-group-dir")
        self.assertEqual(result["name"], "jerome")
        self.assertFalse(result["routed"])
        self.assertIsNone(result["base_url"])
        self.assertTrue(result["reachable"])
        self.assertIsInstance(result["pending_official_sessions"], int)


if __name__ == "__main__":
    unittest.main()
