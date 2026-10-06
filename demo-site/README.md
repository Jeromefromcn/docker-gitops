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

## The build refuses when

- an Order-table row links a page that does not exist, or its number disagrees with the file;
- a page `NN-*.md` is missing from the Order table, or a markdown file is not named `NN-slug.md`;
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
