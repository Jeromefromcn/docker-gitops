#!/usr/bin/env python3
"""Check a built runbook site: every page present, noindex, prev/next order.

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
from prepare import parse_order  # noqa: E402

NOINDEX = '<meta name="robots" content="noindex, nofollow">'
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

    for _, _, filename in order:
        rel = f"{filename[:-3]}/index.html"
        if not (site / rel).is_file():
            errors.append(f"{rel}: missing")

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
