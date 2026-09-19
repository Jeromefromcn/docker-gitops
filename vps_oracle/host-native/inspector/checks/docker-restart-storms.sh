#!/usr/bin/env bash
# checks/docker-restart-storms.sh
#
# Flags containers whose RestartCount is unusually high or whose state is
# stuck in `restarting`. Design spec's "Docker restart storm" row (ALERT
# ONLY — auto-restart can mask a config error; surfacing it is the
# point, resolving it is not the inspector's job).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

STORM_COUNT="${INSPECTOR_RESTART_STORM_COUNT:-10}"
# Set by remote wrappers (e.g. oracle2-docker-restart-storms.sh, which also
# sets DOCKER_HOST) so every alert line names the instance it came from --
# the report title only says vps_oracle. Empty for the local run.
tag="${INSPECTOR_INSTANCE:+[$INSPECTOR_INSTANCE] }"
# timeout: a remote DOCKER_HOST=ssh:// can hang instead of failing.
DOCKER_TIMEOUT="${INSPECTOR_DOCKER_TIMEOUT:-30}"

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
