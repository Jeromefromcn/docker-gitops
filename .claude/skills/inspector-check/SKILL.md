---
name: inspector-check
description: Add or modify an inspection check under vps_oracle/host-native/inspector. Use when you need to "add an inspection item", "make inspector detect X", "add an alert", or decide after a failure post-mortem to add automated detection. Enforces one-to-one pairing of checks/ and tests/.
---

# Add an inspector check

The inspection scripts run via a systemd timer at 09:00/21:00 daily, and each run always sends a Telegram report. For background and the tiering design, see the [design doc](../../../docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md).

**Where it goes:** a check about vps_oracle itself → `vps_oracle/host-native/inspector/checks/`. A check about another host (run remotely from vps_oracle) → `<host>/inspector-checks/checks/` as a standalone script (sets `DOCKER_HOST`, sources `lib/common.sh`; no logic under `vps_oracle/`); its test goes in the sibling `tests/`. See `vps_oracle2/inspector-checks/README.md`. Every alert from a remote check must name the instance.

## Hard rule: one check, one test

Every `checks/<name>.sh` (in either location) **must** have a matching `tests/test-<name>.sh` beside it. CI (`.github/workflows/repo-conventions.yml`) checks this pairing and fails outright if it's missing. Write the test before the implementation.

## 1. Decide the tier: auto or alert

| Tier | Meaning | When to use |
|---|---|---|
| `auto` | Detect and auto-clean | the cost of a false positive is acceptable and reversible — dangling image, stopped container, build cache |
| `alert` | Report only, wait for a human | **the cost of a false positive is asymmetric** — possibly the sole copy of some data, or a system state that needs human judgment. docker volume, Released PV, stuck Terminating pod are all `alert` |

If unsure, pick `alert`.

## 2. Write the test (first)

Follow the pattern of [`tests/test-k3s-released-pvs.sh`](../../../vps_oracle/host-native/inspector/tests/test-k3s-released-pvs.sh):

- `source "$SCRIPT_DIR/lib.sh"` for `assert_true` / `finish_tests`
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
source "$SCRIPT_DIR/../lib/common.sh"
```

- Output always goes through `emit_result <tier> <action> <target> <detail>`; `tier` is `auto`/`alert`, `action` is `flagged`/`deleted`/`would-delete`
- Thresholds come from environment variables with defaults: `"${INSPECTOR_XXX:-900}"`
- k3s-related checks use `${INSPECTOR_KUBECONFIG:-$INSPECTOR_STATE_DIR/kubeconfig}`; when the file is missing, raise an alert pointing to running `k3s/setup-kubeconfig.sh`
- Do **not** use `set -e` (`-uo pipefail` is enough) — a single item failing to process shouldn't abort the whole inspection round

## 4. Wire into the main inspection flow

Confirm that [`inspect.sh`](../../../vps_oracle/host-native/inspector/inspect.sh) will discover the new check (see whether it iterates the directory or has an explicit list).

## 5. Verify

```bash
cd vps_oracle/host-native/inspector/tests && ./test-<name>.sh
for t in test-*.sh; do [ "$t" = test-common.sh ] || ./"$t" >/dev/null || echo "FAIL $t"; done
```

Commit only when all green.