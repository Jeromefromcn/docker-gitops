# Lab Demo — Runbook as a Web Page

Date: 2026-09-29

Roadmap row "Runbook as a web page" of the [lab SDLC demo roadmap](2026-09-25-lab-sdlc-demo-roadmap.md): render [`docs/demo/`](../../demo/README.md) as a static site to present from in an interview, with each scenario's saved rehearsal evidence on its own page as the fallback when the live cluster misbehaves.

## Decisions (agreed 2026-09-29)

| Topic | Decision | Why |
|---|---|---|
| Who reads the page | **Both** the interviewer (screen share) and the owner (copying commands into a terminal) | Needs to read well on a shared screen *and* make copying commands one click. Talking points stay visible — they are the pitfalls actually hit, worth showing |
| Hosting | **GitHub Pages**, default `jeromefromcn.github.io/docker-gitops/`, no custom domain | The page must survive the thing it is a fallback for: vps_oracle or oracle2 going down takes nothing with it. The repo is already public, so publishing adds no exposure. Limits (1 GB site, 100 GB/month soft bandwidth, 10-min deploy) are far from this use. Mainland-China reachability explicitly not a requirement |
| Search engines | `noindex` on every page | Costs one line; the page is for a link shared by hand, not for discovery |
| Generator | **MkDocs + Material**, versions pinned | Clean reading layout, prev/next footer, search, code-copy buttons, dark mode, Mermaid — all built in. Material is in maintenance mode since 2025-11 (critical fixes for ≥ 12 months, successor Zensical at 0.0.x); a pinned static build is unaffected, and the design below keeps the generator swappable |
| Markdown stays the only source | `docs/demo/*.md` are **not edited** to suit the site; the site's additions happen in a build copy | The pages must keep reading correctly on GitHub and in the terminal. Snippet-include syntax (`--8<--`) would show as noise on GitHub |
| Where the site's additions live | A **generator-independent `prepare.py`** that writes a build directory, not an MkDocs hook | A hook only runs under MkDocs; a plain script is unit-testable without MkDocs and survives a move to Zensical — only the final `build` command changes |
| Location | New root directory **`demo-site/`** | Not host-bound, like `tailscale/`. `site/` would collide with MkDocs' default output directory; `docs/` holds content, not tooling (docs-layout rule) |

Rejected: GitHub's own rendering of `docs/demo/` (zero work, but GitHub chrome on a shared screen, no demo-order prev/next, evidence one click away on another page); a compose-hosted copy behind NPM (dies with vps_oracle, and needs a build pipeline, NPM record and dev environment); hosting in k3s (dies with the cluster being demonstrated); a hand-written generator (maintenance for nothing).

## Design

### 1. Layout

```
demo-site/
├── README.md          # what this is, the URL, how to build locally
├── prepare.py         # docs/demo/ → build/docs/ + build/mkdocs.yml
├── mkdocs.base.yml    # theme, features, markdown extensions — everything but nav
├── overrides/main.html  # adds <meta name="robots" content="noindex">
├── requirements.txt   # pinned mkdocs, mkdocs-material
└── tests/test_prepare.py
.github/workflows/demo-runbook.yml
```

`build/` is gitignored.

### 2. `prepare.py`

Input: `docs/demo/`. Output: `build/docs/` (a copy of every page) and `build/mkdocs.yml` (`mkdocs.base.yml` + a generated `nav` + `docs_dir: docs`). Standard library only.

- **Nav from README's Order table.** The table (`| NN | [title](NN-slug.md) | why |`) is the demo order and the single source for it. Nav = `README.md` as the home page, then one entry per table row in table order, titled `NN — title`. Numeric file order is *not* the demo order (e.g. 07 runs right after 03), which is why this cannot be left to MkDocs' default.
- **Evidence block.** For each `NN-<slug>.md`, if `evidence/<slug>.txt` exists, the copy gets a collapsible block appended:
  `??? note "Rehearsal evidence — <window line from the file's first line>"` containing the file verbatim in a `text` code block. Collapsed by default: the live run comes first; the block is opened only when the cluster misbehaves.
- **Refuses to build** (exit non-zero, message names the file) when: a table row points to a missing page; a page `NN-*.md` is missing from the table; an evidence file has no page; a scenario page (01–18, i.e. any page except `00-preflight`) has no evidence file. These are exactly the drifts that would otherwise make the site silently wrong.
- The `evidence/` directory itself is not copied (its content is already inlined), so MkDocs does not publish it as loose files.

### 3. `mkdocs.base.yml`

`site_name: Lab demo runbook`, `site_url` set (needed for correct absolute links), `theme: material` with `custom_dir: overrides`, features `navigation.footer` (prev/next in demo order), `content.code.copy`, `search.highlight`, a light/dark palette toggle. Markdown extensions: `admonition`, `pymdownx.details` (the evidence block), `pymdownx.superfences` with the Mermaid custom fence (repo rule: diagrams are Mermaid), `tables`, `toc` with permalinks. `mkdocs build --strict`, so a broken relative link or a nav entry to a missing page fails the build.

### 4. Workflow `.github/workflows/demo-runbook.yml`

| Trigger | Does |
|---|---|
| `push` to `main` touching `docs/demo/**`, `demo-site/**` or the workflow | test → prepare → build → deploy |
| `pull_request` on the same paths | test → prepare → build (no deploy) |
| `workflow_dispatch` | same as push |

- Jobs: `build` (checkout, setup-python, `pip install -r demo-site/requirements.txt`, `python -m unittest` in `demo-site/tests`, `prepare.py`, `mkdocs build --strict`, post-build check, `actions/upload-pages-artifact`) and `deploy` (`actions/deploy-pages`, needs `build`, only on push/dispatch).
- Permissions: `contents: read` for build; `pages: write` + `id-token: write` for deploy only. `concurrency: pages`, `cancel-in-progress: false`, so two quick pushes publish in order.
- **Post-build check** (a few lines of shell in the workflow): every scenario page's HTML contains the evidence block, every page has the `noindex` meta, and the rendered nav order equals the README table. It checks the *output*, so it also catches a generator upgrade that drops a feature.
- One-time setup, outside git: enable Pages with source "GitHub Actions" (`gh api -X POST repos/Jeromefromcn/docker-gitops/pages -f build_type=workflow`). An outward-facing change — done during implementation after confirming with the owner.

### 5. Documentation touched

- `demo-site/README.md` (new): purpose, URL, local build (`python3 demo-site/prepare.py && mkdocs serve -f demo-site/build/mkdocs.yml`), the refusal rules, and the Material maintenance note with the Zensical escape route.
- `docs/demo/README.md`: one line near the top linking the rendered site.
- Root `README.md`: `demo-site/` in the directory tree.
- Roadmap: row status.

## Testing

- **Unit (`tests/test_prepare.py`, stdlib `unittest`, fixture directories in a temp dir):** nav follows the table and not file order; evidence appended to the right page with the window in the title; `00-preflight` gets none; each of the four refusal rules exits non-zero naming the file; the source directory is left unmodified.
- **Build:** `mkdocs build --strict` against the real `docs/demo/`.
- **Output:** the post-build check above.
- **Live, once:** the published URL loads; 18 scenario pages show a collapsed evidence block; prev/next follows the demo order; copy button works on a command block; `curl` of a page shows the `noindex` meta.

## Acceptance criteria

1. A push touching `docs/demo/**` republishes the site without manual steps; a PR touching it builds but does not publish.
2. Every scenario page (01–18) shows its rehearsal evidence as a collapsed block titled with its window; 00 has none.
3. Nav and prev/next follow README's Order table exactly.
4. The build fails on each of: a broken relative link, a page missing from the Order table, a table row without a page, a scenario page without evidence, an orphan evidence file.
5. `docs/demo/*.md` are unchanged apart from the one link line in its README.
6. Every published page carries `noindex`.
7. The site stays reachable with vps_oracle and vps-oracle2 both irrelevant to it (no request to either at page load).

## Out of scope

- Live data in the page (Grafana/Jaeger embeds, running commands from the browser): the page is a script and a fallback, not a console.
- A custom domain, a mirror on own infrastructure, mainland-China reachability.
- Migrating to Zensical: only when Material stops building or a needed fix lands only there.
- Restyling or rewriting runbook content.

## Implementation results

Implemented 2026-09-29 in commits `d7bd2a4`..`3495fc3`. CI run `36579234598`: build job green (25 unit tests, `prepare.py: 19 pages`, `mkdocs build --strict`, `check_site.py: OK`); deploy job failed with "Ensure GitHub Pages has been enabled" — **Pages is not enabled yet**. The CLI's token is refused `POST /repos/.../pages` (403, "Resource not accessible by personal access token"), so enabling it is a manual step: Settings → Pages → Source: *GitHub Actions*, then `gh workflow run demo-runbook.yml`.

| # | Criterion | Status |
|---|---|---|
| 1 | Push republishes; PR builds only | Build on push verified (run above). Deploy gated by `if: github.event_name != 'pull_request'`; the PR path is not yet exercised |
| 2 | Evidence on 01–18, collapsed, titled with its window; none on 00 | Verified locally and in CI by `check_site.py` (a page stripped of its block makes it fail: `14-bad-pod/index.html: no rehearsal evidence block`) |
| 3 | Nav and prev/next follow README's Order table | `check_site.py` walks the next-link chain from the home page and compares it with the table; locally 03 → 07 |
| 4 | Build fails on broken link / page not in table / row without page / scenario without evidence / orphan evidence | Broken link: `mkdocs build --strict` rc=1 (tried). The other four: unit tests, each also naming the file |
| 5 | `docs/demo/*.md` unchanged except one README link | Confirmed by the final review; the link is an absolute GitHub URL because a relative one leaves `docs_dir` |
| 6 | `noindex` on every page | `check_site.py` checks every generated HTML file, including `404.html` |
| 7 | No request to vps_oracle/oracle2 at page load | Static site on GitHub; runbook text mentions internal URLs only inside code blocks. To confirm on the live URL once published |

Deviations from the design:

- The post-build check is `check_site.py`, a script with its own tests, instead of inline shell in the workflow, so it also runs locally.
- `mkdocs.base.yml` uses `custom_dir: ../overrides`, relative to the generated `build/mkdocs.yml`.
- From the final review: `prepare.py` refuses **any** `*.md` other than README that does not match `NN-slug.md` (the copy would otherwise publish a stray or misnamed page with no nav entry and no evidence check); the workflow's `concurrency` covers the whole run, not only the deploy job, so an older push's slower build cannot deploy after a newer one.

Deferred minors from the final review: `evidence/preflight.txt` would be dropped silently instead of refused; the `window` regex accepts the word anywhere on the first line; the deploy guard does not also require `refs/heads/main` (the `github-pages` environment's branch policy covers it); no explicit `encoding="utf-8"`; nav titles would show literal markdown markup if a title ever contained it.

