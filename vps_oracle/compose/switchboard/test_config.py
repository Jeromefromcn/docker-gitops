import os
import sys
import tempfile
import textwrap
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import config


class TestLoadSwitches(unittest.TestCase):
    def test_parses_sections_into_switch_dicts(self):
        with tempfile.TemporaryDirectory() as tmp:
            ini_path = os.path.join(tmp, "switches.ini")
            with open(ini_path, "w") as f:
                f.write(textwrap.dedent("""\
                    [demo]
                    group = Test
                    label = Demo
                    on_label = Enabled
                    off_label = Disabled
                    """))
            switches = config.load_switches(ini_path)
            self.assertEqual(switches, [{
                "id": "demo",
                "group": "Test",
                "label": "Demo",
                "on_label": "Enabled",
                "off_label": "Disabled",
            }])

    def test_missing_optional_fields_fall_back_to_defaults(self):
        with tempfile.TemporaryDirectory() as tmp:
            ini_path = os.path.join(tmp, "switches.ini")
            with open(ini_path, "w") as f:
                f.write("[bare]\n")
            switches = config.load_switches(ini_path)
            self.assertEqual(switches, [{
                "id": "bare",
                "group": "",
                "label": "bare",
                "on_label": "On",
                "off_label": "Off",
            }])

    def test_missing_config_file_is_empty_list(self):
        switches = config.load_switches("/tmp/does-not-exist-switches.ini")
        self.assertEqual(switches, [])


import stat


def _write_script(path, body):
    with open(path, "w") as f:
        f.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)


class TestCheckStatus(unittest.TestCase):
    def _switch_dir(self, tmp, switch_id):
        path = os.path.join(tmp, switch_id)
        os.makedirs(path)
        return path

    def test_exit_zero_is_on_with_detail_from_stdout(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = self._switch_dir(tmp, "demo")
            _write_script(os.path.join(d, "status.sh"), "#!/bin/sh\necho hello\nexit 0\n")
            result = config.check_status("demo", switches_dir=tmp)
            self.assertEqual(result, {"state": "on", "detail": "hello"})

    def test_exit_nonzero_is_off_with_no_detail_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = self._switch_dir(tmp, "demo")
            _write_script(os.path.join(d, "status.sh"), "#!/bin/sh\nexit 1\n")
            result = config.check_status("demo", switches_dir=tmp)
            self.assertEqual(result, {"state": "off", "detail": ""})

    def test_timeout_is_error_not_off(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = self._switch_dir(tmp, "demo")
            _write_script(os.path.join(d, "status.sh"), "#!/bin/sh\nsleep 10\n")
            original_timeout = config.STATUS_TIMEOUT
            config.STATUS_TIMEOUT = 0.2
            try:
                result = config.check_status("demo", switches_dir=tmp)
            finally:
                config.STATUS_TIMEOUT = original_timeout
            self.assertEqual(result, {"state": "error", "detail": ""})

    def test_missing_script_is_error_not_off(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._switch_dir(tmp, "demo")
            result = config.check_status("demo", switches_dir=tmp)
            self.assertEqual(result, {"state": "error", "detail": ""})

    def test_exit_two_is_error_not_off(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = self._switch_dir(tmp, "demo")
            _write_script(os.path.join(d, "status.sh"), "#!/bin/sh\nexit 2\n")
            result = config.check_status("demo", switches_dir=tmp)
            self.assertEqual(result, {"state": "error", "detail": ""})


class TestScanAll(unittest.TestCase):
    def test_scans_every_switch_and_keys_by_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            for switch_id, exit_code in [("a", "0"), ("b", "1")]:
                d = os.path.join(tmp, switch_id)
                os.makedirs(d)
                _write_script(os.path.join(d, "status.sh"), f"#!/bin/sh\nexit {exit_code}\n")
            switches = [{"id": "a"}, {"id": "b"}]
            scans = config.scan_all(switches, switches_dir=tmp)
            self.assertEqual(scans["a"]["state"], "on")
            self.assertEqual(scans["b"]["state"], "off")


class TestToggle(unittest.TestCase):
    def _write_switch(self, tmp, switch_id, status_exit, marker_path,
                       on_body=None, off_body=None):
        d = os.path.join(tmp, switch_id)
        os.makedirs(d)
        _write_script(os.path.join(d, "status.sh"), f"#!/bin/sh\nexit {status_exit}\n")
        _write_script(
            os.path.join(d, "on.sh"),
            on_body or f"#!/bin/sh\necho on > {marker_path}\nexit 0\n",
        )
        _write_script(
            os.path.join(d, "off.sh"),
            off_body or f"#!/bin/sh\necho off > {marker_path}\nexit 0\n",
        )
        return d

    def test_currently_off_runs_on_script(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = os.path.join(tmp, "marker")
            self._write_switch(tmp, "demo", status_exit="1", marker_path=marker)
            lock_dir = os.path.join(tmp, "locks")
            ok, stderr = config.toggle("demo", switches_dir=tmp, lock_dir=lock_dir)
            self.assertTrue(ok)
            self.assertEqual(open(marker).read().strip(), "on")

    def test_currently_on_runs_off_script(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = os.path.join(tmp, "marker")
            self._write_switch(tmp, "demo", status_exit="0", marker_path=marker)
            lock_dir = os.path.join(tmp, "locks")
            ok, stderr = config.toggle("demo", switches_dir=tmp, lock_dir=lock_dir)
            self.assertTrue(ok)
            self.assertEqual(open(marker).read().strip(), "off")

    def test_action_failure_returns_stderr(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._write_switch(
                tmp, "demo", status_exit="1", marker_path=os.path.join(tmp, "marker"),
                on_body="#!/bin/sh\necho boom >&2\nexit 1\n",
            )
            lock_dir = os.path.join(tmp, "locks")
            ok, stderr = config.toggle("demo", switches_dir=tmp, lock_dir=lock_dir)
            self.assertFalse(ok)
            self.assertIn("boom", stderr)

    def test_unknown_status_refuses_to_toggle(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = os.path.join(tmp, "demo")
            os.makedirs(d)  # no status.sh at all
            marker = os.path.join(tmp, "marker")
            _write_script(os.path.join(d, "on.sh"), f"#!/bin/sh\necho on > {marker}\nexit 0\n")
            _write_script(os.path.join(d, "off.sh"), f"#!/bin/sh\necho off > {marker}\nexit 0\n")
            lock_dir = os.path.join(tmp, "locks")
            ok, stderr = config.toggle("demo", switches_dir=tmp, lock_dir=lock_dir)
            self.assertFalse(ok)
            # Refusal must happen before any action script runs — the marker
            # file only gets written by on.sh/off.sh, so its absence proves
            # neither ran.
            self.assertFalse(os.path.exists(marker))

    def test_lock_file_created_at_lock_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = os.path.join(tmp, "marker")
            self._write_switch(tmp, "demo", status_exit="1", marker_path=marker)
            lock_dir = os.path.join(tmp, "locks")
            self.assertFalse(os.path.exists(lock_dir))
            ok, stderr = config.toggle("demo", switches_dir=tmp, lock_dir=lock_dir)
            self.assertTrue(ok)
            self.assertTrue(os.path.exists(os.path.join(lock_dir, "demo.lock")))


if __name__ == "__main__":
    unittest.main()
