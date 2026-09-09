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
#
# Covers Bash as well as Edit/Write: a heredoc (`cat > docker-compose.yml`)
# writes a file without ever going through the Edit tool, so keying only on
# tool_input.file_path would leave that path unguarded. For Bash there is no
# file path to read, so the fallback asks git which compose files changed.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
input="$(cat)"
file="$(jq -r '.tool_input.file_path // empty' <<<"$input" 2>/dev/null)"

files=()
if [ -n "$file" ]; then
  case "$file" in
    */compose/*/docker-compose.yml) [ -f "$file" ] && files=("$file") ;;
  esac
else
  # Bash (or any tool without a file_path): ask git what actually changed.
  while IFS= read -r changed; do
    [ -n "$changed" ] || continue
    [ -f "$repo_root/$changed" ] && files+=("$repo_root/$changed")
  done < <(cd "$repo_root" && git status --porcelain -- '*/compose/*/docker-compose.yml' 2>/dev/null | awk '{print $NF}')
fi

[ "${#files[@]}" -gt 0 ] || exit 0

status=0
for stack_file in "${files[@]}"; do
  stack_dir="$(dirname "$stack_file")"
  file="$stack_file"

  if command -v docker >/dev/null 2>&1; then
    if ! err="$(cd "$stack_dir" && docker compose config -q 2>&1)"; then
      echo "docker compose config failed for $file:" >&2
      echo "$err" >&2
      status=2
    fi
  fi
done

checker="$repo_root/.github/scripts/check-compose-conventions.py"
if [ -f "$checker" ] && command -v python3 >/dev/null 2>&1; then
  if ! out="$(cd "$repo_root" && python3 "$checker" 2>&1)"; then
    echo "compose conventions check failed (see .claude/rules/compose-conventions.md):" >&2
    grep '^FAIL' <<<"$out" >&2
    status=2
  fi
fi

exit $status
