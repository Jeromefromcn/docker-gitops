import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from check_site import check  # noqa: E402

NOINDEX = '<meta name="robots" content="noindex, nofollow">'
EVIDENCE = '<details class="note"><summary>Rehearsal evidence — window x</summary></details>'
ORDER = ["00-preflight", "07-gitops", "02-rolling"]


def page(next_href=None, noindex=True, evidence=False):
    parts = ["<html><head>", NOINDEX if noindex else "", "</head><body>"]
    if evidence:
        parts.append(EVIDENCE)
    if next_href:
        parts.append(f'<a href="{next_href}" class="md-footer__link md-footer__link--next" aria-label="Next">')
    return "".join(parts + ["</body></html>"])


class CheckSiteTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        self.site, self.src = root / "site", root / "demo"
        self.src.mkdir()
        rows = "".join(f"| {s[:2]} | [T]({s}.md) | |\n" for s in ORDER)
        (self.src / "README.md").write_text(rows)
        self.write("index.html", page("00-preflight/"))
        self.write("00-preflight/index.html", page("../07-gitops/"))
        self.write("07-gitops/index.html", page("../02-rolling/", evidence=True))
        self.write("02-rolling/index.html", page(None, evidence=True))

    def write(self, rel, html):
        path = self.site / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(html)

    def test_good_site_passes(self):
        self.assertEqual(check(self.site, self.src), [])

    def test_wrong_order_is_reported(self):
        self.write("00-preflight/index.html", page("../02-rolling/"))
        self.assertTrue(any("order" in e for e in check(self.site, self.src)))

    def test_missing_noindex_is_reported(self):
        self.write("07-gitops/index.html", page("../02-rolling/", noindex=False, evidence=True))
        self.assertIn("07-gitops/index.html: no noindex meta", check(self.site, self.src))

    def test_missing_evidence_is_reported(self):
        self.write("02-rolling/index.html", page(None))
        self.assertIn("02-rolling/index.html: no rehearsal evidence block", check(self.site, self.src))

    def test_evidence_on_preflight_is_reported(self):
        self.write("00-preflight/index.html", page("../07-gitops/", evidence=True))
        self.assertIn("00-preflight/index.html: has an evidence block but needs none", check(self.site, self.src))

    def test_next_link_loop_terminates(self):
        self.write("02-rolling/index.html", page("../07-gitops/", evidence=True))
        self.assertTrue(any("order" in e for e in check(self.site, self.src)))


if __name__ == "__main__":
    unittest.main()
