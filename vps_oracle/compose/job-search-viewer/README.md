# job-search-viewer

Read-only browser view of the markdown in the private `job-search` repo, at
`https://job-search.jerome.cloudns.asia` (NPM access list `self-only-and-auth`).

- The repo's working tree is bind-mounted read-only, so an edit shows up on a
  plain browser refresh — no rebuild, no restart.
- nginx serves only directory listings (JSON autoindex) and `*.md`; any other
  file in the repo returns 404.
- `site/index.html` crawls the listings into a file tree and renders markdown
  client-side (marked + DOMPurify from jsdelivr, pinned versions).
- autoindex hides dot-entries, so dot directories (`.claude/`, ...) are not
  shown in the tree.

The bind mount hardcodes `/home/ubuntu/jerome/job-search`; if that repo moves,
update the path in `docker-compose.yml` and recreate the container.
