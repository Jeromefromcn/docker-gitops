import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from prepare import PrepareError, parse_order, prepare  # noqa: E402

REPO_DEMO = HERE.parent.parent / "docs" / "demo"
BASE = "site_name: Test\n"


class Fixture:
    """A throwaway docs/demo/ lookalike: pages and an Order table."""

    def __init__(self, rows, pages=None):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.src, self.out, self.base = root / "demo", root / "build", root / "base.yml"
        self.src.mkdir(parents=True)
        self.base.write_text(BASE)
        table = "".join(f"| {n} | [{t}]({f}) | |\n" for n, t, f in rows)
        (self.src / "README.md").write_text(f"# Runbook\n\n## Order\n\n| # | Scenario | Why |\n|---|---|---|\n{table}")
        for f in pages if pages is not None else [f for _, _, f in rows]:
            (self.src / f).write_text(f"# {f}\n\nbody\n")

    def run(self):
        return prepare(self.src, self.out, self.base)

    def close(self):
        self.tmp.cleanup()


ROWS = [
    ("00", "Preflight", "00-preflight.md"),
    ("07", "GitOps", "07-gitops.md"),
    ("02", "Rolling update", "02-rolling.md"),
]


class PrepareTest(unittest.TestCase):
    def fixture(self, *a, **kw):
        fx = Fixture(*a, **kw)
        self.addCleanup(fx.close)
        return fx

    def test_nav_follows_readme_order_not_file_order(self):
        fx = self.fixture(ROWS)
        self.assertEqual(fx.run(), ["00-preflight.md", "07-gitops.md", "02-rolling.md"])
        config = (fx.out / "mkdocs.yml").read_text()
        self.assertIn("docs_dir: docs\n", config)
        self.assertLess(config.index("07-gitops.md"), config.index("02-rolling.md"))
        self.assertIn('"07 — GitOps": 07-gitops.md', config)
        self.assertTrue(config.startswith(BASE))

    def test_refuses_row_without_page(self):
        fx = self.fixture(ROWS, pages=["00-preflight.md", "07-gitops.md"])
        with self.assertRaisesRegex(PrepareError, "02-rolling.md"):
            fx.run()

    def test_refuses_page_not_in_table(self):
        fx = self.fixture(ROWS[:2], pages=[f for _, _, f in ROWS])
        with self.assertRaisesRegex(PrepareError, "02-rolling.md is not in README's Order table"):
            fx.run()

    def test_refuses_row_number_mismatch(self):
        rows = [("00", "Preflight", "00-preflight.md"), ("03", "GitOps", "07-gitops.md")]
        fx = self.fixture(rows)
        with self.assertRaisesRegex(PrepareError, "07-gitops.md"):
            fx.run()

    def test_nav_title_with_colon_and_quote(self):
        rows = [("00", "Preflight", "00-preflight.md"), ("10", 'Canary: a "bad" build', "10-canary.md")]
        fx = self.fixture(rows)
        fx.run()
        self.assertIn('"10 — Canary: a \\"bad\\" build": 10-canary.md', (fx.out / "mkdocs.yml").read_text())

    def test_rerun_drops_stale_pages(self):
        fx = self.fixture(ROWS)
        fx.run()
        (fx.out / "docs" / "99-stale.md").write_text("old\n")
        fx.run()
        self.assertFalse((fx.out / "docs" / "99-stale.md").exists())

    def test_source_left_unmodified(self):
        fx = self.fixture(ROWS)
        before = {p: p.read_bytes() for p in fx.src.rglob("*") if p.is_file()}
        fx.run()
        after = {p: p.read_bytes() for p in fx.src.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_refuses_markdown_outside_the_page_pattern(self):
        # copytree publishes everything; a stray or misnamed page would go
        # live with no nav entry.
        fx = self.fixture(ROWS)
        (fx.src / "notes.md").write_text("draft\n")
        (fx.src / "7-typo.md").write_text("typo\n")
        with self.assertRaisesRegex(PrepareError, "(?s)7-typo.md.*notes.md"):
            fx.run()

    def test_base_with_nav_is_refused(self):
        fx = self.fixture(ROWS)
        fx.base.write_text(BASE + "nav:\n  - x.md\n")
        with self.assertRaisesRegex(PrepareError, "must not set nav"):
            fx.run()

    def test_parse_order_rejects_duplicate_rows(self):
        readme = "| 01 | [A](01-a.md) | |\n| 01 | [A](01-a.md) | |\n"
        with self.assertRaisesRegex(PrepareError, "01-a.md twice"):
            parse_order(readme)

    def test_real_docs_demo_prepares(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "base.yml"
            base.write_text(BASE)
            nav = prepare(REPO_DEMO, Path(tmp) / "build", base)
        self.assertEqual(nav[0], "00-preflight.md")
        self.assertEqual(len(nav), len(list(REPO_DEMO.glob("[0-9][0-9]-*.md"))))


if __name__ == "__main__":
    unittest.main()
