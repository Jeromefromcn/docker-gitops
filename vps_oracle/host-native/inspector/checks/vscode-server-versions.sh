#!/usr/bin/env bash
# checks/vscode-server-versions.sh
#
# Deletes stale ~/.vscode-server/cli/servers/<version>/ directories:
# not among the N most-recently-used entries in lru.json, and not
# referenced by any live server-main.js process. See design spec's
# "VS Code server 版本目錄堆積" row.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

SERVERS_DIR="${INSPECTOR_VSCODE_SERVERS_DIR:-$HOME/.vscode-server/cli/servers}"
KEEP_COUNT="${INSPECTOR_KEEP_SERVER_VERSIONS:-2}"
LRU_FILE="$SERVERS_DIR/lru.json"

[ -d "$SERVERS_DIR" ] || exit 0

mapfile -t existing_dirs < <(
  find "$SERVERS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
)
[ "${#existing_dirs[@]}" -eq 0 ] && exit 0

mapfile -t lru_order < <(jq -r '.[]?' "$LRU_FILE" 2>/dev/null)

declare -A keep
kept=0
for name in "${lru_order[@]}"; do
  [ "$kept" -ge "$KEEP_COUNT" ] && break
  for existing in "${existing_dirs[@]}"; do
    if [ "$name" = "$existing" ]; then
      keep["$name"]=1
      kept=$((kept + 1))
      break
    fi
  done
done

for dir in "${existing_dirs[@]}"; do
  [ -n "${keep[$dir]:-}" ] && continue

  if pgrep -f "vscode-server/cli/servers/${dir}/server/out/server-main\\.js" >/dev/null 2>&1; then
    continue   # actively referenced by a live process -- never delete
  fi

  size="$(du -sh "$SERVERS_DIR/$dir" 2>/dev/null | cut -f1)"
  detail="not in top ${KEEP_COUNT} lru.json entries, no active process, size=${size:-unknown}"

  if [ "${INSPECTOR_DRY_RUN:-0}" = "1" ]; then
    emit_result "auto" "would-delete" "$dir" "$detail"
  else
    rm -rf "${SERVERS_DIR:?}/${dir:?}"
    emit_result "auto" "deleted" "$dir" "$detail"
  fi
done
