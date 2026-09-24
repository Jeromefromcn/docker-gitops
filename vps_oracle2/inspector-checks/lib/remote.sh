#!/usr/bin/env bash
# vps_oracle2/inspector-checks/lib/remote.sh — shared by every oracle2 check.
# Sourced, never executed. The checks run on vps_oracle but inspect (and, for
# auto-tier ones, clean up) vps-oracle2's docker daemon over SSH.
#
# Overrides `docker` with a function that adds a timeout (a hung SSH session
# must not stall the whole inspection run), so the check bodies read exactly
# like their local vps_oracle counterparts. DOCKER_HOST is what actually
# redirects every docker call to oracle2.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../vps_oracle/host-native/inspector/lib/common.sh"

export DOCKER_HOST="${INSPECTOR_ORACLE2_DOCKER_HOST:-ssh://ubuntu@vps-oracle2}"
DOCKER_TIMEOUT="${INSPECTOR_DOCKER_TIMEOUT:-30}"

# `type -P`: timeout can only exec a real binary, not this function.
docker() { timeout "$DOCKER_TIMEOUT" "$(type -P docker)" "$@"; }

# oracle2_ssh <cmd...>: run a command on oracle2 over SSH, for the k3s-agent
# checks that need the node's own tools (`sudo k3s crictl`), which no
# DOCKER_HOST-style redirection can reach. Same timeout rationale as docker().
ORACLE2_SSH_HOST="${INSPECTOR_ORACLE2_SSH_HOST:-vps-oracle2}"
oracle2_ssh() {
  timeout "$DOCKER_TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout=10 "$ORACLE2_SSH_HOST" "$@"
}

# require_daemon <check-script-name>: alert and exit 0 if oracle2's daemon is
# unreachable. inspect.sh groups the report by host directory, so the alert
# shows up under the vps_oracle2 block; this doubles as a liveness check.
require_daemon() {
  docker info >/dev/null 2>&1 || {
    emit_result "alert" "flagged" "check:$1" \
      "docker daemon unreachable — check skipped"
    exit 0
  }
}
