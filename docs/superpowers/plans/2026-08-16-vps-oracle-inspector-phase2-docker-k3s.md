# vps_oracle Inspector — Phase 2 (Docker + k3s Hygiene Checks) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the 13 docker/k3s hygiene checks from the design spec's check table (7 auto-tier, 6 alert-tier) as drop-in `checks/*.sh` scripts — `inspect.sh`'s glob discovery picks them up with zero changes to existing code — plus the least-privilege k3s access they need.

**Architecture:** Same host-native bash pattern as phase 1: each check is an independently executable script that sources `lib/common.sh`, prints zero or more `emit_result`-shaped JSON lines, and exits 0. Docker checks call the `docker` CLI as `ubuntu` (docker group, verified working); k3s checks call `kubectl` with a dedicated least-privilege ServiceAccount kubeconfig stored in gitignored `state/`; the two operations phase 1 never needed root for (`crictl`, reading `/var/lib/docker/containers`) use narrowly-scoped `sudo -n` (passwordless sudo verified on this host) — exactly the spec's "單獨用 sudo 包那一小段" escape hatch. All notification text is English (explicit user requirement, 2026-08-16 — see inspect.sh header).

**Tech Stack:** bash (`set -uo pipefail`, not `-e`), `docker` CLI 29.6 (incl. `docker compose config --format json`, which replaces a missing `yq` for YAML parsing), `kubectl` (k3s v1.36.2), `crictl` via `sudo -n`, `jq`, GNU `date -d`.

**Spec:** [`docs/superpowers/specs/2026-08-15-vps-oracle-inspector-design.md`](../specs/2026-08-15-vps-oracle-inspector-design.md) — "Check 清單與分級規則" tables define all 13 checks; "部署" section defines the sudo-scoping and kubeconfig requirements.

## Global Constraints

- **Inherited from phase 1, unchanged:** report every run via `inspector-tg` apprise target (no changes to `inspect.sh` in this phase — glob discovery means new checks need no main-loop edits); all report text English; `INSPECTOR_DRY_RUN=1` makes every destructive path print `would-delete`/`would-kill` and do nothing; thresholds are overridable env vars declared at the top of each script; never edit compose/k8s config files (the logging-drift check only reports).
- **One commit per check**, matching phase 1's granularity and the repo's "one change per commit" rule. Commits go directly to `main` in this checkout (phase 1 precedent); before each commit run `git status --short` and `git log --oneline -1` — other Claude sessions share this checkout (see memory) and may have interleaved.
- **Committing a check to `main` makes it live** on the next timer fire (`docker-gitops-inspector.timer` is enabled, next run 09:00/21:00 HKT). Every task therefore dry-runs its check against the real host *before* committing, and Task 14 does a full real-mode validation run.
- **No admin kubeconfig.** k3s checks use `state/kubeconfig` (gitignored) bound to ServiceAccount `workloads/docker-gitops-inspector` with exactly: pods get/list/delete, jobs get/list/delete, persistentvolumes get/list. The spec's "唯讀 kubeconfig 複本" wording predates the tier table — the tier table's auto-actions (`kubectl delete pod`, `kubectl delete job`) require delete rights, so least-privilege-with-delete is the faithful reading.
- **`sudo -n` only, never bare `sudo`** — if passwordless sudo is ever revoked, the check must emit an alert line and skip, not hang waiting for a TTY it doesn't have (systemd).
- **Tests are hermetic:** docker/kubectl/crictl are stubbed via a temp `PATH` dir (same technique as phase 1's curl stub in `test-inspect.sh`). Tests never touch real docker/k3s state; real-cluster validation happens only in each task's dry-run step.
- **Silent-skip is a bug:** a check that can't run (docker daemon down, API unreachable, kubeconfig missing, sudo revoked) must emit a tier=alert line saying so — otherwise the Telegram report says "一切正常" while half the inspector quietly did nothing.
- k3s RBAC manifests live in `vps_oracle/inspector/k3s/`, **not** `vps_oracle/k3s/manifests/` — everything under `k3s/manifests/` and `k3s/apps/*/k8s/` is ArgoCD GitOps-managed and manually applying there makes selfHeal fight you (see `vps_oracle/k3s/README.md`). The inspector RBAC is applied once by its own setup script.

## Verified Host Facts (2026-08-16, calibrates every dry-run expectation below)

- docker 29.6.0; `ubuntu` uses it without sudo. Current state: 10 running containers, **0 exited, 0 dangling images, 0B build cache**, 51 volumes of which 1 is in use (50 dangling: ~47 anonymous + 3 named), custom networks `3x-ui_default`/`monitoring_default`/`proxy` all in use. `/var/lib/docker/containers/*` is root-only — the oversized-log check needs `sudo`.
- k3s v1.36.2 active; `kubectl` at `/usr/local/bin`; `~/.kube/config` is an **admin** copy (user `default`) — not usable per the no-admin-kubeconfig constraint. Current cluster state: **0 Failed pods, 0 Released PVs, 0 stuck-Terminating pods**, exactly 1 completed Job (`kyverno/kyverno-migrate-resources`, <1h old — under any sane retention threshold).
- `crictl` needs sudo (socket + config are root-only); passwordless sudo confirmed (`sudo -n true` succeeds).
- `crictl images -o json` exposes no creation timestamp (fields: id/pinned/repoDigests/repoTags/size/username only) — so the containerd-image check takes **no age filter**; that matches the spec's action cell (`crictl rmi --prune`) and kubelet's own image GC remains the age-aware primary mechanism.
- `yq` is not installed. `docker compose -f <file> config --no-interpolate --format json` (tested, works) parses compose YAML → JSON for the logging-drift check. All 7 compose files in the repo already mention `logging` at least once — expect the drift dry run to be empty or near-empty.
- systemd's compiled default PATH for services includes `/usr/local/bin` (where kubectl lives), but Task 14 still sets `Environment=PATH=` explicitly in the unit so the dependency is visible rather than implicit.
- Spec's Completed-Job row says "超過 N 個或超過 N 天" — this plan implements **age-only** (default 3 days). A count cap would delete fresh jobs whose output someone may still be reading; age is the dimension where misjudgment cost is asymmetric, and the spec's own tiering philosophy ("誤判代價不對稱地高 → 只告警/保守") points that way.

## File Structure

```
vps_oracle/inspector/
├── k3s/                                # Task 1 — NOT under vps_oracle/k3s/ (ArgoCD territory)
│   ├── rbac.yaml                       # SA + ClusterRole + Binding + token Secret
│   └── setup-kubeconfig.sh             # one-time: apply RBAC, mint state/kubeconfig
├── checks/
│   ├── docker-stopped-containers.sh    # Task 2  (auto)
│   ├── docker-dangling-images.sh       # Task 3  (auto)
│   ├── docker-build-cache.sh           # Task 4  (auto)
│   ├── docker-unused-networks.sh       # Task 5  (auto)
│   ├── docker-restart-storms.sh        # Task 6  (alert)
│   ├── docker-unused-volumes.sh        # Task 7  (alert)
│   ├── docker-compose-logging-drift.sh # Task 8  (alert)
│   ├── docker-oversized-logs.sh        # Task 9  (alert)
│   ├── k3s-evicted-pods.sh             # Task 10 (auto)
│   ├── k3s-completed-jobs.sh           # Task 11 (auto)
│   ├── k3s-containerd-images.sh        # Task 12 (auto)
│   ├── k3s-released-pvs.sh             # Task 13 (alert)
│   └── k3s-stuck-terminating.sh        # Task 13 (alert)
├── tests/
│   ├── lib.sh                          # Task 2 — assert_true/finish_tests, shared by phase-2 tests
│   ├── test-docker-stopped-containers.sh    # Task 2
│   ├── test-docker-dangling-images.sh       # Task 3
│   ├── test-docker-build-cache.sh           # Task 4
│   ├── test-docker-unused-networks.sh       # Task 5
│   ├── test-docker-restart-storms.sh        # Task 6
│   ├── test-docker-unused-volumes.sh        # Task 7
│   ├── test-docker-compose-logging-drift.sh # Task 8
│   ├── test-docker-oversized-logs.sh        # Task 9
│   ├── test-k3s-evicted-pods.sh             # Task 10
│   ├── test-k3s-completed-jobs.sh           # Task 11
│   ├── test-k3s-containerd-images.sh        # Task 12
│   └── test-k3s-alerts.sh                   # Task 13 (covers both alert scripts)
├── systemd/
│   └── docker-gitops-inspector.service # Task 14 — add Environment=PATH line (Modify)
└── README.md                            # Task 14 — phase 2 section (Modify)
```

The 13 check names are the spec's own file names, verbatim. `tests/lib.sh` is new; phase-1 test files keep their inline helpers untouched (their pattern is left alone, new tests don't copy it 12 more times).

Every docker check starts with the same daemon guard; every k3s check with the same kubeconfig guard + primary-call guard. These 3-line blocks are deliberately duplicated per script (explicit over clever — each check independently reports why it couldn't run).

---

### Task 1: k3s least-privilege RBAC + kubeconfig bootstrap

**Files:**
- Create: `vps_oracle/inspector/k3s/rbac.yaml`
- Create: `vps_oracle/inspector/k3s/setup-kubeconfig.sh`

**Interfaces:**
- Consumes: admin `~/.kube/config` (present, verified) — used only by this one-time script, never by checks
- Produces: `state/kubeconfig` (gitignored, mode 600, token auth, server `https://127.0.0.1:6443`) — Tasks 10–13 read it via `INSPECTOR_KUBECONFIG` (default `$INSPECTOR_STATE_DIR/kubeconfig`)
- Produces: cluster objects SA/Secret `docker-gitops-inspector[-token]` in namespace `workloads`, ClusterRole/Binding `docker-gitops-inspector`

- [ ] **Step 1: Write `k3s/rbac.yaml`**

```yaml
# Cluster-side RBAC for the vps_oracle host inspector (phase 2 k3s
# checks). Applied once — idempotently — by setup-kubeconfig.sh, NOT by
# ArgoCD: deliberately outside vps_oracle/k3s/manifests/ so selfHeal
# never fights it (see vps_oracle/k3s/README.md). Least privilege per
# the spec's check table: delete rights only for the two auto-tier
# cleanup actions (Failed pods, completed Jobs); everything else
# read-only, and no access at all to secrets/configmaps/workloads.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: docker-gitops-inspector
  namespace: workloads
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: docker-gitops-inspector
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "delete"]
- apiGroups: ["batch"]
  resources: ["jobs"]
  verbs: ["get", "list", "delete"]
- apiGroups: [""]
  resources: ["persistentvolumes"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: docker-gitops-inspector
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: docker-gitops-inspector
subjects:
- kind: ServiceAccount
  name: docker-gitops-inspector
  namespace: workloads
---
# TokenRequest tokens expire; this secret-bound token does not. The
# kubeconfig written by setup-kubeconfig.sh embeds it, and it lives in
# the gitignored state/ dir — never in git.
apiVersion: v1
kind: Secret
metadata:
  name: docker-gitops-inspector-token
  namespace: workloads
  annotations:
    kubernetes.io/service-account.name: docker-gitops-inspector
type: kubernetes.io/service-account-token
```

- [ ] **Step 2: Write `k3s/setup-kubeconfig.sh`**

```bash
#!/usr/bin/env bash
# k3s/setup-kubeconfig.sh — one-time bootstrap for the inspector's k3s
# access. Applies rbac.yaml with the admin kubeconfig, waits for the SA
# token secret, and writes a least-privilege token kubeconfig to
# state/kubeconfig (gitignored). Safe to re-run: apply is idempotent and
# the existing token is reused, not rotated.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSPECTOR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$INSPECTOR_ROOT/state"
KUBECONFIG_FILE="$STATE_DIR/kubeconfig"
mkdir -p "$STATE_DIR"

kubectl apply -f "$SCRIPT_DIR/rbac.yaml"

echo "waiting for token secret to be populated..." >&2
token=""
for _ in $(seq 1 30); do
  token="$(kubectl -n workloads get secret docker-gitops-inspector-token \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)" && [ -n "$token" ] && break
  sleep 1
done
[ -n "$token" ] || { echo "ERROR: token secret never populated" >&2; exit 1; }

# Reuse the cluster CA from the admin config rather than
# insecure-skip-tls-verify.
ca_data="$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
[ -n "$ca_data" ] || { echo "ERROR: could not read cluster CA from admin kubeconfig" >&2; exit 1; }

umask 077
cat > "$KUBECONFIG_FILE" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: inspector
  cluster:
    server: https://127.0.0.1:6443
    certificate-authority-data: ${ca_data}
users:
- name: inspector
  user:
    token: ${token}
contexts:
- name: inspector
  context:
    cluster: inspector
    user: inspector
current-context: inspector
EOF
chmod 600 "$KUBECONFIG_FILE"

echo "verifying the kubeconfig works AND is not over-privileged..." >&2
kubectl --kubeconfig "$KUBECONFIG_FILE" get pods -A >/dev/null
kubectl --kubeconfig "$KUBECONFIG_FILE" get jobs -A >/dev/null
kubectl --kubeconfig "$KUBECONFIG_FILE" get pv >/dev/null
if kubectl --kubeconfig "$KUBECONFIG_FILE" -n workloads get secrets >/dev/null 2>&1; then
  echo "ERROR: kubeconfig can read secrets — RBAC is broader than intended" >&2
  exit 1
fi
echo "OK: wrote $KUBECONFIG_FILE (SA workloads/docker-gitops-inspector)" >&2
```

- [ ] **Step 3: `chmod +x`, syntax-check, run against the real cluster**

```bash
chmod +x vps_oracle/inspector/k3s/setup-kubeconfig.sh
bash -n vps_oracle/inspector/k3s/setup-kubeconfig.sh
vps_oracle/inspector/k3s/setup-kubeconfig.sh
```
Expected: `serviceaccount/… created` ×4-ish apply output, then `OK: wrote …/state/kubeconfig`.

- [ ] **Step 4: Verify least privilege from the cluster side**

```bash
kubectl auth can-i --as=system:serviceaccount:workloads:docker-gitops-inspector delete pods -A
kubectl auth can-i --as=system:serviceaccount:workloads:docker-gitops-inspector delete jobs -A
kubectl auth can-i --as=system:serviceaccount:workloads:docker-gitops-inspector get secrets -A
```
Expected: `yes`, `yes`, `no`.

- [ ] **Step 5: Commit**

```bash
git status --short   # expect only the two new files; investigate anything else first
git add vps_oracle/inspector/k3s/rbac.yaml vps_oracle/inspector/k3s/setup-kubeconfig.sh
git commit -m "Add inspector k3s RBAC and least-privilege kubeconfig bootstrap"
```

---

### Task 2: `checks/docker-stopped-containers.sh` + `tests/lib.sh`

**Files:**
- Create: `vps_oracle/inspector/tests/lib.sh`
- Create: `vps_oracle/inspector/checks/docker-stopped-containers.sh`
- Create: `vps_oracle/inspector/tests/test-docker-stopped-containers.sh`

**Interfaces:**
- Consumes: `lib/common.sh`'s `emit_result`
- Produces: `tests/lib.sh` with `assert_true(desc, cond)`, `failures` counter, `finish_tests()` — sourced by all phase-2 test scripts (Tasks 3–13)
- Overridable env vars: `INSPECTOR_STOPPED_CONTAINER_MAX_AGE_SECONDS` (default 604800 = 7 days)

- [ ] **Step 1: Write `tests/lib.sh`**

```bash
#!/usr/bin/env bash
# tests/lib.sh — shared helpers for phase-2 check tests. Sourced, never
# executed. Phase-1 test files keep their inline copies (untouched);
# phase-2 tests source this instead of duplicating the assert helper 12
# more times. The CLI-stub pattern: write fake docker/kubectl/crictl
# scripts into a temp dir, export STUB_DIR pointing at it, prepend the
# dir to PATH when invoking the check under test — same technique as
# phase 1's curl stub in test-inspect.sh. Destructive stub commands
# (rm/rmi/prune/delete) append their argv to $STUB_DIR/calls.log so
# tests can assert exactly what would have run.

failures=0

assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "true" ]; then
    echo "ok - $desc"
  else
    echo "FAIL - $desc"
    failures=$((failures + 1))
  fi
}

# Prints PASS/FAIL footer and exits 0/1 accordingly. Always the last
# line of a test script.
finish_tests() {
  echo "---"
  if [ "$failures" -eq 0 ]; then
    echo "PASS"
    exit 0
  else
    echo "FAIL: $failures check(s) failed"
    exit 1
  fi
}
```

- [ ] **Step 2: Write `checks/docker-stopped-containers.sh`**

```bash
#!/usr/bin/env bash
# checks/docker-stopped-containers.sh
#
# Removes containers in `exited` state whose exit happened more than
# INSPECTOR_STOPPED_CONTAINER_MAX_AGE_SECONDS ago (default 7 days).
# Design spec's "Docker 已停止容器" row (auto tier). Uses explicit
# per-container `docker rm` of enumerated candidates rather than a
# blanket prune, so exactly the reported targets are the ones removed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

MAX_AGE_SECONDS="${INSPECTOR_STOPPED_CONTAINER_MAX_AGE_SECONDS:-604800}"

docker info >/dev/null 2>&1 || {
  emit_result "alert" "flagged" "check:docker-stopped-containers.sh" \
    "docker daemon unreachable — check skipped"
  exit 0
}

now_epoch="$(date +%s)"

mapfile -t rows < <(docker ps -a --filter status=exited --format '{{.ID}}\t{{.Names}}' 2>/dev/null)
[ "${#rows[@]}" -eq 0 ] && exit 0

for row in "${rows[@]}"; do
  [ -n "$row" ] || continue
  id="${row%%$'\t'*}"
  name="${row#*$'\t'}"

  finished_at="$(docker inspect --format '{{.State.FinishedAt}}' "$id" 2>/dev/null)" || continue
  finished_epoch="$(date -d "$finished_at" +%s 2>/dev/null)" || continue
  age=$((now_epoch - finished_epoch))

  [ "$age" -ge "$MAX_AGE_SECONDS" ] || continue

  if [ "${INSPECTOR_DRY_RUN:-0}" = "1" ]; then
    emit_result "auto" "would-delete" "docker container ${name:-$id}" \
      "exited ${age}s ago (threshold ${MAX_AGE_SECONDS}s)"
  elif docker rm "$id" >/dev/null 2>&1; then
    emit_result "auto" "deleted" "docker container ${name:-$id}" \
      "exited ${age}s ago (threshold ${MAX_AGE_SECONDS}s)"
  else
    emit_result "alert" "flagged" "docker container ${name:-$id}" \
      "docker rm failed (exited ${age}s ago) — manual investigation needed"
  fi
done
```

- [ ] **Step 3: `chmod`, syntax-check**

```bash
chmod +x vps_oracle/inspector/checks/docker-stopped-containers.sh
chmod 644 vps_oracle/inspector/tests/lib.sh   # sourced, not executed
bash -n vps_oracle/inspector/checks/docker-stopped-containers.sh
```

- [ ] **Step 4: Write `tests/test-docker-stopped-containers.sh`**

```bash
#!/usr/bin/env bash
# tests/test-docker-stopped-containers.sh — hermetic: docker is a stub
# in a temp PATH dir, so no real container is ever listed or removed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
export STUB_DIR="$bin_dir"

old_finished="2020-01-01T00:00:00.000000000Z"   # always far past any threshold
recent_finished="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%S.000000000Z)"

cat > "$bin_dir/docker" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" info "*) exit 0 ;;
  *" ps -a --filter status=exited "*)
    printf 'oldcid000111\tleftover-app\nrecentcid222\tjust-stopped\n'
    ;;
  *" inspect "*)
    case "\$*" in
      *oldcid000111*) echo "$old_finished" ;;
      *recentcid222*) echo "$recent_finished" ;;
      *) exit 1 ;;
    esac
    ;;
  *" rm "*)
    echo "docker \$*" >> "\$STUB_DIR/calls.log"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/docker-stopped-containers.sh"

echo "== dry run: only the long-exited container is proposed =="
out="$(PATH="$bin_dir:$PATH" INSPECTOR_DRY_RUN=1 "$check")"
assert_true "would-delete for leftover-app" \
  "$(grep -q '"action":"would-delete"' <<<"$out" && grep -q 'leftover-app' <<<"$out" && echo true || echo false)"
assert_true "just-stopped (1h) is not proposed" \
  "$(grep -q 'just-stopped' <<<"$out" && echo false || echo true)"
assert_true "dry run issued no docker rm" \
  "$([ ! -f "$bin_dir/calls.log" ] && echo true || echo false)"

echo "== real run: only the long-exited container is removed =="
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "deleted line for leftover-app" \
  "$(grep -q '"action":"deleted"' <<<"$out" && grep -q 'leftover-app' <<<"$out" && echo true || echo false)"
assert_true "docker rm called for oldcid000111 and nothing else" \
  "$(grep -q 'docker rm oldcid000111' "$bin_dir/calls.log" && [ "$(grep -c 'docker rm' "$bin_dir/calls.log")" = "1" ] && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
```

- [ ] **Step 5: `chmod +x` and run**

```bash
chmod +x vps_oracle/inspector/tests/test-docker-stopped-containers.sh
cd vps_oracle/inspector && ./tests/test-docker-stopped-containers.sh
```
Expected: all `ok -`, final `PASS`, exit 0.

- [ ] **Step 6: Dry-run against real host state**

```bash
cd vps_oracle/inspector && INSPECTOR_DRY_RUN=1 ./checks/docker-stopped-containers.sh
```
Expected: exits 0, **no output** (host currently has 0 exited containers — verified 2026-08-16). Any output must be eyeballed against `docker ps -a` before proceeding.

- [ ] **Step 7: Commit**

```bash
git status --short
git add vps_oracle/inspector/tests/lib.sh \
        vps_oracle/inspector/checks/docker-stopped-containers.sh \
        vps_oracle/inspector/tests/test-docker-stopped-containers.sh
git commit -m "Add docker-stopped-containers check and shared test helpers"
```

---

### Task 3: `checks/docker-dangling-images.sh`

**Files:**
- Create: `vps_oracle/inspector/checks/docker-dangling-images.sh`
- Create: `vps_oracle/inspector/tests/test-docker-dangling-images.sh`

**Interfaces:**
- Consumes: `emit_result`; `tests/lib.sh`
- Overridable env vars: `INSPECTOR_DANGLING_IMAGE_MAX_AGE_SECONDS` (default 604800)

- [ ] **Step 1: Write `checks/docker-dangling-images.sh`**

```bash
#!/usr/bin/env bash
# checks/docker-dangling-images.sh
#
# Removes dangling (untagged, unreferenced) images created more than
# INSPECTOR_DANGLING_IMAGE_MAX_AGE_SECONDS ago (default 7 days). Design
# spec's "Docker dangling image" row (auto tier). Per-image `docker rmi`
# of enumerated candidates instead of blanket `docker image prune`:
# prune has no per-image report and would ignore the age threshold.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

MAX_AGE_SECONDS="${INSPECTOR_DANGLING_IMAGE_MAX_AGE_SECONDS:-604800}"

docker info >/dev/null 2>&1 || {
  emit_result "alert" "flagged" "check:docker-dangling-images.sh" \
    "docker daemon unreachable — check skipped"
  exit 0
}

now_epoch="$(date +%s)"

mapfile -t ids < <(docker images --filter dangling=true --format '{{.ID}}' 2>/dev/null)
[ "${#ids[@]}" -eq 0 ] && exit 0

for id in "${ids[@]}"; do
  [ -n "$id" ] || continue
  created="$(docker image inspect --format '{{.Created}}' "$id" 2>/dev/null)" || continue
  created_epoch="$(date -d "$created" +%s 2>/dev/null)" || continue
  age=$((now_epoch - created_epoch))
  [ "$age" -ge "$MAX_AGE_SECONDS" ] || continue

  if [ "${INSPECTOR_DRY_RUN:-0}" = "1" ]; then
    emit_result "auto" "would-delete" "docker image $id" \
      "dangling, created ${age}s ago (threshold ${MAX_AGE_SECONDS}s)"
  elif docker rmi "$id" >/dev/null 2>&1; then
    emit_result "auto" "deleted" "docker image $id" \
      "dangling, created ${age}s ago (threshold ${MAX_AGE_SECONDS}s)"
  else
    emit_result "alert" "flagged" "docker image $id" \
      "docker rmi failed (dangling, created ${age}s ago) — manual investigation needed"
  fi
done
```

- [ ] **Step 2: `chmod` and syntax-check**

```bash
chmod +x vps_oracle/inspector/checks/docker-dangling-images.sh
bash -n vps_oracle/inspector/checks/docker-dangling-images.sh
```

- [ ] **Step 3: Write `tests/test-docker-dangling-images.sh`**

```bash
#!/usr/bin/env bash
# tests/test-docker-dangling-images.sh — hermetic docker stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
export STUB_DIR="$bin_dir"

old_created="2020-01-01T00:00:00.000000000Z"
recent_created="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%S.000000000Z)"

cat > "$bin_dir/docker" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" info "*) exit 0 ;;
  *" images --filter dangling=true "*)
    printf 'imgold111222\nimgnew333444\n'
    ;;
  *" image inspect "*)
    case "\$*" in
      *imgold111222*) echo "$old_created" ;;
      *imgnew333444*) echo "$recent_created" ;;
      *) exit 1 ;;
    esac
    ;;
  *" rmi "*)
    echo "docker \$*" >> "\$STUB_DIR/calls.log"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/docker-dangling-images.sh"

echo "== dry run: only the old dangling image is proposed =="
out="$(PATH="$bin_dir:$PATH" INSPECTOR_DRY_RUN=1 "$check")"
assert_true "would-delete for imgold111222" \
  "$(grep -q 'would-delete' <<<"$out" && grep -q 'imgold111222' <<<"$out" && echo true || echo false)"
assert_true "recent dangling image is not proposed" \
  "$(grep -q 'imgnew333444' <<<"$out" && echo false || echo true)"
assert_true "dry run issued no docker rmi" \
  "$([ ! -f "$bin_dir/calls.log" ] && echo true || echo false)"

echo "== real run: only the old dangling image is removed =="
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "deleted line for imgold111222" \
  "$(grep -q '"action":"deleted"' <<<"$out" && grep -q 'imgold111222' <<<"$out" && echo true || echo false)"
assert_true "docker rmi called for imgold111222 and nothing else" \
  "$(grep -q 'docker rmi imgold111222' "$bin_dir/calls.log" && [ "$(grep -c 'docker rmi' "$bin_dir/calls.log")" = "1" ] && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
```

- [ ] **Step 4: `chmod +x` and run**

```bash
chmod +x vps_oracle/inspector/tests/test-docker-dangling-images.sh
cd vps_oracle/inspector && ./tests/test-docker-dangling-images.sh
```
Expected: all `ok -`, final `PASS`, exit 0.

- [ ] **Step 5: Dry-run against real host state**

```bash
cd vps_oracle/inspector && INSPECTOR_DRY_RUN=1 ./checks/docker-dangling-images.sh
```
Expected: exits 0, **no output** (0 dangling images on host, verified 2026-08-16).

- [ ] **Step 6: Commit**

```bash
git status --short
git add vps_oracle/inspector/checks/docker-dangling-images.sh \
        vps_oracle/inspector/tests/test-docker-dangling-images.sh
git commit -m "Add docker-dangling-images check with age threshold"
```

---

### Task 4: `checks/docker-build-cache.sh`

**Files:**
- Create: `vps_oracle/inspector/checks/docker-build-cache.sh`
- Create: `vps_oracle/inspector/tests/test-docker-build-cache.sh`

**Interfaces:**
- Consumes: `emit_result`; `tests/lib.sh`
- Overridable env vars: `INSPECTOR_BUILD_CACHE_MAX_AGE_SECONDS` (default 604800)

- [ ] **Step 1: Write `checks/docker-build-cache.sh`**

```bash
#!/usr/bin/env bash
# checks/docker-build-cache.sh
#
# Prunes docker build cache older than
# INSPECTOR_BUILD_CACHE_MAX_AGE_SECONDS (default 7 days). Design spec's
# "Docker build cache" row (auto tier). Unlike the other checks this one
# cannot enumerate candidates per-entry for a would-delete list: builder
# records have no stable per-entry CLI listing, so dry-run reports the
# would-run command plus the current total instead, and the real run
# reports what prune reclaimed. Host currently has 0B build cache, so
# the common case is silence.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

MAX_AGE_SECONDS="${INSPECTOR_BUILD_CACHE_MAX_AGE_SECONDS:-604800}"

docker info >/dev/null 2>&1 || {
  emit_result "alert" "flagged" "check:docker-build-cache.sh" \
    "docker daemon unreachable — check skipped"
  exit 0
}

total="$(docker builder du 2>/dev/null | awk '/^Total:/ {print $2}')"
[ -n "$total" ] || exit 0
[ "$total" = "0B" ] && exit 0

if [ "${INSPECTOR_DRY_RUN:-0}" = "1" ]; then
  emit_result "auto" "would-delete" "docker build cache" \
    "would run: docker builder prune -f --filter until=${MAX_AGE_SECONDS}s (current total ${total})"
elif output="$(docker builder prune -f --filter "until=${MAX_AGE_SECONDS}s" 2>/dev/null)"; then
  reclaimed="$(awk '/^Total reclaimed space:/ {print $NF}' <<<"$output")"
  emit_result "auto" "deleted" "docker build cache" \
    "pruned cache records older than ${MAX_AGE_SECONDS}s, reclaimed ${reclaimed:-unknown} of ${total}"
else
  emit_result "alert" "flagged" "docker build cache" \
    "docker builder prune failed — manual investigation needed (total was ${total})"
fi
```

- [ ] **Step 2: `chmod` and syntax-check**

```bash
chmod +x vps_oracle/inspector/checks/docker-build-cache.sh
bash -n vps_oracle/inspector/checks/docker-build-cache.sh
```

- [ ] **Step 3: Write `tests/test-docker-build-cache.sh`**

```bash
#!/usr/bin/env bash
# tests/test-docker-build-cache.sh — hermetic docker stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
export STUB_DIR="$bin_dir"

cat > "$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" info "*) exit 0 ;;
  *" builder du "*)
    printf 'ID                 RECLAIMABLE     SIZE\nabc                true            1.2GB\nTotal:\t\t1.2GB\n'
    ;;
  *" builder prune "*)
    echo "docker $*" >> "$STUB_DIR/calls.log"
    echo '3 cache entries deleted'
    echo 'Total reclaimed space: 1.1GB'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/docker-build-cache.sh"

echo "== dry run: reports the would-run prune, runs nothing =="
out="$(PATH="$bin_dir:$PATH" INSPECTOR_DRY_RUN=1 "$check")"
assert_true "would-delete line mentions current total 1.2GB" \
  "$(grep -q 'would-delete' <<<"$out" && grep -q '1.2GB' <<<"$out" && echo true || echo false)"
assert_true "would-run line contains the until filter" \
  "$(grep -q "until=604800s" <<<"$out" && echo true || echo false)"
assert_true "dry run issued no docker builder prune" \
  "$([ ! -f "$bin_dir/calls.log" ] && echo true || echo false)"

echo "== real run: prune invoked once, reclaimed size reported =="
rm -f "$bin_dir/calls.log"
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "deleted line reports reclaimed 1.1GB" \
  "$(grep -q '"action":"deleted"' <<<"$out" && grep -q '1.1GB' <<<"$out" && echo true || echo false)"
assert_true "prune carried the until filter" \
  "$(grep -q -- '--filter until=604800s' "$bin_dir/calls.log" && echo true || echo false)"
assert_true "docker builder prune called exactly once" \
  "$([ "$(grep -c 'builder prune' "$bin_dir/calls.log")" = "1" ] && echo true || echo false)"

echo "== zero cache case: docker builder du reports 0B, check is silent =="
cat > "$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" info "*) exit 0 ;;
  *" builder du "*) printf 'Total:\t0B\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"
out="$(PATH="$bin_dir:$PATH" INSPECTOR_DRY_RUN=1 "$check")"
assert_true "no output when build cache is empty" \
  "$([ -z "$out" ] && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
```

- [ ] **Step 4: `chmod +x` and run**

```bash
chmod +x vps_oracle/inspector/tests/test-docker-build-cache.sh
cd vps_oracle/inspector && ./tests/test-docker-build-cache.sh
```
Expected: all `ok -`, final `PASS`, exit 0.

- [ ] **Step 5: Dry-run against real host state**

```bash
cd vps_oracle/inspector && INSPECTOR_DRY_RUN=1 ./checks/docker-build-cache.sh
```
Expected: exits 0, **no output** (build cache Total is 0B on host, verified 2026-08-16).

- [ ] **Step 6: Commit**

```bash
git status --short
git add vps_oracle/inspector/checks/docker-build-cache.sh \
        vps_oracle/inspector/tests/test-docker-build-cache.sh
git commit -m "Add docker-build-cache check"
```

---

### Task 5: `checks/docker-unused-networks.sh`

**Files:**
- Create: `vps_oracle/inspector/checks/docker-unused-networks.sh`
- Create: `vps_oracle/inspector/tests/test-docker-unused-networks.sh`

**Interfaces:**
- Consumes: `emit_result`; `tests/lib.sh`
- Overridable env vars: none (spec defines no threshold — "無容器掛載的自訂 network" is the whole condition)

- [ ] **Step 1: Write `checks/docker-unused-networks.sh`**

```bash
#!/usr/bin/env bash
# checks/docker-unused-networks.sh
#
# Removes custom docker networks with zero containers attached. Design
# spec's "Docker 未用 network" row (auto tier, no age threshold —
# re-creating a network costs nothing). `--filter type=custom` already
# excludes the predefined bridge/host/none, so per-network `docker
# network rm` of the enumerated candidates is exactly `docker network
# prune` semantics but with per-target reporting.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

docker info >/dev/null 2>&1 || {
  emit_result "alert" "flagged" "check:docker-unused-networks.sh" \
    "docker daemon unreachable — check skipped"
  exit 0
}

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
```

- [ ] **Step 2: `chmod` and syntax-check**

```bash
chmod +x vps_oracle/inspector/checks/docker-unused-networks.sh
bash -n vps_oracle/inspector/checks/docker-unused-networks.sh
```

- [ ] **Step 3: Write `tests/test-docker-unused-networks.sh`**

```bash
#!/usr/bin/env bash
# tests/test-docker-unused-networks.sh — hermetic docker stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
export STUB_DIR="$bin_dir"

cat > "$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" info "*) exit 0 ;;
  *" network ls --filter type=custom "*)
    printf 'usednet\norphanet\n'
    ;;
  *" network inspect "*)
    case "$*" in
      *usednet*) echo 1 ;;
      *orphanet*) echo 0 ;;
      *) exit 1 ;;
    esac
    ;;
  *" network rm "*)
    echo "docker $*" >> "$STUB_DIR/calls.log"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/docker-unused-networks.sh"

echo "== dry run: only the unattached network is proposed =="
out="$(PATH="$bin_dir:$PATH" INSPECTOR_DRY_RUN=1 "$check")"
assert_true "would-delete for orphanet" \
  "$(grep -q 'would-delete' <<<"$out" && grep -q 'orphanet' <<<"$out" && echo true || echo false)"
assert_true "usednet is not proposed" \
  "$(grep -q 'usednet' <<<"$out" && echo false || echo true)"
assert_true "dry run issued no docker network rm" \
  "$([ ! -f "$bin_dir/calls.log" ] && echo true || echo false)"

echo "== real run: only the unattached network is removed =="
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "deleted line for orphanet" \
  "$(grep -q '"action":"deleted"' <<<"$out" && grep -q 'orphanet' <<<"$out" && echo true || echo false)"
assert_true "docker network rm called for orphanet and nothing else" \
  "$(grep -q 'docker network rm orphanet' "$bin_dir/calls.log" && [ "$(grep -c 'network rm' "$bin_dir/calls.log")" = "1" ] && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
```

- [ ] **Step 4: `chmod +x` and run**

```bash
chmod +x vps_oracle/inspector/tests/test-docker-unused-networks.sh
cd vps_oracle/inspector && ./tests/test-docker-unused-networks.sh
```
Expected: all `ok -`, final `PASS`, exit 0.

- [ ] **Step 5: Dry-run against real host state**

```bash
cd vps_oracle/inspector && INSPECTOR_DRY_RUN=1 ./checks/docker-unused-networks.sh
```
Expected: exits 0, **no output** (all three custom networks — `3x-ui_default`, `monitoring_default`, `proxy` — have containers attached, verified 2026-08-16).

- [ ] **Step 6: Commit**

```bash
git status --short
git add vps_oracle/inspector/checks/docker-unused-networks.sh \
        vps_oracle/inspector/tests/test-docker-unused-networks.sh
git commit -m "Add docker-unused-networks check"
```

---

### Task 6: `checks/docker-restart-storms.sh` (alert only)

**Files:**
- Create: `vps_oracle/inspector/checks/docker-restart-storms.sh`
- Create: `vps_oracle/inspector/tests/test-docker-restart-storms.sh`

**Interfaces:**
- Consumes: `emit_result`; `tests/lib.sh`
- Overridable env vars: `INSPECTOR_RESTART_STORM_COUNT` (default 10)

- [ ] **Step 1: Write `checks/docker-restart-storms.sh`**

```bash
#!/usr/bin/env bash
# checks/docker-restart-storms.sh
#
# Flags containers whose RestartCount is异常 high or whose state is
# stuck in `restarting`. Design spec's "Docker 重啟風暴" row (ALERT
# ONLY — auto-restart can mask a config error; surfacing it is the
# point, resolving it is not the inspector's job).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

STORM_COUNT="${INSPECTOR_RESTART_STORM_COUNT:-10}"

docker info >/dev/null 2>&1 || {
  emit_result "alert" "flagged" "check:docker-restart-storms.sh" \
    "docker daemon unreachable — check skipped"
  exit 0
}

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
```

- [ ] **Step 2: `chmod` and syntax-check**

```bash
chmod +x vps_oracle/inspector/checks/docker-restart-storms.sh
bash -n vps_oracle/inspector/checks/docker-restart-storms.sh
```

- [ ] **Step 3: Write `tests/test-docker-restart-storms.sh`**

```bash
#!/usr/bin/env bash
# tests/test-docker-restart-storms.sh — hermetic docker stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"

cat > "$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" info "*) exit 0 ;;
  *" ps -aq "*)
    printf 'id1\nid2\nid3\n'
    ;;
  *" inspect "*)
    case "$*" in
      *id1*) echo "/stormy 12 running" ;;
      *id2*) echo "/flappy 0 restarting" ;;
      *id3*) echo "/calm 2 running" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/docker-restart-storms.sh"

echo "== stormy (count 12) and flappy (restarting) alert; calm does not =="
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "alert line for stormy via restart count" \
  "$(grep -q '"tier":"alert"' <<<"$out" && grep -q 'stormy' <<<"$out" && echo true || echo false)"
assert_true "alert line for flappy via restarting state" \
  "$(grep -q 'flappy' <<<"$out" && echo true || echo false)"
assert_true "calm (count 2) is not flagged" \
  "$(grep -q 'calm' <<<"$out" && echo false || echo true)"
assert_true "exactly two alert lines" \
  "$([ "$(grep -c '"tier":"alert"' <<<"$out")" = "2" ] && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
```

- [ ] **Step 4: `chmod +x` and run**

```bash
chmod +x vps_oracle/inspector/tests/test-docker-restart-storms.sh
cd vps_oracle/inspector && ./tests/test-docker-restart-storms.sh
```
Expected: all `ok -`, final `PASS`, exit 0.

- [ ] **Step 5: Run against real host state** (alert-tier check — dry-run env is irrelevant, it never acts)

```bash
cd vps_oracle/inspector && ./checks/docker-restart-storms.sh
```
Expected: exits 0, **no output** (all 10 containers Up with RestartCount 0, verified 2026-08-16).

- [ ] **Step 6: Commit**

```bash
git status --short
git add vps_oracle/inspector/checks/docker-restart-storms.sh \
        vps_oracle/inspector/tests/test-docker-restart-storms.sh
git commit -m "Add docker-restart-storms alert check"
```

---

### Task 7: `checks/docker-unused-volumes.sh` (alert only)

**Files:**
- Create: `vps_oracle/inspector/checks/docker-unused-volumes.sh`
- Create: `vps_oracle/inspector/tests/test-docker-unused-volumes.sh`

**Interfaces:**
- Consumes: `emit_result`; `tests/lib.sh`
- Overridable env vars: none (existence is the condition; misjudgment cost is asymmetric — that's why it's alert-tier)

Reporting note: this host has ~47 dangling **anonymous** volumes right now. Listing each as its own Telegram line would drown the report, so anonymous volumes collapse into one summary line; **named** volumes (the ones a human plausibly created on purpose) each get their own line — that's the split that matches where review effort matters.

- [ ] **Step 1: Write `checks/docker-unused-volumes.sh`**

```bash
#!/usr/bin/env bash
# checks/docker-unused-volumes.sh
#
# Flags volumes not referenced by any container (docker's dangling
# filter). Design spec's "Docker 未用 volume" row (ALERT ONLY — a volume
# may hold the only copy of data; the cost of a wrong removal is
# asymmetric). Anonymous volumes (64-hex names, created implicitly by
# compose recreation) are aggregated into one summary line; named
# volumes get one line each.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

docker info >/dev/null 2>&1 || {
  emit_result "alert" "flagged" "check:docker-unused-volumes.sh" \
    "docker daemon unreachable — check skipped"
  exit 0
}

mapfile -t vols < <(docker volume ls --filter dangling=true --format '{{.Name}}' 2>/dev/null)
[ "${#vols[@]}" -eq 0 ] && exit 0

anonymous_count=0
named=()
for v in "${vols[@]}"; do
  [ -n "$v" ] || continue
  if [[ "$v" =~ ^[0-9a-f]{64}$ ]]; then
    anonymous_count=$((anonymous_count + 1))
  else
    named+=("$v")
  fi
done

if [ "$anonymous_count" -gt 0 ]; then
  emit_result "alert" "flagged" "docker anonymous volumes x${anonymous_count}" \
    "not mounted by any container (leftovers from compose recreation; review with 'docker volume inspect' / 'docker system df -v' before removing)"
fi

for n in "${named[@]:-}"; do
  [ -n "$n" ] || continue
  emit_result "alert" "flagged" "docker volume $n" \
    "named volume not mounted by any container — may hold data, manual review needed"
done
```

- [ ] **Step 2: `chmod` and syntax-check**

```bash
chmod +x vps_oracle/inspector/checks/docker-unused-volumes.sh
bash -n vps_oracle/inspector/checks/docker-unused-volumes.sh
```

- [ ] **Step 3: Write `tests/test-docker-unused-volumes.sh`**

```bash
#!/usr/bin/env bash
# tests/test-docker-unused-volumes.sh — hermetic docker stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"

cat > "$bin_dir/docker" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" info "*) exit 0 ;;
  *" volume ls --filter dangling=true "*)
    printf '%s\n%s\n%s\n%s\n' \\
      "$(printf 'a%.0s' {1..64})" \\
      "$(printf 'b%.0s' {1..64})" \\
      "$(printf 'c%.0s' {1..64})" \\
      "old-project-data"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/docker-unused-volumes.sh"

echo "== anonymous volumes aggregate, named volumes list individually =="
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "one aggregate line for 3 anonymous volumes" \
  "$(grep -q 'anonymous volumes x3' <<<"$out" && echo true || echo false)"
assert_true "individual line for named volume old-project-data" \
  "$(grep -q '"target":"docker volume old-project-data"' <<<"$out" && echo true || echo false)"
assert_true "exactly two alert lines" \
  "$([ "$(grep -c '"tier":"alert"' <<<"$out")" = "2" ] && echo true || echo false)"
assert_true "no raw anonymous hash appears in the report" \
  "$(grep -q 'aaaaaaaa' <<<"$out" && echo false || echo true)"

rm -rf "$work_dir"
finish_tests
```

- [ ] **Step 4: `chmod +x` and run**

```bash
chmod +x vps_oracle/inspector/tests/test-docker-unused-volumes.sh
cd vps_oracle/inspector && ./tests/test-docker-unused-volumes.sh
```
Expected: all `ok -`, final `PASS`, exit 0.

- [ ] **Step 5: Run against real host state** (alert-tier, never acts)

```bash
cd vps_oracle/inspector && ./checks/docker-unused-volumes.sh
```
Expected: exits 0 with **real output** — one `anonymous volumes x~47` aggregate line plus up to 3 named-volume lines (50 dangling volumes verified on host 2026-08-16). Eyeball the named ones: they are genuinely unmounted but may be intentional. This is expected first-run noise, not a bug.

- [ ] **Step 6: Commit**

```bash
git status --short
git add vps_oracle/inspector/checks/docker-unused-volumes.sh \
        vps_oracle/inspector/tests/test-docker-unused-volumes.sh
git commit -m "Add docker-unused-volumes alert check"
```

---

### Task 8: `checks/docker-compose-logging-drift.sh` (alert only)

**Files:**
- Create: `vps_oracle/inspector/checks/docker-compose-logging-drift.sh`
- Create: `vps_oracle/inspector/tests/test-docker-compose-logging-drift.sh`

**Interfaces:**
- Consumes: `emit_result`; `INSPECTOR_ROOT` from `lib/common.sh`; `docker compose config` (the repo has no `yq`; docker itself is already the dependency everywhere else)
- Overridable env vars: `INSPECTOR_REPO_ROOT` (default: two levels above `INSPECTOR_ROOT`, i.e. the docker-gitops checkout root)

- [ ] **Step 1: Write `checks/docker-compose-logging-drift.sh`**

```bash
#!/usr/bin/env bash
# checks/docker-compose-logging-drift.sh
#
# Scans <repo>/<host>/compose/*/docker-compose.yml and flags services
# missing logging.options.max-size. Design spec's "compose 檔 logging
# 配置漂移" row (ALERT ONLY — the inspector never edits compose files).
# Parses with `docker compose config --no-interpolate --format json`
# instead of grep/awk: the repo has no yq, and docker already parses
# this exact file format everywhere else. --no-interpolate keeps
# ${VAR} literals valid without the stack's .env present.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

REPO_ROOT="${INSPECTOR_REPO_ROOT:-$(cd "$INSPECTOR_ROOT/../.." && pwd)}"

shopt -s nullglob
files=("$REPO_ROOT"/*/compose/*/docker-compose.yml)
[ "${#files[@]}" -eq 0 ] && exit 0

for file in "${files[@]}"; do
  relpath="${file#"$REPO_ROOT"/}"
  json="$(docker compose -f "$file" config --no-interpolate --format json 2>/dev/null)" || {
    emit_result "alert" "flagged" "$relpath" \
      "docker compose config failed — file could not be parsed, manual review needed"
    continue
  }

  while read -r svc; do
    [ -n "$svc" ] || continue
    max_size="$(jq -r --arg s "$svc" '.services[$s].logging.options["max-size"] // empty' <<<"$json")"
    if [ -z "$max_size" ]; then
      emit_result "alert" "flagged" "$relpath:$svc" \
        "service has no logging.options.max-size (repo convention: max-size 10m, see root README 日志大小限制)"
    fi
  done < <(jq -r '.services | keys[]' <<<"$json")
done
```

- [ ] **Step 2: `chmod` and syntax-check**

```bash
chmod +x vps_oracle/inspector/checks/docker-compose-logging-drift.sh
bash -n vps_oracle/inspector/checks/docker-compose-logging-drift.sh
```

- [ ] **Step 3: Write `tests/test-docker-compose-logging-drift.sh`**

```bash
#!/usr/bin/env bash
# tests/test-docker-compose-logging-drift.sh — hermetic: fixture repo
# tree with two compose files, docker stub serves canned `compose
# config` JSON per file path.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir" \
  "$work_dir/hosta/compose/good" "$work_dir/hostb/compose/bad"
echo "services:" > "$work_dir/hosta/compose/good/docker-compose.yml"   # content unused; stub serves JSON
echo "services:" > "$work_dir/hostb/compose/bad/docker-compose.yml"

good_json="$work_dir/good.json"
bad_json="$work_dir/bad.json"
cat > "$good_json" <<'EOF'
{"services":{"with-limits":{"image":"x","logging":{"driver":"json-file","options":{"max-size":"10m","max-file":"5"}}}}}
EOF
cat > "$bad_json" <<'EOF'
{"services":{"fine":{"image":"x","logging":{"driver":"json-file","options":{"max-size":"10m"}}},"no-logging":{"image":"x"},"wrong-logging":{"image":"x","logging":{"driver":"json-file"}}}}
EOF

cat > "$bin_dir/docker" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" info "*) exit 0 ;;
  *" compose "*)
    case "\$*" in
      *good/docker-compose.yml*) cat "$good_json" ;;
      *bad/docker-compose.yml*)  cat "$bad_json" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/docker-compose-logging-drift.sh"

out="$(PATH="$bin_dir:$PATH" INSPECTOR_REPO_ROOT="$work_dir" "$check")"
assert_true "flags the service with no logging block" \
  "$(grep -q '"target":"hostb/compose/bad/docker-compose.yml:no-logging"' <<<"$out" && echo true || echo false)"
assert_true "flags the service with logging but no max-size" \
  "$(grep -q 'wrong-logging' <<<"$out" && echo true || echo false)"
assert_true "conformant service in the same file is not flagged" \
  "$(grep -q ':fine"' <<<"$out" && echo false || echo true)"
assert_true "fully conformant stack produces no line" \
  "$(grep -q 'hosta' <<<"$out" && echo false || echo true)"

rm -rf "$work_dir"
finish_tests
```

- [ ] **Step 4: `chmod +x` and run**

```bash
chmod +x vps_oracle/inspector/tests/test-docker-compose-logging-drift.sh
cd vps_oracle/inspector && ./tests/test-docker-compose-logging-drift.sh
```
Expected: all `ok -`, final `PASS`, exit 0.

- [ ] **Step 5: Run against real repo state** (alert-tier, never acts)

```bash
cd vps_oracle/inspector && ./checks/docker-compose-logging-drift.sh
```
Expected: exits 0; likely no output (all 7 compose files declare logging — spot-verified 2026-08-16, but this check is what proves it *per service* for the first time). Any line it prints is a real drift finding; report it to the user in the task summary.

- [ ] **Step 6: Commit**

```bash
git status --short
git add vps_oracle/inspector/checks/docker-compose-logging-drift.sh \
        vps_oracle/inspector/tests/test-docker-compose-logging-drift.sh
git commit -m "Add docker-compose-logging-drift alert check"
```

---

### Task 9: `checks/docker-oversized-logs.sh` (alert only)

**Files:**
- Create: `vps_oracle/inspector/checks/docker-oversized-logs.sh`
- Create: `vps_oracle/inspector/tests/test-docker-oversized-logs.sh`

**Interfaces:**
- Consumes: `emit_result`; `tests/lib.sh`; passwordless `sudo -n` for `/var/lib/docker/containers` (root-only, verified)
- Overridable env vars: `INSPECTOR_LOG_ALERT_BYTES` (default 52428800 = 50MiB — repo convention caps logs at 10m×5 files, so a single json log over 50MiB means limits are not effective)

- [ ] **Step 1: Write `checks/docker-oversized-logs.sh`**

```bash
#!/usr/bin/env bash
# checks/docker-oversized-logs.sh
#
# Flags container json log files whose actual size exceeds
# INSPECTOR_LOG_ALERT_BYTES (default 50MiB). Design spec's "容器日誌檔
# 異常大" row (ALERT ONLY — an oversized log usually means the logging
# config did not take effect, which needs a human to investigate, not a
# truncate). /var/lib/docker/containers is root-only, so this is one of
# the two spec-sanctioned narrowly-scoped sudo uses (the other is
# crictl in k3s-containerd-images.sh). Threshold comparison happens in
# bash, not in find's -size, so tests can exercise it with a stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

THRESHOLD_BYTES="${INSPECTOR_LOG_ALERT_BYTES:-52428800}"

docker info >/dev/null 2>&1 || {
  emit_result "alert" "flagged" "check:docker-oversized-logs.sh" \
    "docker daemon unreachable — check skipped"
  exit 0
}

sudo -n true 2>/dev/null || {
  emit_result "alert" "flagged" "check:docker-oversized-logs.sh" \
    "passwordless sudo unavailable — cannot read /var/lib/docker, check skipped"
  exit 0
}

# Map container id -> name so the report names containers, not hashes.
declare -A id_to_name
while read -r id name; do
  [ -n "$id" ] && id_to_name["$id"]="$name"
done < <(docker ps -a --no-trunc --format '{{.ID}} {{.Names}}' 2>/dev/null)

while read -r size path; do
  [ -n "$size" ] || continue
  [ "$size" -gt "$THRESHOLD_BYTES" ] || continue
  cid="$(basename "$(dirname "$path")")"   # .../containers/<id>/<id>-json.log
  emit_result "alert" "flagged" "docker container ${id_to_name[$cid]:-$cid}" \
    "json log file is ${size} bytes, over ${THRESHOLD_BYTES} threshold — logging limits possibly not effective: $path"
done < <(sudo -n find /var/lib/docker/containers -name '*-json.log' -printf '%s %p\n' 2>/dev/null)
```

- [ ] **Step 2: `chmod` and syntax-check**

```bash
chmod +x vps_oracle/inspector/checks/docker-oversized-logs.sh
bash -n vps_oracle/inspector/checks/docker-oversized-logs.sh
```

- [ ] **Step 3: Write `tests/test-docker-oversized-logs.sh`**

```bash
#!/usr/bin/env bash
# tests/test-docker-oversized-logs.sh — hermetic: sudo and find are
# both stubbed (sudo passes through to same-dir stubs, mirroring the
# real thing running as root).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"

cat > "$bin_dir/sudo" <<'EOF'
#!/usr/bin/env bash
# fake sudo: drop a "-n" if present, execute the rest from PATH (i.e.
# the stub find in this same dir)
[ "${1:-}" = "-n" ] && shift
exec "$@"
EOF
cat > "$bin_dir/find" <<'EOF'
#!/usr/bin/env bash
echo "60000000 /var/lib/docker/containers/aaaa1111bbbb/aaaa1111bbbb-json.log"
echo "2000000 /var/lib/docker/containers/cccc3333dddd/cccc3333dddd-json.log"
EOF
cat > "$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" info "*) exit 0 ;;
  *" ps -a --no-trunc "*)
    printf 'aaaa1111bbbb chatty-app\ncccc3333dddd quiet-app\n'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/sudo" "$bin_dir/find" "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/docker-oversized-logs.sh"

echo "== default 50MiB threshold: only the 60MB log alerts, named by container =="
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "alert names chatty-app, not the hash" \
  "$(grep -q '"target":"docker container chatty-app"' <<<"$out" && echo true || echo false)"
assert_true "alert carries the actual size" \
  "$(grep -q '60000000 bytes' <<<"$out" && echo true || echo false)"
assert_true "quiet-app (2MB) is not flagged" \
  "$(grep -q 'quiet-app' <<<"$out" && echo false || echo true)"
assert_true "exactly one alert line" \
  "$([ "$(grep -c '"tier":"alert"' <<<"$out")" = "1" ] && echo true || echo false)"

echo "== raised threshold suppresses the alert =="
out="$(PATH="$bin_dir:$PATH" INSPECTOR_LOG_ALERT_BYTES=99999999 "$check")"
assert_true "no output when threshold exceeds all logs" \
  "$([ -z "$out" ] && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
```

- [ ] **Step 4: `chmod +x` and run**

```bash
chmod +x vps_oracle/inspector/tests/test-docker-oversized-logs.sh
cd vps_oracle/inspector && ./tests/test-docker-oversized-logs.sh
```
Expected: all `ok -`, final `PASS`, exit 0.

- [ ] **Step 5: Run against real host state** (alert-tier, never acts; exercises real sudo)

```bash
cd vps_oracle/inspector && ./checks/docker-oversized-logs.sh
```
Expected: exits 0, **no output** (all stacks declare max-size 10m; `du` spot-check during planning saw nothing oversized).

- [ ] **Step 6: Commit**

```bash
git status --short
git add vps_oracle/inspector/checks/docker-oversized-logs.sh \
        vps_oracle/inspector/tests/test-docker-oversized-logs.sh
git commit -m "Add docker-oversized-logs alert check"
```

---

### Task 10: `checks/k3s-evicted-pods.sh`

**Files:**
- Create: `vps_oracle/inspector/checks/k3s-evicted-pods.sh`
- Create: `vps_oracle/inspector/tests/test-k3s-evicted-pods.sh`

**Interfaces:**
- Consumes: `emit_result`; `INSPECTOR_STATE_DIR`; kubeconfig from Task 1 via `INSPECTOR_KUBECONFIG` (default `$INSPECTOR_STATE_DIR/kubeconfig`)
- Overridable env vars: `INSPECTOR_KUBECONFIG`

- [ ] **Step 1: Write `checks/k3s-evicted-pods.sh`**

```bash
#!/usr/bin/env bash
# checks/k3s-evicted-pods.sh
#
# Deletes leftover pods in Failed phase (Evicted/Error/etc.). Design
# spec's "k3s Evicted/Failed pod" row (auto tier — deleting terminal
# Failed pods is standard k8s hygiene; their controllers recreate
# anything that should exist). No age threshold: a Failed pod is
# already terminal.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

KUBECONFIG_FILE="${INSPECTOR_KUBECONFIG:-$INSPECTOR_STATE_DIR/kubeconfig}"

if [ ! -f "$KUBECONFIG_FILE" ]; then
  emit_result "alert" "flagged" "check:k3s-evicted-pods.sh" \
    "inspector kubeconfig missing at $KUBECONFIG_FILE — run k3s/setup-kubeconfig.sh once (see README)"
  exit 0
fi

kc() { kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"; }

pods_json="$(kc get pods -A --field-selector=status.phase=Failed -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:k3s-evicted-pods.sh" \
    "kubernetes API not reachable via inspector kubeconfig — check skipped"
  exit 0
}

[ "$(jq '.items | length' <<<"$pods_json")" -gt 0 ] || exit 0

while read -r line; do
  [ -n "$line" ] || continue
  ns="$(jq -r '.ns' <<<"$line")"
  name="$(jq -r '.name' <<<"$line")"
  reason="$(jq -r '.reason' <<<"$line")"

  if [ "${INSPECTOR_DRY_RUN:-0}" = "1" ]; then
    emit_result "auto" "would-delete" "pod $ns/$name" "phase=Failed reason=$reason"
  elif kc delete pod -n "$ns" "$name" >/dev/null 2>&1; then
    emit_result "auto" "deleted" "pod $ns/$name" "phase=Failed reason=$reason"
  else
    emit_result "alert" "flagged" "pod $ns/$name" \
      "kubectl delete failed (phase=Failed reason=$reason) — manual investigation needed"
  fi
done < <(jq -c '.items[] | {ns: .metadata.namespace, name: .metadata.name, reason: (.status.reason // "unknown")}' <<<"$pods_json")
```

- [ ] **Step 2: `chmod` and syntax-check**

```bash
chmod +x vps_oracle/inspector/checks/k3s-evicted-pods.sh
bash -n vps_oracle/inspector/checks/k3s-evicted-pods.sh
```

- [ ] **Step 3: Write `tests/test-k3s-evicted-pods.sh`**

```bash
#!/usr/bin/env bash
# tests/test-k3s-evicted-pods.sh — hermetic kubectl stub; kubeconfig is
# a dummy file (the check only tests existence, the stub ignores it).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
export STUB_DIR="$bin_dir"
touch "$work_dir/fake-kubeconfig"

cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" get pods -A "*)
    cat <<'JSON'
{"items":[
 {"metadata":{"name":"web-abc","namespace":"workloads"},"status":{"reason":"Evicted"}},
 {"metadata":{"name":"bad-pod","namespace":"dify"},"status":{"reason":"Error"}}
]}
JSON
    ;;
  *" delete pod "*)
    echo "kubectl $*" >> "$STUB_DIR/calls.log"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/kubectl"

check="$SCRIPT_DIR/../checks/k3s-evicted-pods.sh"
env_common=(PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/fake-kubeconfig")

echo "== dry run: both failed pods proposed, nothing deleted =="
out="$(env "${env_common[@]}" INSPECTOR_DRY_RUN=1 "$check")"
assert_true "would-delete for workloads/web-abc (Evicted)" \
  "$(grep -q '"target":"pod workloads/web-abc"' <<<"$out" && grep -q 'Evicted' <<<"$out" && echo true || echo false)"
assert_true "would-delete for dify/bad-pod (Error)" \
  "$(grep -q '"target":"pod dify/bad-pod"' <<<"$out" && echo true || echo false)"
assert_true "dry run issued no kubectl delete" \
  "$([ ! -f "$bin_dir/calls.log" ] && echo true || echo false)"

echo "== real run: both deleted =="
out="$(env "${env_common[@]}" "$check")"
assert_true "deleted lines for both pods" \
  "$([ "$(grep -c '"action":"deleted"' <<<"$out")" = "2" ] && echo true || echo false)"
assert_true "kubectl delete called per pod with namespace" \
  "$(grep -q 'delete pod -n workloads web-abc' "$bin_dir/calls.log" && grep -q 'delete pod -n dify bad-pod' "$bin_dir/calls.log" && echo true || echo false)"

echo "== missing kubeconfig: alert, not silence =="
out="$(env PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/nonexistent" "$check")"
assert_true "emits alert about missing kubeconfig" \
  "$(grep -q '"tier":"alert"' <<<"$out" && grep -q 'kubeconfig missing' <<<"$out" && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
```

- [ ] **Step 4: `chmod +x` and run**

```bash
chmod +x vps_oracle/inspector/tests/test-k3s-evicted-pods.sh
cd vps_oracle/inspector && ./tests/test-k3s-evicted-pods.sh
```
Expected: all `ok -`, final `PASS`, exit 0.

- [ ] **Step 5: Dry-run against real cluster**

```bash
cd vps_oracle/inspector && INSPECTOR_DRY_RUN=1 ./checks/k3s-evicted-pods.sh
```
Expected: exits 0, **no output** (0 Failed pods verified 2026-08-16). This run also proves the Task 1 kubeconfig works from a check script.

- [ ] **Step 6: Commit**

```bash
git status --short
git add vps_oracle/inspector/checks/k3s-evicted-pods.sh \
        vps_oracle/inspector/tests/test-k3s-evicted-pods.sh
git commit -m "Add k3s-evicted-pods check"
```

---

### Task 11: `checks/k3s-completed-jobs.sh`

**Files:**
- Create: `vps_oracle/inspector/checks/k3s-completed-jobs.sh`
- Create: `vps_oracle/inspector/tests/test-k3s-completed-jobs.sh`

**Interfaces:**
- Consumes: `emit_result`; kubeconfig from Task 1 (`INSPECTOR_KUBECONFIG`)
- Overridable env vars: `INSPECTOR_KUBECONFIG`, `INSPECTOR_COMPLETED_JOB_MAX_AGE_SECONDS` (default 259200 = 3 days; age-only by design — see Verified Host Facts)

- [ ] **Step 1: Write `checks/k3s-completed-jobs.sh`**

```bash
#!/usr/bin/env bash
# checks/k3s-completed-jobs.sh
#
# Deletes completed Jobs older than INSPECTOR_COMPLETED_JOB_MAX_AGE_
# SECONDS (default 3 days). Design spec's "k3s Completed Job 堆積" row
# (auto tier). Age-only on purpose: the spec's "超過 N 個或超過 N 天"
# offers count or age, and a count cap would delete fresh jobs whose
# output someone may still be reading — age is the low-misjudgment-cost
# dimension, matching the spec's own tiering philosophy.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

MAX_AGE_SECONDS="${INSPECTOR_COMPLETED_JOB_MAX_AGE_SECONDS:-259200}"
KUBECONFIG_FILE="${INSPECTOR_KUBECONFIG:-$INSPECTOR_STATE_DIR/kubeconfig}"

if [ ! -f "$KUBECONFIG_FILE" ]; then
  emit_result "alert" "flagged" "check:k3s-completed-jobs.sh" \
    "inspector kubeconfig missing at $KUBECONFIG_FILE — run k3s/setup-kubeconfig.sh once (see README)"
  exit 0
fi

kc() { kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"; }

jobs_json="$(kc get jobs -A -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:k3s-completed-jobs.sh" \
    "kubernetes API not reachable via inspector kubeconfig — check skipped"
  exit 0
}

now_epoch="$(date +%s)"

while read -r line; do
  [ -n "$line" ] || continue
  ns="$(jq -r '.ns' <<<"$line")"
  name="$(jq -r '.name' <<<"$line")"
  completed_at="$(jq -r '.ct' <<<"$line")"
  completed_epoch="$(date -d "$completed_at" +%s 2>/dev/null)" || continue
  age=$((now_epoch - completed_epoch))
  [ "$age" -ge "$MAX_AGE_SECONDS" ] || continue

  if [ "${INSPECTOR_DRY_RUN:-0}" = "1" ]; then
    emit_result "auto" "would-delete" "job $ns/$name" \
      "completed ${age}s ago (threshold ${MAX_AGE_SECONDS}s)"
  elif kc delete job -n "$ns" "$name" >/dev/null 2>&1; then
    emit_result "auto" "deleted" "job $ns/$name" \
      "completed ${age}s ago (threshold ${MAX_AGE_SECONDS}s)"
  else
    emit_result "alert" "flagged" "job $ns/$name" \
      "kubectl delete failed (completed ${age}s ago) — manual investigation needed"
  fi
done < <(jq -c '.items[] | select(.status.completionTime != null) | {ns: .metadata.namespace, name: .metadata.name, ct: .status.completionTime}' <<<"$jobs_json")
```

- [ ] **Step 2: `chmod` and syntax-check**

```bash
chmod +x vps_oracle/inspector/checks/k3s-completed-jobs.sh
bash -n vps_oracle/inspector/checks/k3s-completed-jobs.sh
```

- [ ] **Step 3: Write `tests/test-k3s-completed-jobs.sh`**

```bash
#!/usr/bin/env bash
# tests/test-k3s-completed-jobs.sh — hermetic kubectl stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
export STUB_DIR="$bin_dir"
touch "$work_dir/fake-kubeconfig"

old_ct="$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)"
new_ct="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
cat > "$work_dir/jobs.json" <<EOF
{"items":[
 {"metadata":{"name":"job-old","namespace":"workloads"},"status":{"completionTime":"$old_ct"}},
 {"metadata":{"name":"job-fresh","namespace":"workloads"},"status":{"completionTime":"$new_ct"}},
 {"metadata":{"name":"job-running","namespace":"kyverno"},"status":{}}
]}
EOF

cat > "$bin_dir/kubectl" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" get jobs -A "*) cat "$work_dir/jobs.json" ;;
  *" delete job "*)
    echo "kubectl \$*" >> "\$STUB_DIR/calls.log"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/kubectl"

check="$SCRIPT_DIR/../checks/k3s-completed-jobs.sh"
env_common=(PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/fake-kubeconfig")

echo "== dry run: only the 10-day-old job is proposed =="
out="$(env "${env_common[@]}" INSPECTOR_DRY_RUN=1 "$check")"
assert_true "would-delete for workloads/job-old" \
  "$(grep -q '"target":"job workloads/job-old"' <<<"$out" && echo true || echo false)"
assert_true "1h-old completed job is not proposed" \
  "$(grep -q 'job-fresh' <<<"$out" && echo false || echo true)"
assert_true "incomplete job is not proposed" \
  "$(grep -q 'job-running' <<<"$out" && echo false || echo true)"
assert_true "dry run issued no kubectl delete" \
  "$([ ! -f "$bin_dir/calls.log" ] && echo true || echo false)"

echo "== real run: only job-old deleted =="
out="$(env "${env_common[@]}" "$check")"
assert_true "one deleted line" \
  "$([ "$(grep -c '"action":"deleted"' <<<"$out")" = "1" ] && echo true || echo false)"
assert_true "kubectl delete job called for job-old only" \
  "$(grep -q 'delete job -n workloads job-old' "$bin_dir/calls.log" && [ "$(grep -c 'delete job' "$bin_dir/calls.log")" = "1" ] && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
```

- [ ] **Step 4: `chmod +x` and run**

```bash
chmod +x vps_oracle/inspector/tests/test-k3s-completed-jobs.sh
cd vps_oracle/inspector && ./tests/test-k3s-completed-jobs.sh
```
Expected: all `ok -`, final `PASS`, exit 0.

- [ ] **Step 5: Dry-run against real cluster**

```bash
cd vps_oracle/inspector && INSPECTOR_DRY_RUN=1 ./checks/k3s-completed-jobs.sh
```
Expected: exits 0, **no output** (the only completed Job, `kyverno/kyverno-migrate-resources`, is <1h old — far under the 3-day threshold).

- [ ] **Step 6: Commit**

```bash
git status --short
git add vps_oracle/inspector/checks/k3s-completed-jobs.sh \
        vps_oracle/inspector/tests/test-k3s-completed-jobs.sh
git commit -m "Add k3s-completed-jobs check with age threshold"
```

---

### Task 12: `checks/k3s-containerd-images.sh`

**Files:**
- Create: `vps_oracle/inspector/checks/k3s-containerd-images.sh`
- Create: `vps_oracle/inspector/tests/test-k3s-containerd-images.sh`

**Interfaces:**
- Consumes: `emit_result`; passwordless `sudo -n` (crictl socket is root-only, verified); `tests/lib.sh`
- Overridable env vars: none for behavior — **no age threshold by design**: CRI's image listing exposes no creation timestamp (`crictl images -o json` fields are id/pinned/repoDigests/repoTags/size/username only, verified 2026-08-16), and the spec's action cell for this row is plainly `crictl rmi --prune`. Kubelet's own image GC (active on k3s by default) remains the age-aware primary mechanism; this check is the manual backstop.

- [ ] **Step 1: Write `checks/k3s-containerd-images.sh`**

```bash
#!/usr/bin/env bash
# checks/k3s-containerd-images.sh
#
# Reports and prunes containerd images not referenced by any container
# (including exited ones) on the k3s node. Design spec's "k3s
# containerd 未用 image" row (auto tier). crictl needs root (socket +
# config are root-only) — this and docker-oversized-logs.sh are the two
# narrowly-scoped sudo uses the spec's deployment section sanctions.
#
# No age filter, deliberately: CRI exposes no image creation timestamp,
# and `crictl rmi --prune` (the spec's named action) has none either.
# Kubelet image GC is the age-aware primary mechanism; this is the
# backstop that reports what's sitting unused.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

sudo -n true 2>/dev/null || {
  emit_result "alert" "flagged" "check:k3s-containerd-images.sh" \
    "passwordless sudo unavailable — cannot run crictl, check skipped"
  exit 0
}

ps_json="$(sudo -n crictl ps -a -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:k3s-containerd-images.sh" \
    "crictl ps failed — check skipped"
  exit 0
}
images_json="$(sudo -n crictl images -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:k3s-containerd-images.sh" \
    "crictl images failed — check skipped"
  exit 0
}

used_file="$(mktemp)"
trap 'rm -f "$used_file"' EXIT
jq -r '.containers[].imageRef' <<<"$ps_json" | sed 's/^sha256://' | sort -u > "$used_file"

count=0
total_size=0
while read -r line; do
  [ -n "$line" ] || continue
  id="$(jq -r '.id' <<<"$line")"
  id="${id#sha256:}"
  grep -qx "$id" "$used_file" && continue
  size="$(jq -r '.size' <<<"$line")"
  count=$((count + 1))
  total_size=$((total_size + size))
done < <(jq -c '.images[]' <<<"$images_json")

[ "$count" -gt 0 ] || exit 0

detail="${count} images not referenced by any container (incl. exited), total ${total_size} bytes — no age filter: CRI exposes no image creation time; kubelet image GC is the age-aware mechanism"

if [ "${INSPECTOR_DRY_RUN:-0}" = "1" ]; then
  emit_result "auto" "would-delete" "containerd unused images x${count}" "$detail"
elif output="$(sudo -n crictl rmi --prune 2>/dev/null)"; then
  emit_result "auto" "deleted" "containerd unused images x${count}" "$detail"
else
  emit_result "alert" "flagged" "containerd unused images x${count}" \
    "crictl rmi --prune failed — manual investigation needed"
fi
```

- [ ] **Step 2: `chmod` and syntax-check**

```bash
chmod +x vps_oracle/inspector/checks/k3s-containerd-images.sh
bash -n vps_oracle/inspector/checks/k3s-containerd-images.sh
```

- [ ] **Step 3: Write `tests/test-k3s-containerd-images.sh`**

```bash
#!/usr/bin/env bash
# tests/test-k3s-containerd-images.sh — hermetic: sudo passes through to
# a stubbed crictl.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
export STUB_DIR="$bin_dir"

cat > "$bin_dir/sudo" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-n" ] && shift
exec "$@"
EOF
cat > "$bin_dir/crictl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" ps -a -o json "*)
    echo '{"containers":[{"imageRef":"sha256:aaa"},{"imageRef":"sha256:bbb"}]}'
    ;;
  *" images -o json "*)
    echo '{"images":[{"id":"sha256:aaa","size":100},{"id":"sha256:bbb","size":50},{"id":"sha256:ccc","size":200}]}'
    ;;
  *" rmi --prune "*)
    echo "crictl $*" >> "$STUB_DIR/calls.log"
    echo "Deleted: sha256:ccc"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/sudo" "$bin_dir/crictl"

check="$SCRIPT_DIR/../checks/k3s-containerd-images.sh"

echo "== dry run: only the unreferenced image counts =="
out="$(PATH="$bin_dir:$PATH" INSPECTOR_DRY_RUN=1 "$check")"
assert_true "would-delete summary says x1" \
  "$(grep -q '"target":"containerd unused images x1"' <<<"$out" && echo true || echo false)"
assert_true "detail carries the summed size 250" \
  "$(grep -q 'total 250 bytes' <<<"$out" && echo true || echo false)"
assert_true "dry run issued no crictl rmi" \
  "$([ ! -f "$bin_dir/calls.log" ] && echo true || echo false)"

echo "== real run: prune invoked once =="
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "deleted summary line" \
  "$(grep -q '"action":"deleted"' <<<"$out" && echo true || echo false)"
assert_true "crictl rmi --prune called exactly once" \
  "$([ "$(grep -c 'rmi --prune' "$bin_dir/calls.log")" = "1" ] && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
```

- [ ] **Step 4: `chmod +x` and run**

```bash
chmod +x vps_oracle/inspector/tests/test-k3s-containerd-images.sh
cd vps_oracle/inspector && ./tests/test-k3s-containerd-images.sh
```
Expected: all `ok -`, final `PASS`, exit 0.

- [ ] **Step 5: Dry-run against real node**

```bash
cd vps_oracle/inspector && INSPECTOR_DRY_RUN=1 ./checks/k3s-containerd-images.sh
```
Expected: exits 0; possibly one `would-delete` summary line (62 images vs 104 containers on node — some unused is normal since kubelet GC runs on disk-pressure thresholds, not continuously). Whatever it reports, cross-check a named image against `sudo crictl images` before trusting the count.

- [ ] **Step 6: Commit**

```bash
git status --short
git add vps_oracle/inspector/checks/k3s-containerd-images.sh \
        vps_oracle/inspector/tests/test-k3s-containerd-images.sh
git commit -m "Add k3s-containerd-images check (sudo crictl prune backstop)"
```

---

### Task 13: `checks/k3s-released-pvs.sh` + `checks/k3s-stuck-terminating.sh` (both alert only)

Two structurally identical read-only checks (`kubectl get -o json` → jq filter → alert line, never acts), one shared test file.

**Files:**
- Create: `vps_oracle/inspector/checks/k3s-released-pvs.sh`
- Create: `vps_oracle/inspector/checks/k3s-stuck-terminating.sh`
- Create: `vps_oracle/inspector/tests/test-k3s-alerts.sh`

**Interfaces:**
- Consumes: `emit_result`; kubeconfig from Task 1 (`INSPECTOR_KUBECONFIG`)
- Overridable env vars: `INSPECTOR_KUBECONFIG`; `INSPECTOR_TERMINATING_STUCK_SECONDS` (default 900) on the terminating check

- [ ] **Step 1: Write `checks/k3s-released-pvs.sh`**

```bash
#!/usr/bin/env bash
# checks/k3s-released-pvs.sh
#
# Flags PersistentVolumes in Released phase — unbound but still holding
# disk. Design spec's "k3s Released PV" row (ALERT ONLY — same
# asymmetric-misjudgment reasoning as docker volumes: a Released PV may
# still be the only copy of data someone wants).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

KUBECONFIG_FILE="${INSPECTOR_KUBECONFIG:-$INSPECTOR_STATE_DIR/kubeconfig}"

if [ ! -f "$KUBECONFIG_FILE" ]; then
  emit_result "alert" "flagged" "check:k3s-released-pvs.sh" \
    "inspector kubeconfig missing at $KUBECONFIG_FILE — run k3s/setup-kubeconfig.sh once (see README)"
  exit 0
fi

pv_json="$(kubectl --kubeconfig "$KUBECONFIG_FILE" get pv -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:k3s-released-pvs.sh" \
    "kubernetes API not reachable via inspector kubeconfig — check skipped"
  exit 0
}

while read -r line; do
  [ -n "$line" ] || continue
  name="$(jq -r '.name' <<<"$line")"
  cap="$(jq -r '.cap' <<<"$line")"
  claim="$(jq -r '.claim' <<<"$line")"
  emit_result "alert" "flagged" "PV $name" \
    "Released (was $claim, capacity $cap) — still holds storage, manual review needed"
done < <(jq -c '.items[] | select(.status.phase == "Released") | {name: .metadata.name, cap: (.spec.capacity.storage // "unknown"), claim: (.spec.claimRef.name // "unknown")}' <<<"$pv_json")
```

- [ ] **Step 2: Write `checks/k3s-stuck-terminating.sh`**

```bash
#!/usr/bin/env bash
# checks/k3s-stuck-terminating.sh
#
# Flags pods stuck in Terminating (deletionTimestamp set longer than
# INSPECTOR_TERMINATING_STUCK_SECONDS ago). Design spec's "k3s 卡住的
# Terminating pod" row (ALERT ONLY — usually a finalizer/node problem;
# force-deleting is a human decision).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

THRESHOLD_SECONDS="${INSPECTOR_TERMINATING_STUCK_SECONDS:-900}"
KUBECONFIG_FILE="${INSPECTOR_KUBECONFIG:-$INSPECTOR_STATE_DIR/kubeconfig}"

if [ ! -f "$KUBECONFIG_FILE" ]; then
  emit_result "alert" "flagged" "check:k3s-stuck-terminating.sh" \
    "inspector kubeconfig missing at $KUBECONFIG_FILE — run k3s/setup-kubeconfig.sh once (see README)"
  exit 0
fi

pods_json="$(kubectl --kubeconfig "$KUBECONFIG_FILE" get pods -A -o json 2>/dev/null)" || {
  emit_result "alert" "flagged" "check:k3s-stuck-terminating.sh" \
    "kubernetes API not reachable via inspector kubeconfig — check skipped"
  exit 0
}

now_epoch="$(date +%s)"

while read -r line; do
  [ -n "$line" ] || continue
  ns="$(jq -r '.ns' <<<"$line")"
  name="$(jq -r '.name' <<<"$line")"
  dt="$(jq -r '.dt' <<<"$line")"
  dt_epoch="$(date -d "$dt" +%s 2>/dev/null)" || continue
  age=$((now_epoch - dt_epoch))
  [ "$age" -ge "$THRESHOLD_SECONDS" ] || continue
  emit_result "alert" "flagged" "pod $ns/$name" \
    "Terminating for ${age}s (threshold ${THRESHOLD_SECONDS}s) — likely stuck finalizer, manual review needed"
done < <(jq -c '.items[] | select(.metadata.deletionTimestamp != null) | {ns: .metadata.namespace, name: .metadata.name, dt: .metadata.deletionTimestamp}' <<<"$pods_json")
```

- [ ] **Step 3: `chmod` and syntax-check both**

```bash
chmod +x vps_oracle/inspector/checks/k3s-released-pvs.sh \
          vps_oracle/inspector/checks/k3s-stuck-terminating.sh
bash -n vps_oracle/inspector/checks/k3s-released-pvs.sh
bash -n vps_oracle/inspector/checks/k3s-stuck-terminating.sh
```

- [ ] **Step 4: Write `tests/test-k3s-alerts.sh`**

```bash
#!/usr/bin/env bash
# tests/test-k3s-alerts.sh — covers k3s-released-pvs.sh and
# k3s-stuck-terminating.sh (structurally identical read-only checks).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
touch "$work_dir/fake-kubeconfig"

old_dt="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
new_dt="$(date -u -d '-1 minute' +%Y-%m-%dT%H:%M:%SZ)"

cat > "$work_dir/pv.json" <<EOF
{"items":[
 {"metadata":{"name":"pvc-stale"},"spec":{"capacity":{"storage":"5Gi"},"claimRef":{"name":"vikunja"}},"status":{"phase":"Released"}},
 {"metadata":{"name":"pvc-live"},"spec":{"capacity":{"storage":"1Gi"},"claimRef":{"name":"apprise"}},"status":{"phase":"Bound"}}
]}
EOF
cat > "$work_dir/pods.json" <<EOF
{"items":[
 {"metadata":{"name":"stuck-pod","namespace":"workloads","deletionTimestamp":"$old_dt"}},
 {"metadata":{"name":"fresh-delete","namespace":"dify","deletionTimestamp":"$new_dt"}},
 {"metadata":{"name":"normal-pod","namespace":"dify"}}
]}
EOF

cat > "$bin_dir/kubectl" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" get pv -o json "*) cat "$work_dir/pv.json" ;;
  *" get pods -A -o json "*) cat "$work_dir/pods.json" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/kubectl"

env_common=(PATH="$bin_dir:$PATH" INSPECTOR_KUBECONFIG="$work_dir/fake-kubeconfig")

echo "== released PVs: only the Released one is flagged =="
out="$(env "${env_common[@]}" "$SCRIPT_DIR/../checks/k3s-released-pvs.sh")"
assert_true "flags pvc-stale with claim and capacity" \
  "$(grep -q '"target":"PV pvc-stale"' <<<"$out" && grep -q 'vikunja' <<<"$out" && grep -q '5Gi' <<<"$out" && echo true || echo false)"
assert_true "Bound PV is not flagged" \
  "$(grep -q 'pvc-live' <<<"$out" && echo false || echo true)"

echo "== stuck terminating: only deletionTimestamp older than 900s is flagged =="
out="$(env "${env_common[@]}" "$SCRIPT_DIR/../checks/k3s-stuck-terminating.sh")"
assert_true "flags stuck-pod (deleting for ~1h)" \
  "$(grep -q '"target":"pod workloads/stuck-pod"' <<<"$out" && echo true || echo false)"
assert_true "1-minute-old deletion is under threshold, not flagged" \
  "$(grep -q 'fresh-delete' <<<"$out" && echo false || echo true)"
assert_true "pod without deletionTimestamp is not flagged" \
  "$(grep -q 'normal-pod' <<<"$out" && echo false || echo true)"

rm -rf "$work_dir"
finish_tests
```

- [ ] **Step 5: `chmod +x` and run**

```bash
chmod +x vps_oracle/inspector/tests/test-k3s-alerts.sh
cd vps_oracle/inspector && ./tests/test-k3s-alerts.sh
```
Expected: all `ok -`, final `PASS`, exit 0.

- [ ] **Step 6: Run both against real cluster** (alert-tier, never acts)

```bash
cd vps_oracle/inspector && ./checks/k3s-released-pvs.sh && ./checks/k3s-stuck-terminating.sh
```
Expected: both exit 0, **no output** (all PVs Bound, 0 Terminating pods, verified 2026-08-16).

- [ ] **Step 7: Commit**

```bash
git status --short
git add vps_oracle/inspector/checks/k3s-released-pvs.sh \
        vps_oracle/inspector/checks/k3s-stuck-terminating.sh \
        vps_oracle/inspector/tests/test-k3s-alerts.sh
git commit -m "Add k3s released-PV and stuck-terminating alert checks"
```

---

### Task 14: systemd PATH pin, README phase 2 section, full-run validation

**Files:**
- Modify: `vps_oracle/inspector/systemd/docker-gitops-inspector.service` (add one `Environment=` line)
- Modify: `vps_oracle/inspector/README.md` (replace the "現況" section, extend 測試/部署)

**Interfaces:**
- Consumes: all 13 checks from Tasks 2–13 (already committed and individually verified)
- Produces: deployed state where the systemd timer runs the full 15-check inspector; updated docs

- [ ] **Step 1: Add explicit PATH to the service unit**

The full `[Service]` section after the edit (only the `Environment=` line is new — kubectl lives in `/usr/local/bin`, which is in systemd's compiled default PATH today; pinning it makes the dependency explicit instead of ambient):

```ini
[Unit]
Description=docker-gitops host inspector (vps_oracle) — stray session cleanup + resource report
After=network-online.target

[Service]
Type=oneshot
User=ubuntu
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=/home/ubuntu/jerome/docker-gitops/vps_oracle/inspector
ExecStart=/home/ubuntu/jerome/docker-gitops/vps_oracle/inspector/inspect.sh
```

- [ ] **Step 2: Update `README.md`**

Replace the existing `## 現況（phase 1）` section (keep the 範圍邊界 paragraph as-is) with:

```markdown
## 現況（phase 2）

已實作（phase 1）：
- `checks/stray-vscode-sessions.sh` — 游離/卡死的 claude session、脫離連線的 server-main 樹
- `checks/vscode-server-versions.sh` — 堆積的 `.vscode-server/cli/servers/*` 版本目錄

已實作（phase 2，docker 層）：
- `checks/docker-stopped-containers.sh`（auto）— exited 超過 7 天的容器
- `checks/docker-dangling-images.sh`（auto）— dangling 超過 7 天的 image
- `checks/docker-build-cache.sh`（auto）— 超過 7 天的 build cache
- `checks/docker-unused-networks.sh`（auto）— 無容器掛載的自訂 network
- `checks/docker-restart-storms.sh`（alert）— RestartCount 異常高 / 持續 Restarting
- `checks/docker-unused-volumes.sh`（alert）— 無容器掛載的 volume（匿名聚合成一行，具名逐行）
- `checks/docker-compose-logging-drift.sh`（alert）— compose 服務缺 `logging.options.max-size`
- `checks/docker-oversized-logs.sh`（alert）— 單檔超過 50MiB 的 `*-json.log`

已實作（phase 2，k3s 層）：
- `checks/k3s-evicted-pods.sh`（auto）— Failed 殘留 pod
- `checks/k3s-completed-jobs.sh`（auto）— 完成超過 3 天的 Job
- `checks/k3s-containerd-images.sh`（auto）— 無容器引用的 containerd image（`sudo crictl`）
- `checks/k3s-released-pvs.sh`（alert）— Released PV
- `checks/k3s-stuck-terminating.sh`（alert）— 卡超過 15 分鐘的 Terminating pod

閾值都是各腳本開頭的 env var，可從 systemd unit 的 `Environment=` 或手動執行時覆寫。
```

And replace the `## 測試` code block's script list with the full set:

```bash
cd vps_oracle/inspector
./tests/test-common.sh
./tests/test-stray-vscode-sessions.sh
./tests/test-vscode-server-versions.sh
./tests/test-inspect.sh        # 最後一段會真的打 apprise inspector-tg，Telegram 群組要收得到
./tests/test-docker-stopped-containers.sh
./tests/test-docker-dangling-images.sh
./tests/test-docker-build-cache.sh
./tests/test-docker-unused-networks.sh
./tests/test-docker-restart-storms.sh
./tests/test-docker-unused-volumes.sh
./tests/test-docker-compose-logging-drift.sh
./tests/test-docker-oversized-logs.sh
./tests/test-k3s-evicted-pods.sh
./tests/test-k3s-completed-jobs.sh
./tests/test-k3s-containerd-images.sh
./tests/test-k3s-alerts.sh
```

And append this new section after `## 部署`:

```markdown
## k3s 存取（phase 2 一次性設置）

k3s checks 不用 admin kubeconfig，用最小權限 SA（`workloads/docker-gitops-inspector`：pods/jobs get+list+delete、PV get+list，其余一律拒絕）：

```bash
cd vps_oracle/inspector
./k3s/setup-kubeconfig.sh     # apply RBAC + 寫 state/kubeconfig（gitignored，600）
```

腳本冪等，重跑安全。RBAC manifest 在 `k3s/rbac.yaml`——不在 `vps_oracle/k3s/manifests/`（那是 ArgoCD 地盤，見 k3s/README）。

兩個 check 用到密碼免輸入的 `sudo -n`（都是唯讀列舉或單一清理指令）：`docker-oversized-logs.sh`（讀 `/var/lib/docker/containers`）、`k3s-containerd-images.sh`（`crictl` socket 是 root-only）。若日後收回 NOPASSWD，這兩個 check 會在報告裡發 alert 說明被跳過，不會掛住。
```

- [ ] **Step 3: Run the full test suite**

```bash
cd vps_oracle/inspector
for t in ./tests/test-*.sh; do echo "== $t =="; "$t" || break; done
```
Expected: every test file ends `PASS`; loop completes without breaking.

- [ ] **Step 4: Full dry run of all 15 checks via inspect.sh**

```bash
cd vps_oracle/inspector && INSPECTOR_DRY_RUN=1 ./inspect.sh
```
Expected: exit 0, one Telegram message in "OCI System inspection". Expected real findings on this host: the `docker unused volumes` aggregate line (~47 anonymous) and possibly named-volume lines and one `containerd unused images` line; **nothing** in 已自動處理 (host verified clean for every auto tier). Anything else in the report is a surprise — investigate before Step 5.

- [ ] **Step 5: Reload unit and do one real (non-dry-run) systemd run**

```bash
sudo systemctl daemon-reload
sudo systemctl start docker-gitops-inspector.service
systemctl status docker-gitops-inspector.service --no-pager
journalctl -u docker-gitops-inspector.service -n 80 --no-pager
```
Expected: status `Succeeded`; journal shows the check scripts ran (no "docker daemon unreachable" / "kubeconfig missing" / "sudo unavailable" alerts — those would mean the systemd environment differs from the interactive one); a real report lands in Telegram. Cross-check `docker ps -a`, `kubectl get jobs -A`, `sudo crictl images` afterwards that nothing unexpected was removed (expected: nothing auto-tier fires on this host today; if the containerd-image line fired for real, verify the removed images were genuinely unreferenced).

- [ ] **Step 6: Commit**

```bash
git status --short
git add vps_oracle/inspector/systemd/docker-gitops-inspector.service vps_oracle/inspector/README.md
git commit -m "Pin PATH in inspector unit and document phase 2 in README"
```

---

## Definition of Done (Phase 2)

- [ ] All 16 test files pass (`test-common.sh` through `test-k3s-alerts.sh`)
- [ ] `INSPECTOR_DRY_RUN=1 ./inspect.sh` full run: report contents match actual host state (eyeballed against `docker ps -a` / `kubectl get` / `sudo crictl images`), nothing in 已自動處理 that shouldn't be
- [ ] One real systemd-triggered run (`systemctl start`) succeeded: journal clean, Telegram report received, nothing wrongly deleted
- [ ] `state/kubeconfig` exists (mode 600) and RBAC verified: SA can delete pods/jobs, cannot read secrets
- [ ] All 14 tasks committed as separate commits on `main`, each preceded by a `git status --short` check
- [ ] README reflects phase 2 (checks list, k3s setup, full test list)

## Spec Coverage Check

Spec auto-tier rows: 已停止容器→Task 2, dangling image→Task 3, build cache→Task 4, 未用 network→Task 5, Evicted/Failed pod→Task 10, Completed Job→Task 11, containerd 未用 image→Task 12. Spec alert-tier rows: 重啟風暴→Task 6, 未用 volume→Task 7, logging 配置漂移→Task 8, 日誌檔異常大→Task 9, Released PV→Task 13, 卡住 Terminating→Task 13. Self-chain overlap row was implemented in phase 1 (kill_tree consumers; no new kill paths exist in phase 2 — no process kills at all, so no new self-protection surface). Deployment requirements (ubuntu user + scoped sudo + non-admin kubeconfig): Tasks 1, 9, 12, 14.
