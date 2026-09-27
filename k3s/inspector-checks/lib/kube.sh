#!/usr/bin/env bash
# k3s/inspector-checks/lib/kube.sh — shared by every cluster-scoped check.
# Sourced, never executed.
#
# These checks read the cluster API (`kubectl … -A`) rather than one host. The
# cluster is a single component spanning both nodes, so it has no host
# directory to live under, which is why this tree sits at the repo root
# beside k3s/ instead of under a <host>/ — the same rule that put k3s/ itself
# at the root. `inspect.sh` derives the report's instance label from the
# directory it finds a check in, so these findings appear under `k3s`; that
# name is true, where a host name would not be. They used to live in
# vps_oracle's checks/, which is how the 2026-09-27 lab OOM was read as a
# vps_oracle problem while every lab-environment pod runs on vps-oracle2.
#
# Deliberately only the common.sh borrow lives here. The kubeconfig path and
# the `kc` wrapper are still per-check — they read different resources and
# some define no `kc` at all — so hoisting those is a separate change.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../vps_oracle/host-native/inspector/lib/common.sh"
