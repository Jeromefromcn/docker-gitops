import os
import stat
import sys
import tempfile
import textwrap
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from threading import Thread

sys.path.insert(0, os.path.dirname(__file__))
import app
import config


def _write_script(path, body):
    with open(path, "w") as f:
        f.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)


class SwitchboardTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.switches_dir = os.path.join(self.tmp.name, "switches")
        os.makedirs(self.switches_dir)
        self.config_path = os.path.join(self.tmp.name, "switches.ini")

        self.original_config_path = config.CONFIG_PATH
        self.original_switches_dir = config.SWITCHES_DIR
        config.CONFIG_PATH = self.config_path
        config.SWITCHES_DIR = self.switches_dir
        self.addCleanup(self._restore_config)

    def _restore_config(self):
        config.CONFIG_PATH = self.original_config_path
        config.SWITCHES_DIR = self.original_switches_dir

    def _write_ini(self, content):
        with open(self.config_path, "w") as f:
            f.write(content)

    def _write_switch(self, switch_id, status_exit, on_body="exit 0\n", off_body="exit 0\n"):
        d = os.path.join(self.switches_dir, switch_id)
        os.makedirs(d)
        _write_script(os.path.join(d, "status.sh"), f"#!/bin/sh\nexit {status_exit}\n")
        _write_script(os.path.join(d, "on.sh"), f"#!/bin/sh\n{on_body}")
        _write_script(os.path.join(d, "off.sh"), f"#!/bin/sh\n{off_body}")

    def start_server(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
        Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        return server.server_port


class TestDoGet(SwitchboardTestCase):
    def test_renders_switch_state_and_labels(self):
        self._write_ini(textwrap.dedent("""\
            [demo]
            group = Test
            label = Demo
            on_label = Enabled
            off_label = Disabled
            """))
        self._write_switch("demo", status_exit="0")
        port = self.start_server()
        body = urllib.request.urlopen(f"http://127.0.0.1:{port}/").read().decode()
        self.assertIn("Demo", body)
        self.assertIn("Enabled", body)
        self.assertIn("Switch to Disabled", body)

    def test_error_state_hides_toggle_button(self):
        self._write_ini("[demo]\nlabel = Demo\n")
        os.makedirs(os.path.join(self.switches_dir, "demo"))  # no status.sh
        port = self.start_server()
        body = urllib.request.urlopen(f"http://127.0.0.1:{port}/").read().decode()
        self.assertIn("ERROR", body)
        self.assertNotIn("<form", body)

    def test_unknown_path_is_404(self):
        self._write_ini("")
        port = self.start_server()
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/nope")
        self.assertEqual(ctx.exception.code, 404)


class TestDoPost(SwitchboardTestCase):
    def test_toggle_runs_on_script_and_redirects(self):
        self._write_ini("[demo]\nlabel = Demo\n")
        marker = os.path.join(self.tmp.name, "marker")
        self._write_switch("demo", status_exit="1", on_body=f"echo on > {marker}\nexit 0\n")
        port = self.start_server()
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/toggle", data=b"id=demo", method="POST",
        )
        resp = urllib.request.urlopen(req)  # urllib follows the 303 redirect
        self.assertEqual(resp.status, 200)
        self.assertEqual(open(marker).read().strip(), "on")

    def test_unknown_switch_id_is_rejected(self):
        self._write_ini("[demo]\nlabel = Demo\n")
        self._write_switch("demo", status_exit="1")
        port = self.start_server()
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/toggle", data=b"id=not-a-real-switch", method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req)
        self.assertEqual(ctx.exception.code, 400)

    def test_action_failure_renders_error_page(self):
        self._write_ini("[demo]\nlabel = Demo\n")
        self._write_switch("demo", status_exit="1", on_body="echo boom >&2\nexit 1\n")
        port = self.start_server()
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/toggle", data=b"id=demo", method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req)
        self.assertEqual(ctx.exception.code, 500)
        self.assertIn(b"boom", ctx.exception.read())


if __name__ == "__main__":
    unittest.main()
