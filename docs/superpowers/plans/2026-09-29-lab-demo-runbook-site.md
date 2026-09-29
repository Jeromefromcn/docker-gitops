# Lab Demo Runbook Site Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish `docs/demo/` as a static site on GitHub Pages, with each scenario's rehearsal evidence embedded as a collapsed block and navigation in README's demo order.

**Architecture:** A stdlib-only `demo-site/prepare.py` copies `docs/demo/` into `demo-site/build/docs/`, appends each scenario's `evidence/<slug>.txt` as a collapsed admonition, and writes `demo-site/build/mkdocs.yml` (a hand-written base plus a nav generated from README's Order table). MkDocs + Material builds it with `--strict`; `check_site.py` verifies the *output* (evidence blocks, `noindex`, prev/next order); a GitHub Actions workflow runs all of it and deploys to Pages on pushes to `main`.

**Tech Stack:** Python 3.12 stdlib (`unittest`, `re`, `shutil`, `pathlib`), MkDocs 1.6.1, Material for MkDocs 9.7.7, pymdown-extensions 12.1, GitHub Actions (`actions/upload-pages-artifact@v5.0.0`, `actions/deploy-pages@v5.0.1`).

**Spec:** [`docs/superpowers/specs/2026-09-29-lab-demo-runbook-site-design.md`](../specs/2026-09-29-lab-demo-runbook-site-design.md)

## Global Constraints

- `docs/demo/*.md` are **not edited** to suit the site, apart from one link line near the top of `docs/demo/README.md` (Task 4).
- `prepare.py` and `check_site.py` use the Python standard library only.
- Versions pinned exactly: `mkdocs==1.6.1`, `mkdocs-material==9.7.7`, `pymdown-extensions==12.1`, `Markdown==3.11`. **Never `mkdocs>=2`**: Material's own build banner warns MkDocs 2.0 removes the plugin system and breaks theme overrides.
- Site URL: `https://jeromefromcn.github.io/docker-gitops/`. No custom domain.
- Every page carries `<meta name="robots" content="noindex, nofollow">`.
- Nav source of truth: README's Order table rows of the form `| NN | [title](NN-slug.md) | why |`. Nav titles are `NN — title`.
- Scenario page = any `NN-slug.md` with `NN != "00"`; its evidence is `evidence/<slug>.txt`. `00-preflight.md` has none.
- Evidence block: `??? note "Rehearsal evidence — window <window text from the file's first line>"`, collapsed, file content verbatim in a `text` fence.
- Build with `mkdocs build --strict`.
- Commit messages: English, imperative, end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Commits go to `main` (lab roadmap convention). Check `git status`/`git log` before each commit — other sessions commit to this checkout.
- Enabling Pages (`gh api -X POST .../pages`) and every `git push` are outward-facing: ask the owner first.

## Review Focus

1. **Evidence containing backticks** (a ```` ``` ```` line or inline backticks in a future evidence format) must stay inside its block and not end the fence early — Task 1 test `test_evidence_with_backtick_fence_stays_fenced`.
2. **An Order-table row whose number disagrees with the file it links** (`| 10 | [..](11-header-canary.md) |`) would give a nav titled with the wrong number — refused, Task 1 test `test_refuses_row_number_mismatch`.
3. **Re-running prepare after a page was deleted or renamed** must not leave the old page in the build (MkDocs would publish it) — Task 1 test `test_rerun_drops_stale_pages`.
4. **Titles with YAML-significant characters** (the real README has `Canary by weight: catch a bad build`; a future title may contain `"`) must produce a valid `mkdocs.yml` — Task 1 test `test_nav_title_with_colon_and_quote` plus the real-docs test.
5. **An evidence file with no `window …` on its first line, or empty** (hand-edited, or a changed `demo-evidence` format) must fail with the file named, not publish a block with a blank title — Task 1 test `test_refuses_evidence_without_window`.

---

## File Structure

| File | Responsibility |
|---|---|
| `demo-site/prepare.py` | `docs/demo/` → `build/docs/` + `build/mkdocs.yml`; all refusal rules |
| `demo-site/check_site.py` | Verifies a built site: evidence blocks, `noindex`, prev/next chain equals README order |
| `demo-site/mkdocs.base.yml` | Theme, features, extensions — everything except `docs_dir` and `nav` |
| `demo-site/overrides/main.html` | Adds the `noindex` meta to every page |
| `demo-site/requirements.txt` | Pinned build dependencies |
| `demo-site/tests/test_prepare.py` | Unit tests for `prepare.py`, incl. one against the real `docs/demo/` |
| `demo-site/tests/test_check_site.py` | Unit tests for `check_site.py` on small HTML fixtures |
| `demo-site/README.md` | Purpose, URL, local build, refusal rules, generator note |
| `.github/workflows/demo-runbook.yml` | test → prepare → build → check → deploy |
| `.gitignore` | `demo-site/build/` |

---

### Task 1: `prepare.py` with its refusal rules

**Files:**
- Create: `demo-site/prepare.py`
- Test: `demo-site/tests/test_prepare.py`

**Interfaces:**
- Produces:
  - `class PrepareError(Exception)` — message names the offending file(s), one problem per line.
  - `parse_order(readme: str) -> list[tuple[str, str, str]]` — `(num, title, filename)` in table order; raises `PrepareError`.
  - `evidence_block(evidence: str, name: str) -> str` — markdown to append; raises `PrepareError`.
  - `prepare(src: Path, out: Path, base: Path) -> list[str]` — writes `out/docs/` and `out/mkdocs.yml`, returns the nav filenames in order; raises `PrepareError`.
  - `EXEMPT = {"00"}` — page numbers that need no evidence.
  - CLI: `python3 demo-site/prepare.py [--src DIR] [--out DIR] [--base FILE]`, defaults `docs/demo`, `demo-site/build`, `demo-site/mkdocs.base.yml` (resolved from the script's location); exit 1 with `prepare.py: <message>` on stderr on refusal.

- [ ] **Step 1: Write the failing tests**

`demo-site/tests/test_prepare.py`:

```python
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from prepare import PrepareError, evidence_block, parse_order, prepare  # noqa: E402

REPO_DEMO = HERE.parent.parent / "docs" / "demo"
BASE = "site_name: Test\n"


def window(slug):
    return f"== {slug}  window 2026-09-29T03:52:24Z → 2026-09-29T03:53:03Z (39s)\n  [envoy] PASS  x\n== OK\n"


class Fixture:
    """A throwaway docs/demo/ lookalike: pages, an Order table, evidence."""

    def __init__(self, rows, pages=None, evidence=None):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.src, self.out, self.base = root / "demo", root / "build", root / "base.yml"
        (self.src / "evidence").mkdir(parents=True)
        self.base.write_text(BASE)
        table = "".join(f"| {n} | [{t}]({f}) | |\n" for n, t, f in rows)
        (self.src / "README.md").write_text(f"# Runbook\n\n## Order\n\n| # | Scenario | Why |\n|---|---|---|\n{table}")
        for f in pages if pages is not None else [f for _, _, f in rows]:
            (self.src / f).write_text(f"# {f}\n\nbody\n")
        if evidence is None:
            evidence = {f[3:-3]: window(f[3:-3]) for _, _, f in rows if not f.startswith("00-")}
        for slug, text in evidence.items():
            (self.src / "evidence" / f"{slug}.txt").write_text(text)

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

    def test_evidence_appended_with_window_title(self):
        fx = self.fixture(ROWS)
        fx.run()
        page = (fx.out / "docs" / "07-gitops.md").read_text()
        self.assertTrue(page.startswith("# 07-gitops.md\n\nbody\n"))
        self.assertIn('??? note "Rehearsal evidence — window 2026-09-29T03:52:24Z → 2026-09-29T03:53:03Z (39s)"', page)
        self.assertIn("\n      [envoy] PASS  x\n", page)  # 4 for the block + its own 2

    def test_preflight_gets_no_evidence(self):
        fx = self.fixture(ROWS)
        fx.run()
        self.assertNotIn("Rehearsal evidence", (fx.out / "docs" / "00-preflight.md").read_text())

    def test_refuses_row_without_page(self):
        fx = self.fixture(ROWS, pages=["00-preflight.md", "07-gitops.md"], evidence={"gitops": window("gitops")})
        with self.assertRaisesRegex(PrepareError, "02-rolling.md"):
            fx.run()

    def test_refuses_page_not_in_table(self):
        fx = self.fixture(ROWS[:2], pages=[f for _, _, f in ROWS], evidence={"gitops": window("gitops"), "rolling": window("rolling")})
        with self.assertRaisesRegex(PrepareError, "02-rolling.md is not in README's Order table"):
            fx.run()

    def test_refuses_orphan_evidence(self):
        ev = {"gitops": window("gitops"), "rolling": window("rolling"), "gone": window("gone")}
        fx = self.fixture(ROWS, evidence=ev)
        with self.assertRaisesRegex(PrepareError, "evidence/gone.txt"):
            fx.run()

    def test_refuses_scenario_page_without_evidence(self):
        fx = self.fixture(ROWS, evidence={"gitops": window("gitops")})
        with self.assertRaisesRegex(PrepareError, "02-rolling.md has no evidence/rolling.txt"):
            fx.run()

    def test_refuses_row_number_mismatch(self):
        rows = [("00", "Preflight", "00-preflight.md"), ("03", "GitOps", "07-gitops.md")]
        fx = self.fixture(rows)
        with self.assertRaisesRegex(PrepareError, "07-gitops.md"):
            fx.run()

    def test_refuses_evidence_without_window(self):
        fx = self.fixture(ROWS, evidence={"gitops": "no header here\n", "rolling": window("rolling")})
        with self.assertRaisesRegex(PrepareError, "evidence/gitops.txt"):
            fx.run()

    def test_refuses_empty_evidence(self):
        fx = self.fixture(ROWS, evidence={"gitops": "", "rolling": window("rolling")})
        with self.assertRaisesRegex(PrepareError, "evidence/gitops.txt"):
            fx.run()

    def test_evidence_with_backtick_fence_stays_fenced(self):
        text = window("gitops") + "```\nstill evidence\n````\n"
        block = evidence_block(text, "gitops.txt")
        lines = [l.strip() for l in block.strip("\n").split("\n")]
        # lines[0] is the ??? line, lines[1] blank; the evidence holds a
        # 4-backtick line, so the fence must be 5 long to contain it.
        self.assertEqual(lines[2], "`````text")
        self.assertEqual(lines[-1], "`````")

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

    def test_evidence_directory_not_copied(self):
        fx = self.fixture(ROWS)
        fx.run()
        self.assertFalse((fx.out / "docs" / "evidence").exists())

    def test_source_left_unmodified(self):
        fx = self.fixture(ROWS)
        before = {p: p.read_bytes() for p in fx.src.rglob("*") if p.is_file()}
        fx.run()
        after = {p: p.read_bytes() for p in fx.src.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s demo-site/tests -v`
Expected: ERROR — `ModuleNotFoundError: No module named 'prepare'`.

- [ ] **Step 3: Write the implementation**

`demo-site/prepare.py`:

```python
#!/usr/bin/env python3
"""Turn docs/demo/ into a site build directory without touching the source.

Writes <out>/docs/ -- a copy of every page, each scenario page with its
rehearsal evidence appended as a collapsed block -- and <out>/mkdocs.yml,
the hand-written base plus a nav in README's demo order. Standard library
only. Nothing here is MkDocs-specific except the `???` admonition syntax and
the nav format, so moving to another generator (Zensical) changes only
those two.
"""
import argparse
import json
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

# | 07 | [GitOps self-heal and rollback](07-gitops-selfheal-rollback.md) | why |
ORDER_ROW = re.compile(r"^\|\s*(\d{2})\s*\|\s*\[([^\]]+)\]\(((\d{2})-[a-z0-9-]+\.md)\)\s*\|")
PAGE_NAME = re.compile(r"^(\d{2})-([a-z0-9-]+)\.md$")
# == bad-pod  window 2026-09-29T03:52:24Z → 2026-09-29T03:53:03Z (39s)
WINDOW = re.compile(r"\bwindow\s+(.+?)\s*$")
EXEMPT = {"00"}  # preflight runs no scenario, so it has no evidence


class PrepareError(Exception):
    pass


def parse_order(readme: str) -> list[tuple[str, str, str]]:
    rows, seen = [], set()
    for line in readme.splitlines():
        m = ORDER_ROW.match(line)
        if not m:
            continue
        num, title, filename, file_num = m.groups()
        if num != file_num:
            raise PrepareError(f"README Order row {num} links {filename}: the numbers disagree")
        if filename in seen:
            raise PrepareError(f"README Order table lists {filename} twice")
        seen.add(filename)
        rows.append((num, title, filename))
    if not rows:
        raise PrepareError("README.md has no Order table rows")
    return rows


def evidence_block(evidence: str, name: str) -> str:
    lines = evidence.replace("\r\n", "\n").rstrip("\n").split("\n")
    if lines == [""]:
        raise PrepareError(f"evidence/{name} is empty")
    m = WINDOW.search(lines[0])
    if not m:
        raise PrepareError(f"evidence/{name}: first line has no 'window ...': {lines[0]!r}")
    title = f"Rehearsal evidence — window {m.group(1)}".replace('"', "'")
    # A fence longer than any backtick run inside, so the evidence cannot close it.
    longest = max((len(r) for r in re.findall(r"`+", evidence)), default=0)
    fence = "`" * max(3, longest + 1)
    body = [f"{fence}text", *lines, fence]
    indented = "\n".join(f"    {line}" if line else "" for line in body)
    return f'\n??? note "{title}"\n\n{indented}\n'


def prepare(src: Path, out: Path, base: Path) -> list[str]:
    order = parse_order((src / "README.md").read_text())
    base_text = base.read_text()
    errors = []
    for key in ("nav", "docs_dir"):
        if re.search(rf"^{key}\s*:", base_text, re.M):
            errors.append(f"{base.name} must not set {key}: prepare.py generates it")

    pages = {}
    for path in sorted(src.glob("[0-9][0-9]-*.md")):
        m = PAGE_NAME.match(path.name)
        if not m:
            errors.append(f"{path.name}: page names must be NN-lowercase-slug.md")
            continue
        pages[path.name] = (m.group(1), m.group(2))

    listed = [f for _, _, f in order]
    errors += [f"README Order table links {f}, which does not exist" for f in listed if f not in pages]
    errors += [f"{f} is not in README's Order table" for f in pages if f not in listed]

    slugs = {}
    for name, (_, slug) in pages.items():
        if slug in slugs:
            errors.append(f"{slugs[slug]} and {name} share the slug {slug!r}: evidence would be ambiguous")
        slugs[slug] = name
    evidence_dir = src / "evidence"
    evidence = {p.stem: p for p in evidence_dir.glob("*.txt")} if evidence_dir.is_dir() else {}
    errors += [f"evidence/{s}.txt has no page NN-{s}.md" for s in sorted(evidence) if s not in slugs]
    errors += [
        f"{name} has no evidence/{slug}.txt"
        for name, (num, slug) in pages.items()
        if num not in EXEMPT and slug not in evidence
    ]

    blocks = {}
    for name, (num, slug) in pages.items():
        if slug in evidence and num not in EXEMPT:
            try:
                blocks[name] = evidence_block(evidence[slug].read_text(), f"{slug}.txt")
            except PrepareError as e:
                errors.append(str(e))
    if errors:
        raise PrepareError("\n".join(errors))

    docs = out / "docs"
    if docs.exists():
        shutil.rmtree(docs)
    shutil.copytree(src, docs, ignore=shutil.ignore_patterns("evidence"))
    for name, block in blocks.items():
        page = docs / name
        page.write_text(page.read_text().rstrip("\n") + "\n" + block)

    nav = "".join(
        f"  - {json.dumps(f'{num} — {title}', ensure_ascii=False)}: {filename}\n"
        for num, title, filename in order
    )
    (out / "mkdocs.yml").write_text(
        base_text.rstrip("\n")
        + "\n\n# Generated by prepare.py from README's Order table -- do not edit.\n"
        + "docs_dir: docs\nnav:\n  - Overview: README.md\n"
        + nav
    )
    return listed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--src", type=Path, default=HERE.parent / "docs" / "demo")
    ap.add_argument("--out", type=Path, default=HERE / "build")
    ap.add_argument("--base", type=Path, default=HERE / "mkdocs.base.yml")
    args = ap.parse_args()
    try:
        nav = prepare(args.src, args.out, args.base)
    except PrepareError as e:
        print(f"prepare.py: {e}", file=sys.stderr)
        return 1
    print(f"prepare.py: {len(nav)} pages -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s demo-site/tests -v`
Expected: all tests `ok`, including `test_real_docs_demo_prepares`.

- [ ] **Step 5: Run it on the real runbook and eyeball one page**

```bash
python3 demo-site/prepare.py
tail -12 demo-site/build/docs/14-bad-pod.md
sed -n '/^# Generated/,$p' demo-site/build/mkdocs.yml | head -8
git status --short docs/demo   # expect nothing: the source is untouched
```
Expected: `prepare.py: 19 pages -> .../demo-site/build`; the bad-pod page ends with the `??? note "Rehearsal evidence — window 2026-09-29T03:52:24Z → ..."` block; nav starts `Overview`, `00 — Preflight`, `01 — ...`, `02 — ...`, `03 — ...`, `07 — ...`.

- [ ] **Step 6: Ignore the build directory and commit**

Append to `.gitignore`:

```gitignore

# demo runbook site build output (demo-site/prepare.py + mkdocs)
demo-site/build/
```

```bash
git status --short && git log --oneline -3
git add .gitignore demo-site/prepare.py demo-site/tests/test_prepare.py
git commit -m "demo-site: prepare the runbook for a static site build

Copy docs/demo/ into a build directory, append each scenario's rehearsal
evidence as a collapsed block and generate the nav from README's Order
table. Refuse to build on a page, table row or evidence file that has no
counterpart, so the site cannot silently drift from the runbook.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: MkDocs configuration and a strict local build

**Files:**
- Create: `demo-site/mkdocs.base.yml`, `demo-site/overrides/main.html`, `demo-site/requirements.txt`

**Interfaces:**
- Consumes: `prepare.py` CLI (Task 1) — writes `demo-site/build/mkdocs.yml` with `docs_dir: docs` and `nav`.
- Produces: `mkdocs build --strict -f demo-site/build/mkdocs.yml` → `demo-site/build/site/` (MkDocs' default `site_dir` is relative to the config file). Pages at `<slug-with-number>/index.html`, e.g. `14-bad-pod/index.html`; home at `index.html`.

- [ ] **Step 1: Write the pinned requirements**

`demo-site/requirements.txt`:

```text
# Pinned exactly. Never mkdocs>=2: Material's build banner warns that
# MkDocs 2.0 removes the plugin system and breaks theme overrides
# (overrides/main.html). Material itself is in maintenance mode since
# 2025-11; see demo-site/README.md for the way out.
mkdocs==1.6.1
mkdocs-material==9.7.7
pymdown-extensions==12.1
Markdown==3.11
```

- [ ] **Step 2: Write the base config**

`demo-site/mkdocs.base.yml`:

```yaml
# Everything except docs_dir and nav, which prepare.py generates into
# build/mkdocs.yml. Build: python3 demo-site/prepare.py &&
# mkdocs build --strict -f demo-site/build/mkdocs.yml
site_name: Lab demo runbook
site_description: Live SDLC demonstrations on lab-environment, with the evidence behind each one
site_url: https://jeromefromcn.github.io/docker-gitops/
repo_url: https://github.com/Jeromefromcn/docker-gitops
repo_name: docker-gitops

theme:
  name: material
  custom_dir: ../overrides
  features:
    - navigation.footer      # prev/next in demo order
    - content.code.copy      # one-click copy on every command block
    - search.highlight
  palette:
    - media: "(prefers-color-scheme: light)"
      scheme: default
      toggle:
        icon: material/weather-night
        name: Dark mode
    - media: "(prefers-color-scheme: dark)"
      scheme: slate
      toggle:
        icon: material/weather-sunny
        name: Light mode

markdown_extensions:
  - admonition
  - pymdownx.details         # the collapsed rehearsal-evidence block
  - pymdownx.superfences:
      custom_fences:
        - name: mermaid
          class: mermaid
          format: !!python/name:pymdownx.superfences.fence_code_format
  - tables
  - toc:
      permalink: true
```

`custom_dir` is relative to the config file's directory, which is `demo-site/build/` once prepare.py has written it — hence `../overrides`.

- [ ] **Step 3: Write the noindex override**

`demo-site/overrides/main.html`:

```html
{% extends "base.html" %}
{% block extrahead %}
  <meta name="robots" content="noindex, nofollow">
{% endblock %}
```

- [ ] **Step 4: Build strictly**

```bash
python3 -m venv /tmp/demo-site-venv && /tmp/demo-site-venv/bin/pip install -q -r demo-site/requirements.txt
python3 demo-site/prepare.py
/tmp/demo-site-venv/bin/mkdocs build --strict -f demo-site/build/mkdocs.yml; echo rc=$?
```
Expected: `rc=0`; the Material "MkDocs 2.0" banner is printed and is expected. Then:

```bash
grep -c 'name="robots" content="noindex, nofollow"' demo-site/build/site/index.html demo-site/build/site/14-bad-pod/index.html
grep -c '<details class="note">' demo-site/build/site/14-bad-pod/index.html demo-site/build/site/00-preflight/index.html
grep -o 'href="[^"]*" class="md-footer__link md-footer__link--next"' demo-site/build/site/03-schema-migration/index.html
```
Expected: `1` / `1`; `1` for bad-pod and `0` for preflight; 03's next link is `../07-gitops-selfheal-rollback/`.

- [ ] **Step 5: Prove `--strict` catches a broken link (then undo)**

```bash
echo '[x](does-not-exist.md)' >> demo-site/build/docs/01-load-balancing.md
/tmp/demo-site-venv/bin/mkdocs build --strict -f demo-site/build/mkdocs.yml >/dev/null 2>&1; echo rc=$?
python3 demo-site/prepare.py   # regenerates build/docs from the untouched source
```
Expected: `rc=1`.

- [ ] **Step 6: Commit**

```bash
git status --short && git log --oneline -3
git add demo-site/mkdocs.base.yml demo-site/overrides/main.html demo-site/requirements.txt
git commit -m "demo-site: add the MkDocs Material configuration

Pinned MkDocs 1.6.1 and Material 9.7.7, prev/next footer, copy buttons,
the details extension for the evidence block, Mermaid fences and a
noindex meta on every page.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `check_site.py` — verify the built output

**Files:**
- Create: `demo-site/check_site.py`
- Test: `demo-site/tests/test_check_site.py`

**Interfaces:**
- Consumes: `parse_order`, `EXEMPT` from `prepare.py` (Task 1); the site layout from Task 2 (`index.html`, `<NN-slug>/index.html`, Material footer markup `<a href="..." class="md-footer__link md-footer__link--next"`).
- Produces: `check(site: Path, src: Path) -> list[str]` (empty = OK); CLI `python3 demo-site/check_site.py [SITE_DIR] [--src DIR]`, default site `demo-site/build/site`, exit 1 and one line per problem on failure.

- [ ] **Step 1: Write the failing tests**

`demo-site/tests/test_check_site.py`:

```python
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s demo-site/tests -v`
Expected: `test_check_site` errors with `ModuleNotFoundError: No module named 'check_site'`; `test_prepare` still passes.

- [ ] **Step 3: Write the implementation**

`demo-site/check_site.py`:

```python
#!/usr/bin/env python3
"""Check a built runbook site: evidence blocks, noindex, prev/next order.

Checks the generated HTML rather than prepare.py's output, so it also
catches a generator or theme upgrade that silently drops one of them.
"""
import argparse
import posixpath
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from prepare import EXEMPT, parse_order  # noqa: E402

NOINDEX = '<meta name="robots" content="noindex, nofollow">'
EVIDENCE = re.compile(r'<details class="note">\s*<summary>Rehearsal evidence')
NEXT = re.compile(r'<a href="([^"]+)" class="md-footer__link md-footer__link--next"')


def _follow(current: str, href: str) -> str:
    target = posixpath.normpath(posixpath.join(posixpath.dirname(current), href))
    return "index.html" if target in (".", "") else f"{target}/index.html"


def check(site: Path, src: Path) -> list[str]:
    order = parse_order((src / "README.md").read_text())
    errors = []

    for html in sorted(site.rglob("*.html")):
        if NOINDEX not in html.read_text():
            errors.append(f"{html.relative_to(site).as_posix()}: no noindex meta")

    for num, _, filename in order:
        rel = f"{filename[:-3]}/index.html"
        path = site / rel
        if not path.is_file():
            errors.append(f"{rel}: missing")
            continue
        has = bool(EVIDENCE.search(path.read_text()))
        if num in EXEMPT and has:
            errors.append(f"{rel}: has an evidence block but needs none")
        elif num not in EXEMPT and not has:
            errors.append(f"{rel}: no rehearsal evidence block")

    expected = ["index.html"] + [f"{f[:-3]}/index.html" for _, _, f in order]
    chain, current = [], "index.html"
    while current and len(chain) <= len(expected):
        chain.append(current)
        path = site / current
        m = NEXT.search(path.read_text()) if path.is_file() else None
        current = _follow(current, m.group(1)) if m else None
    if chain != expected:
        errors.append(f"prev/next order differs from README's Order table: got {chain}, want {expected}")
    return errors


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("site", type=Path, nargs="?", default=HERE / "build" / "site")
    ap.add_argument("--src", type=Path, default=HERE.parent / "docs" / "demo")
    args = ap.parse_args()
    errors = check(args.site, args.src)
    for e in errors:
        print(f"check_site.py: {e}", file=sys.stderr)
    if not errors:
        print("check_site.py: OK")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s demo-site/tests -v`
Expected: all `ok`.

- [ ] **Step 5: Run the checker against the real build from Task 2**

```bash
python3 demo-site/prepare.py && /tmp/demo-site-venv/bin/mkdocs build --strict -q -f demo-site/build/mkdocs.yml
python3 demo-site/check_site.py; echo rc=$?
```
Expected: `check_site.py: OK`, `rc=0`. If the real Material markup differs from the fixtures (e.g. `<details class="note">` followed by something other than `<summary>`), fix the regex *and* the fixture together, then re-run both.

- [ ] **Step 6: Commit**

```bash
git status --short && git log --oneline -3
git add demo-site/check_site.py demo-site/tests/test_check_site.py
git commit -m "demo-site: check the built site's evidence, noindex and page order

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Workflow and documentation

**Files:**
- Create: `.github/workflows/demo-runbook.yml`, `demo-site/README.md`
- Modify: `docs/demo/README.md` (one line after the title), `README.md` (directory tree)

**Interfaces:**
- Consumes: `demo-site/requirements.txt`, `prepare.py`, `check_site.py`, the tests (Tasks 1–3).
- Produces: a Pages artifact from `demo-site/build/site`; deploy job only on `push`/`workflow_dispatch`.

- [ ] **Step 1: Write the workflow**

`.github/workflows/demo-runbook.yml`:

```yaml
name: demo-runbook

on:
  push:
    branches: [main]
    paths:
      - 'docs/demo/**'
      - 'demo-site/**'
      - '.github/workflows/demo-runbook.yml'
  pull_request:
    paths:
      - 'docs/demo/**'
      - 'demo-site/**'
      - '.github/workflows/demo-runbook.yml'
  workflow_dispatch: {}

permissions:
  contents: read

# Renders docs/demo/ as a static site on GitHub Pages (demo-site/README.md).
# Pull requests build and check only; pushes to main also deploy.
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v7.0.1

      - name: Set up Python
        uses: actions/setup-python@v7.0.0
        with:
          python-version: '3.12'
          cache: pip
          cache-dependency-path: demo-site/requirements.txt

      - name: Install MkDocs
        run: pip install -r demo-site/requirements.txt

      - name: Unit tests
        run: python -m unittest discover -s demo-site/tests -v

      - name: Prepare
        run: python demo-site/prepare.py

      - name: Build (strict)
        run: mkdocs build --strict -f demo-site/build/mkdocs.yml

      - name: Check the built site
        run: python demo-site/check_site.py demo-site/build/site

      - name: Upload Pages artifact
        uses: actions/upload-pages-artifact@v5.0.0
        with:
          path: demo-site/build/site

  deploy:
    if: github.event_name != 'pull_request'
    needs: build
    runs-on: ubuntu-latest
    permissions:
      pages: write
      id-token: write
    # Two quick pushes publish in order rather than racing.
    concurrency:
      group: pages
      cancel-in-progress: false
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v5.0.1
```

- [ ] **Step 2: Validate the workflow YAML**

```bash
python3 -c "import yaml,sys; d=yaml.safe_load(open('.github/workflows/demo-runbook.yml')); print(list(d['jobs']))"
```
Expected: `['build', 'deploy']`.

- [ ] **Step 3: Write `demo-site/README.md`**

````markdown
# demo-site — the lab demo runbook as a web page

Renders [`docs/demo/`](../docs/demo/README.md) as a static site on GitHub Pages:
**https://jeromefromcn.github.io/docker-gitops/**

The markdown in `docs/demo/` stays the only source and is never edited for the
site's sake. On every push to `main` touching `docs/demo/**` or `demo-site/**`,
[`.github/workflows/demo-runbook.yml`](../.github/workflows/demo-runbook.yml)
runs the tests, `prepare.py`, `mkdocs build --strict`, `check_site.py`, and
deploys. Pull requests build and check but do not deploy.

Hosted on GitHub rather than on vps_oracle on purpose: the page is the fallback
when the lab misbehaves, so it must not share a failure domain with it. Pages
carry `noindex`.

## What the build adds

- **Nav in demo order** — generated from README's *Order* table, not from file
  numbers (07 runs right after 03).
- **Rehearsal evidence** — each scenario page gets `evidence/<slug>.txt`
  appended as a collapsed block titled with its window. Open it only when the
  live run fails.

## The build refuses when

- an Order-table row links a page that does not exist, or its number disagrees with the file;
- a page `NN-*.md` is missing from the Order table;
- a scenario page (any but `00`) has no `evidence/<slug>.txt`, or an evidence file has no page;
- an evidence file is empty or its first line has no `window …`;
- a relative link is broken (`mkdocs build --strict`).

## Build locally

```bash
python3 -m venv /tmp/demo-site-venv && /tmp/demo-site-venv/bin/pip install -r demo-site/requirements.txt
python3 -m unittest discover -s demo-site/tests
python3 demo-site/prepare.py
/tmp/demo-site-venv/bin/mkdocs serve -f demo-site/build/mkdocs.yml   # or: build --strict
python3 demo-site/check_site.py                                        # after a build
```

`demo-site/build/` is gitignored. Re-run `prepare.py` after editing `docs/demo/`:
`mkdocs serve` watches the build copy, not the source.

## Generator

MkDocs 1.6.1 + Material 9.7.7, pinned exactly. Material has been in maintenance
mode since 2025-11 (critical fixes for at least 12 months); its successor is
Zensical. MkDocs 2.0 drops plugins and theme overrides, so never unpin to
`mkdocs>=2`. `prepare.py` is deliberately generator-independent: a move to
Zensical changes the base config and the build command, nothing else.
````

- [ ] **Step 4: Link the site from the runbook and the root README**

In `docs/demo/README.md`, insert after the `# Lab demo runbook` line and its blank line:

```markdown
Rendered at **https://jeromefromcn.github.io/docker-gitops/** (built from this
directory by [`demo-site/`](https://github.com/Jeromefromcn/docker-gitops/tree/main/demo-site)).

```

In the root `README.md` directory tree, add after the `├── tailscale/` line:

```
├── demo-site/                     # docs/demo/ rendered as a web page on GitHub Pages (see demo-site/README.md)
```

- [ ] **Step 5: Re-run the whole local pipeline**

```bash
python3 -m unittest discover -s demo-site/tests && python3 demo-site/prepare.py && \
  /tmp/demo-site-venv/bin/mkdocs build --strict -q -f demo-site/build/mkdocs.yml && python3 demo-site/check_site.py
```
Expected: tests OK, `check_site.py: OK`. (The new link in `docs/demo/README.md` is an absolute GitHub URL on purpose: a relative link to `../../demo-site/` would point outside `docs_dir`, which `--strict` rejects.)

- [ ] **Step 6: Commit**

```bash
git status --short && git log --oneline -3
git add .github/workflows/demo-runbook.yml demo-site/README.md docs/demo/README.md README.md
git commit -m "ci: publish the demo runbook to GitHub Pages

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Enable Pages, deploy, verify live, record results

**Files:**
- Modify: `docs/superpowers/specs/2026-09-25-lab-sdlc-demo-roadmap.md` (the "Runbook as a web page" row), `docs/superpowers/specs/2026-09-29-lab-demo-runbook-site-design.md` (append "Implementation results")

- [ ] **Step 1: Ask the owner, then enable Pages with the Actions source**

Outward-facing — confirm first. Then:

```bash
gh api -X POST repos/Jeromefromcn/docker-gitops/pages -f build_type=workflow
gh api repos/Jeromefromcn/docker-gitops/pages --jq '{build_type, html_url}'
```
Expected: `{"build_type":"workflow","html_url":"https://jeromefromcn.github.io/docker-gitops/"}`.

- [ ] **Step 2: Ask the owner, then push**

```bash
git status -sb | head -1 && git log --oneline origin/main..HEAD
git push origin main
gh run list --workflow demo-runbook.yml --limit 1
gh run watch "$(gh run list --workflow demo-runbook.yml --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```
Expected: the run succeeds, both jobs green.

- [ ] **Step 3: Verify the live site**

```bash
U=https://jeromefromcn.github.io/docker-gitops
curl -s -o /dev/null -w '%{http_code}\n' $U/
curl -s $U/14-bad-pod/ | grep -c 'Rehearsal evidence'
curl -s $U/00-preflight/ | grep -c 'Rehearsal evidence'
curl -s $U/ | grep -c 'name="robots" content="noindex, nofollow"'
curl -s $U/03-schema-migration/ | grep -o 'href="[^"]*" class="md-footer__link md-footer__link--next"'
curl -s $U/ | grep -oE 'https?://(10\.0\.0\.95|100\.100\.140\.33)[^"]*' | head   # page-load assets from own hosts
```
Expected: `200`; `1`; `0`; `1`; `../07-gitops-selfheal-rollback/`. The last command may print links that appear in runbook *text* (e.g. `http://10.0.0.95:30097`), but none may be in a `<script src>`, `<link href>` or `<img src>` — check any hit is inside a code block. Then open the site in a browser once: expand an evidence block, click a copy button, toggle dark mode, walk prev/next from 03 to 07.

- [ ] **Step 4: Prove a PR builds without deploying** (acceptance 1)

Check the Actions tab after the next PR touching `docs/demo/**`, or skip with a note in the results if no PR is open — the `if: github.event_name != 'pull_request'` guard is visible in the workflow.

- [ ] **Step 5: Record results**

Roadmap row "Runbook as a web page": status → `**Done <date>** — [spec](2026-09-29-lab-demo-runbook-site-design.md), [plan](../plans/2026-09-29-lab-demo-runbook-site.md), site https://jeromefromcn.github.io/docker-gitops/ (built by demo-site/, deployed by .github/workflows/demo-runbook.yml)`.

Append to the spec an `## Implementation results` section: each acceptance criterion with how it was verified (command and outcome), plus anything that deviated from the design (notably: the post-build check is `check_site.py`, a script with its own tests, instead of inline shell in the workflow, so it runs locally too).

```bash
git status --short && git log --oneline -3
git add docs/superpowers/specs/2026-09-25-lab-sdlc-demo-roadmap.md docs/superpowers/specs/2026-09-29-lab-demo-runbook-site-design.md
git commit -m "docs: record the demo runbook site results

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
Push after asking.
