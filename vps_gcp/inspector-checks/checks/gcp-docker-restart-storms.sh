#!/usr/bin/env bash
# vps_gcp/inspector-checks/checks/gcp-docker-restart-storms.sh
#
# Flags vps-gcp containers whose RestartCount is unusually high or whose
# state is stuck in `restarting` (ALERT ONLY, same rationale as the local
# docker-restart-storms.sh). Runs on vps_oracle (triggered by its inspector)
# against gcp's docker daemon over SSH. inspect.sh groups the report by
# the host directory this check lives under, so no instance prefix is needed;
# an unreachable host alerts too, which doubles as a liveness check.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/remote.sh"

STORM_COUNT="${INSPECTOR_RESTART_STORM_COUNT:-10}"

require_daemon "gcp-docker-restart-storms.sh"

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
