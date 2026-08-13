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
