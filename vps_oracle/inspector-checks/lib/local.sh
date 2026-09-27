#!/usr/bin/env bash
# vps_oracle/inspector-checks/lib/local.sh — shared by every check about
# vps_oracle itself. Sourced, never executed.
#
# The thinnest of the four <x>/inspector-checks/lib/ files: a check about the
# local host has nothing to override — no `DOCKER_HOST` like remote.sh sets,
# no kubeconfig like kube.sh sets — so this only borrows the engine's
# helpers. It exists so all four check trees have the same shape.
#
# The engine is vps_oracle/host-native/inspector/ (inspect.sh, systemd/,
# state/, lib/common.sh). It discovers this directory exactly like
# vps_oracle2/inspector-checks/, vps_gcp/inspector-checks/ and
# k3s/inspector-checks/, and takes the report's instance name from the
# directory name — which is why the checks about vps_oracle live here rather
# than beside the engine: "the directory says what the check inspects" then
# holds for every instance with no exception.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../vps_oracle/host-native/inspector/lib/common.sh"
