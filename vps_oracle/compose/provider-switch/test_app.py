import os
import sys
import unittest

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


if __name__ == "__main__":
    unittest.main()
