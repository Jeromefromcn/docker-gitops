#!/usr/bin/env bash
# PostToolUse hook: after Claude edits a docker-compose.yml, validate it
# immediately instead of finding out at `docker compose up -d` time.
#
# Two checks:
#   1. `docker compose config -q` — YAML syntax plus variable interpolation.
#      This works locally (the .env files exist on this host); the CI check
#      is YAML-only because .env is gitignored.
#   2. the repo conventions checker, scoped to nothing in particular —
#      it is cheap enough to run whole.
#
# Exit 2 sends stderr back to Claude so it can fix the file right away.
set -uo pipefail

input="$(cat)"
file="$(jq -r '.tool_input.file_path // empty' <<<"$input" 2>/dev/null)"
[ -n "$file" ] || exit 0
case "$file" in
  */compose/*/docker-compose.yml) ;;
  *) exit 0 ;;
esac
[ -f "$file" ] || exit 0

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
stack_dir="$(dirname "$file")"
status=0

if command -v docker >/dev/null 2>&1; then
  if ! err="$(cd "$stack_dir" && docker compose config -q 2>&1)"; then
    echo "docker compose config failed for $file:" >&2
    echo "$err" >&2
    status=2
  fi
fi

checker="$repo_root/.github/scripts/check-compose-conventions.py"
if [ -f "$checker" ] && command -v python3 >/dev/null 2>&1; then
  if ! out="$(cd "$repo_root" && python3 "$checker" 2>&1)"; then
    echo "compose conventions check failed (see .claude/rules/compose-conventions.md):" >&2
    grep '^FAIL' <<<"$out" >&2
    status=2
  fi
fi

exit $status
