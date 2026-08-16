#!/usr/bin/env bash
# checks/docker-restart-storms.sh
#
# Flags containers whose RestartCount is异常 high or whose state is
# stuck in `restarting`. Design spec's "Docker 重啟風暴" row (ALERT
# ONLY — auto-restart can mask a config error; surfacing it is the
# point, resolving it is not the inspector's job).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

STORM_COUNT="${INSPECTOR_RESTART_STORM_COUNT:-10}"

docker info >/dev/null 2>&1 || {
  emit_result "alert" "flagged" "check:docker-restart-storms.sh" \
    "docker daemon unreachable — check skipped"
  exit 0
}

mapfile -t ids < <(docker ps -aq 2>/dev/null)
[ "${#ids[@]}" -eq 0 ] && exit 0

for id in "${ids[@]}"; do
  [ -n "$id" ] || continue
  line="$(docker inspect --format '{{.Name}} {{.RestartCount}} {{.State.Status}}' "$id" 2>/dev/null)" || continue
  read -r name count status <<<"$line"
  name="${name#/}"

  if [ "$status" = "restarting" ] || [ "$count" -ge "$STORM_COUNT" ]; then
    emit_result "alert" "flagged" "docker container $name" \
      "restart count ${count}, state ${status} — possible crash loop (threshold count ${STORM_COUNT})"
  fi
done
