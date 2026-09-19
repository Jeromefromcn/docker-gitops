#!/usr/bin/env bash
# vps_oracle2/inspector-checks/checks/oracle2-docker-unused-networks.sh
#
# vps-oracle2 counterpart of checks/docker-unused-networks.sh (same logic and tier), run
# from vps_oracle against oracle2's docker over SSH; see lib/remote.sh.
#
# Removes custom docker networks with zero containers attached. Design
# spec's "Docker unused network" row (auto tier, no age threshold —
# re-creating a network costs nothing). `--filter type=custom` already
# excludes the predefined bridge/host/none, so per-network `docker
# network rm` of the enumerated candidates is exactly `docker network
# prune` semantics but with per-target reporting.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/remote.sh"

require_daemon "oracle2-docker-unused-networks.sh"

mapfile -t nets < <(docker network ls --filter type=custom --format '{{.Name}}' 2>/dev/null)
[ "${#nets[@]}" -eq 0 ] && exit 0

for name in "${nets[@]}"; do
  [ -n "$name" ] || continue
  attached="$(docker network inspect --format '{{len .Containers}}' "$name" 2>/dev/null)" || continue
  [ "$attached" = "0" ] || continue

  if [ "${INSPECTOR_DRY_RUN:-0}" = "1" ]; then
    emit_result "auto" "would-delete" "docker network $name" \
      "custom network with no containers attached"
  elif docker network rm "$name" >/dev/null 2>&1; then
    emit_result "auto" "deleted" "docker network $name" \
      "custom network with no containers attached"
  else
    emit_result "alert" "flagged" "docker network $name" \
      "docker network rm failed — manual investigation needed"
  fi
done
