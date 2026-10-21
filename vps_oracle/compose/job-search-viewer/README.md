# job-search-viewer

Read-only browser view of the markdown in two private `job-search` repos, at
`https://job-search.jerome.cloudns.asia` (NPM access list `self-only-and-auth`).
The landing page asks which one to open:

| Source | Repo | Mounted at |
|---|---|---|
| Jerome | `/home/ubuntu/jerome/job-search` | `/srv/files/jerome` |
| Bridget | `/home/ubuntu/bridget/job-search` | `/srv/files/bridget` |

- The working trees are bind-mounted read-only, so an edit shows up on a
  plain browser refresh — no rebuild, no restart.
- nginx serves only directory listings (JSON autoindex) and `*.md`; any other
  file in the repos returns 404.
- `site/index.html` crawls the listings into a file tree and renders markdown
  client-side (marked + DOMPurify from jsdelivr, pinned versions). URLs are
  `#/<source>/<path>`; `⇄` in the sidebar goes back to the chooser.
- autoindex hides dot-entries, so dot directories (`.claude/`, ...) are not
  shown in the tree.
- Both sources share one URL and one access list — anyone who can log in sees
  both.

To add or move a source, change the bind mount in `docker-compose.yml` and the
`SOURCES` map in `site/index.html` together, then recreate the container.
