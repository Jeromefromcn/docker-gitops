#!/usr/bin/env bash
# vps_oracle2/inspector-checks/checks/oracle2-docker-restart-storms.sh
#
# Flags vps-oracle2 containers whose RestartCount is unusually high or whose
# state is stuck in `restarting` (ALERT ONLY, same rationale as the local
# docker-restart-storms.sh). Runs on vps_oracle (triggered by its inspector)
# against oracle2's docker daemon over SSH. Every target is prefixed
# "[vps-oracle2]" because the report title only says vps_oracle; an
# unreachable host alerts too, which doubles as a liveness check.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../vps_oracle/host-native/inspector/lib/common.sh"

export DOCKER_HOST="${INSPECTOR_ORACLE2_DOCKER_HOST:-ssh://ubuntu@vps-oracle2}"
STORM_COUNT="${INSPECTOR_RESTART_STORM_COUNT:-10}"
# timeout: a remote DOCKER_HOST=ssh:// can hang instead of failing.
DOCKER_TIMEOUT="${INSPECTOR_DOCKER_TIMEOUT:-30}"
tag="[vps-oracle2] "

timeout "$DOCKER_TIMEOUT" docker info >/dev/null 2>&1 || {
  emit_result "alert" "flagged" "${tag}check:docker-restart-storms.sh" \
    "docker daemon unreachable — check skipped"
  exit 0
}

mapfile -t ids < <(timeout "$DOCKER_TIMEOUT" docker ps -aq 2>/dev/null)
[ "${#ids[@]}" -eq 0 ] && exit 0

for id in "${ids[@]}"; do
  [ -n "$id" ] || continue
  line="$(timeout "$DOCKER_TIMEOUT" docker inspect --format '{{.Name}} {{.RestartCount}} {{.State.Status}}' "$id" 2>/dev/null)" || continue
  read -r name count status <<<"$line"
  name="${name#/}"

  if [ "$status" = "restarting" ] || [ "$count" -ge "$STORM_COUNT" ]; then
    emit_result "alert" "flagged" "${tag}docker container $name" \
      "restart count ${count}, state ${status} — possible crash loop (threshold count ${STORM_COUNT})"
  fi
done
