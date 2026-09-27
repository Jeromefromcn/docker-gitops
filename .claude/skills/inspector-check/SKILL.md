---
name: inspector-check
description: Add or modify an inspection check — local to vps_oracle, about another host, or cluster-wide. Use when you need to "add an inspection item", "make inspector detect X", "add an alert", or decide after a failure post-mortem to add automated detection. Enforces one-to-one pairing of checks/ and tests/, and the location rule that decides which machine the report attributes a finding to.
---

# Add an inspector check

The inspection scripts run via a systemd timer at 09:00/21:00 daily, and each run always sends a Telegram report. For background and the tiering design, see the [design doc](../../../docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md).

**Where it goes** — the directory a check lives in is what the report uses to say *which machine* its findings are about, so it has to name the thing the check actually inspects. Every target has a tree; the engine under `vps_oracle/host-native/inspector/` is not one of them and holds no checks.

| The check inspects | Location | Sources |
|---|---|---|
| vps_oracle itself | `vps_oracle/inspector-checks/checks/` | `$SCRIPT_DIR/../lib/local.sh` |
| another host, reached over SSH | `<host>/inspector-checks/checks/` | `$SCRIPT_DIR/../lib/remote.sh` (sets `DOCKER_HOST`) |
| the k3s cluster, both nodes | `k3s/inspector-checks/checks/` | `$SCRIPT_DIR/../lib/kube.sh` |

No logic about a remote host or the cluster belongs under `vps_oracle/`. Tests go in the sibling `tests/` in every case.

A cluster-wide check belongs under `k3s/`, never under a host: it reads the API rather than one machine, so filing it under a host attributes its findings to that host — the 2026-09-27 lab OOM was reported under `vps_oracle` while every `lab-environment` pod runs on vps-oracle2. The `k3s-` name prefix proves nothing either way: `k3s-containerd-images.sh` is genuinely node-local (it reads this host's containerd via `crictl`) and belongs in `vps_oracle/inspector-checks/`. See the README in the tree you are writing into. Every alert must name the instance — or, for a cluster-wide check, the node — it concerns.

## Hard rule: one check, one test

Every `checks/<name>.sh` (in any of the three locations above) **must** have a matching `tests/test-<name>.sh` beside it. CI (`.github/workflows/repo-conventions.yml`) checks this pairing and fails outright if it's missing. Write the test before the implementation.

## 1. Decide the tier: auto or alert

| Tier | Meaning | When to use |
|---|---|---|
| `auto` | Detect and auto-clean | the cost of a false positive is acceptable and reversible — dangling image, stopped container, build cache |
| `alert` | Report only, wait for a human | **the cost of a false positive is asymmetric** — possibly the sole copy of some data, or a system state that needs human judgment. docker volume, Released PV, stuck Terminating pod are all `alert` |

If unsure, pick `alert`.

## 2. Write the test (first)

Follow the pattern of [`k3s/inspector-checks/tests/test-k3s-released-pvs.sh`](../../../k3s/inspector-checks/tests/test-k3s-released-pvs.sh):

- Source the shared assert helper: `"$SCRIPT_DIR/lib.sh"` from the local inspector, `"$SCRIPT_DIR/../../../vps_oracle/host-native/inspector/tests/lib.sh"` from a `<host>/` or `k3s/` tree
- Write fake `docker` / `kubectl` / `crictl` scripts in a temp dir and prepend them to `PATH` — **tests must be hermetic**, never touching the real docker/k8s
- Destructive stub commands (`rm`/`rmi`/`prune`/`delete`) append their argv to `$STUB_DIR/calls.log`, and the test asserts "what will actually be executed"
- For time-related fixtures, compute inside the stub with `date -d '-30 minutes'` rather than hardcoding timestamps

Cover at least these cases:

- [ ] What should match does match, and the detail carries actionable information
- [ ] What shouldn't match doesn't (one on each side of the boundary value)
- [ ] `auto` check: dry run only proposes, never executes (`INSPECTOR_DRY_RUN=1`, assert `calls.log` doesn't exist)
- [ ] `alert` check: **never** produces `deleted` / `would-delete`
- [ ] When a dependency is unavailable (kubeconfig missing, API unreachable), **raise an alert instead of silently skipping**
- [ ] On a missing field / bad format, degrade to `unknown` or skip, without crashing the whole loop

## 3. Write the check

```bash
#!/usr/bin/env bash
# checks/<name>.sh
#
# <one line describing what this detects>. <which line in the design doc this corresponds to, and the tiering rationale>
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/local.sh"   # ../lib/remote.sh for <host>/, ../lib/kube.sh for k3s/
```

- Output always goes through `emit_result <tier> <action> <target> <detail>`; `tier` is `auto`/`alert`, `action` is `flagged`/`deleted`/`would-delete`
- Thresholds come from environment variables with defaults: `"${INSPECTOR_XXX:-900}"`
- k3s-related checks use `${INSPECTOR_KUBECONFIG:-$INSPECTOR_STATE_DIR/kubeconfig}`; when the file is missing, raise an alert pointing to running `k3s/setup-kubeconfig.sh`
- Do **not** use `set -e` (`-uo pipefail` is enough) — a single item failing to process shouldn't abort the whole inspection round

## 4. Wire into the main inspection flow

Confirm that [`inspect.sh`](../../../vps_oracle/host-native/inspector/inspect.sh) will discover the new check (see whether it iterates the directory or has an explicit list).

## 5. Verify

```bash
cd <the tests/ dir you wrote into> && ./test-<name>.sh
# then everything, the way CI does:
cd "$(git rev-parse --show-toplevel)"
for t in vps_oracle/host-native/inspector/tests/test-*.sh */inspector-checks/tests/test-*.sh; do
  case "$(basename "$t")" in test-common.sh|test-inspect.sh) continue ;; esac
  ./"$t" >/dev/null || echo "FAIL $t"
done
```

Commit only when all green.