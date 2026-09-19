#!/usr/bin/env bash
# vps_gcp/inspector-checks/lib/remote.sh — shared by every gcp check.
# Sourced, never executed. The checks run on vps_oracle but inspect (and, for
# auto-tier ones, clean up) vps-gcp's docker daemon over SSH.
#
# Overrides `docker` with a function that adds a timeout (a hung SSH session
# must not stall the whole inspection run), so the check bodies read exactly
# like their local vps_oracle counterparts. DOCKER_HOST is what actually
# redirects every docker call to gcp.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../vps_oracle/host-native/inspector/lib/common.sh"

export DOCKER_HOST="${INSPECTOR_GCP_DOCKER_HOST:-ssh://ubuntu@vps-gcp}"
DOCKER_TIMEOUT="${INSPECTOR_DOCKER_TIMEOUT:-30}"

# `type -P`: timeout can only exec a real binary, not this function.
docker() { timeout "$DOCKER_TIMEOUT" "$(type -P docker)" "$@"; }

# require_daemon <check-script-name>: alert and exit 0 if gcp's daemon is
# unreachable. inspect.sh groups the report by host directory, so the alert
# shows up under the vps_gcp block; this doubles as a liveness check.
require_daemon() {
  docker info >/dev/null 2>&1 || {
    emit_result "alert" "flagged" "check:$1" \
      "docker daemon unreachable — check skipped"
    exit 0
  }
}
