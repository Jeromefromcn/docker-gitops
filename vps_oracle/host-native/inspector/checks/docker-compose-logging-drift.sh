#!/usr/bin/env bash
# checks/docker-compose-logging-drift.sh
#
# Scans <repo>/<host>/compose/*/docker-compose.yml and flags services
# missing logging.options.max-size. Design spec's "compose 檔 logging
# 配置漂移" row (ALERT ONLY — the inspector never edits compose files).
# Parses with `docker compose config --no-interpolate --format json`
# instead of grep/awk: the repo has no yq, and docker already parses
# this exact file format everywhere else. --no-interpolate keeps
# ${VAR} literals valid without the stack's .env present.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

REPO_ROOT="${INSPECTOR_REPO_ROOT:-$(cd "$INSPECTOR_ROOT/../.." && pwd)}"

shopt -s nullglob
files=("$REPO_ROOT"/*/compose/*/docker-compose.yml)
[ "${#files[@]}" -eq 0 ] && exit 0

for file in "${files[@]}"; do
  relpath="${file#"$REPO_ROOT"/}"
  json="$(docker compose -f "$file" config --no-interpolate --format json 2>/dev/null)" || {
    emit_result "alert" "flagged" "$relpath" \
      "docker compose config failed — file could not be parsed, manual review needed"
    continue
  }

  while read -r svc; do
    [ -n "$svc" ] || continue
    max_size="$(jq -r --arg s "$svc" '.services[$s].logging.options["max-size"] // empty' <<<"$json")"
    if [ -z "$max_size" ]; then
      emit_result "alert" "flagged" "$relpath:$svc" \
        "service has no logging.options.max-size (repo convention: max-size 10m, see root README 日志大小限制)"
    fi
  done < <(jq -r '.services | keys[]' <<<"$json")
done
