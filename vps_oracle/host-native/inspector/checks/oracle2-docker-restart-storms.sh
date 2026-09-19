#!/usr/bin/env bash
# checks/oracle2-docker-restart-storms.sh
#
# Runs docker-restart-storms.sh against vps-oracle2's docker daemon over
# SSH (alert only, same as the local check). Alert lines are prefixed
# "[vps-oracle2]"; an unreachable host also surfaces here as an alert
# ("docker daemon unreachable"), which doubles as a liveness check.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export DOCKER_HOST="${INSPECTOR_ORACLE2_DOCKER_HOST:-ssh://ubuntu@vps-oracle2}"
export INSPECTOR_INSTANCE="vps-oracle2"
exec "$SCRIPT_DIR/docker-restart-storms.sh"
