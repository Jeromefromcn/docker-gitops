# Claude Code 分组级 Provider 切换 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Claude Code sessions under `~/jerome/` (premium projects) and `~/bridget/` (budget projects) independently switch between the official Anthropic subscription and a self-hosted claude-code-router (CCR) instance that fronts a Zhipu GLM subscription, driven by direnv and toggled from a small web UI that always reflects live state.

**Architecture:** A wrapper script installed via VSCode's `claudeCode.claudeProcessWrapper` (and the existing `.bashrc` direnv hook for terminal use) evaluates direnv for the claude process's cwd before exec'ing the real binary. Each group's `.envrc` is static and `source_env_if_exists`s a per-group `.env` file under `~/.claude-provider/`; that file is the *only* thing the UI ever writes. When a group's file sets `ANTHROPIC_BASE_URL`, requests go to a local CCR container (`vps_oracle/compose/ccr/`) which routes to Zhipu; when empty, claude falls back to official OAuth. A second container (`vps_oracle/compose/provider-switch/`) serves the toggle UI, scanning live state on every request rather than caching it.

**Tech Stack:** bash, direnv, Python 3.12 stdlib (`http.server`, no framework — matches the existing `vikunja/notify-relay` pattern), Docker Compose, claude-code-router v3.0.20 (built from its pinned git tag; no published image exists).

## Global Constraints

- Timezone: `environment: TZ: "Asia/Hong_Kong"` on every new service (README).
- Logging: every service gets explicit `logging: {driver: json-file, options: {max-size: "10m", max-file: "5"}}` (README).
- `restart: unless-stopped` on every new service (README).
- Pin image tags/digests, never `latest` (README, CLAUDE.md). For CCR, "pin" means building from a fixed git tag and tagging the resulting local image with that version — no published image exists upstream.
- Minimal port exposure: don't publish host ports for internal/admin surfaces; use the `proxy` Docker network + NPM reverse proxy instead (README). CCR is a deliberate, documented exception (see Task 5) because its consumer is the host `claude` process, not a container.
- `security_opt: [no-new-privileges:true]` where the container's capabilities allow it (README).
- Cross-stack traffic goes over the external `proxy` network; don't attach services that don't need inter-stack access (README).
- Never commit secrets. `.env` / `*.env` / `*credentials*.json` are gitignored — verified already present in this repo's `.gitignore`.
- One change per commit, scoped to one compose stack (CLAUDE.md, README).
- User-visible copy (dashboard titles, card descriptions) in English; repo comments/docs/commit messages in Chinese, matching existing convention (README).
- After editing a compose file, apply with `docker compose up -d` in that stack's directory — but per CLAUDE.md, confirm with the user before applying changes that recreate a running container.
- Host dotfiles under `~/.claude/`, `~/jerome/`, `~/bridget/`, `~/.claude-provider/` are **outside this git repository** — tasks touching them do not end in a repo commit; they end in a shell verification instead.

---

## Task 1: Shared direnv-eval kernel + refactor the existing BASH_ENV shim

**Files:**
- Create: `/home/ubuntu/.claude/direnv-load.sh`
- Modify: `/home/ubuntu/.claude/direnv-bash-env.sh`

**Interfaces:**
- Produces: a sourceable script `direnv-load.sh` that, when sourced, exports whatever `direnv` resolves for `$PWD` into the current shell. No parameters, no return value — side effect only (env vars set). Both this task's shim and Task 2's wrapper source it identically: `. /home/ubuntu/.claude/direnv-load.sh`.

This collapses the two known direnv footguns (recursion via inherited `BASH_ENV`, stdin hang) into one file so they're only fixed once. Full rationale in spec §2.1, §2.2.

- [ ] **Step 1: Write the shared kernel**

```bash
cat > /home/ubuntu/.claude/direnv-load.sh <<'EOF'
# 对当前目录求值 direnv 并注入环境变量。被 source，不要 exit。
if command -v direnv >/dev/null 2>&1; then
  __d="$(BASH_ENV= timeout 5 direnv export bash 2>/dev/null </dev/null)"
  [ -n "$__d" ] && eval "$__d"
  unset __d
fi
EOF
```

- [ ] **Step 2: Refactor the existing BASH_ENV shim to source the kernel**

Read the current file first to confirm nothing else is inside it (it should only be the interactive-shell guard + the direnv-export logic already extracted in Step 1):

```bash
cat /home/ubuntu/.claude/direnv-bash-env.sh
```

Replace its contents:

```bash
cat > /home/ubuntu/.claude/direnv-bash-env.sh <<'EOF'
# Auto-loads direnv's .envrc for every non-interactive bash invocation
# (used by Claude Code's Bash tool and, via claude-direnv-wrapper.sh, by
# the claude process itself). Sourced via $BASH_ENV.
case $- in
  *i*) return 0 2>/dev/null || exit 0 ;;
esac
. /home/ubuntu/.claude/direnv-load.sh
EOF
```

- [ ] **Step 3: Verify the Bash-tool path still works (regression check)**

This is the path your existing git-token direnv setup depends on — must not break.

```bash
cd /home/ubuntu/jerome/betting-lab && BASH_ENV=/home/ubuntu/.claude/direnv-bash-env.sh bash -c 'echo "venv activated: ${VIRTUAL_ENV:-(none)}"'
```

Expected: prints a non-empty path (or whatever `betting-lab/.envrc` actually activates — confirm against its current content, don't assume).

- [ ] **Step 4: No git commit** — this file lives in `/home/ubuntu/.claude/`, outside `docker-gitops`. Move to Task 2.

---

## Task 2: New wrapper script for the VSCode extension's `claudeProcessWrapper` hook

**Files:**
- Create: `/home/ubuntu/.claude/claude-direnv-wrapper.sh`

**Interfaces:**
- Consumes: `/home/ubuntu/.claude/direnv-load.sh` (Task 1).
- Produces: an executable that VSCode invokes as `claude-direnv-wrapper.sh <real-claude-binary> <args...>` (per the extension's `resolveClaudeBinary()` — confirmed in spec §2.4). Downstream (Task 3) configures VSCode to call this path.

- [ ] **Step 1: Write the wrapper**

```bash
cat > /home/ubuntu/.claude/claude-direnv-wrapper.sh <<'EOF'
#!/usr/bin/env bash
# 由 VSCode 扩展以 workspace 目录为 cwd 调用: wrapper <真claude> <args...>
. /home/ubuntu/.claude/direnv-load.sh
exec "$@"
EOF
chmod +x /home/ubuntu/.claude/claude-direnv-wrapper.sh
```

- [ ] **Step 2: Verify it correctly execs a passthrough command without direnv involved**

```bash
/home/ubuntu/.claude/claude-direnv-wrapper.sh echo "wrapper exec works"
```

Expected: prints `wrapper exec works`. This isolates "does the wrapper's `exec "$@"` work at all" from "does direnv injection work" — the next test covers the latter.

- [ ] **Step 3: Verify direnv injection through the wrapper, using a disposable test directory**

```bash
mkdir -p /tmp/wrapper-direnv-test
echo 'export WRAPPER_PROBE=hit' > /tmp/wrapper-direnv-test/.envrc
direnv allow /tmp/wrapper-direnv-test
cd /tmp/wrapper-direnv-test && /home/ubuntu/.claude/claude-direnv-wrapper.sh bash -c 'echo "WRAPPER_PROBE=${WRAPPER_PROBE:-MISSING}"'
```

Expected: `WRAPPER_PROBE=hit`.

- [ ] **Step 4: Clean up the test fixture**

```bash
direnv deny /tmp/wrapper-direnv-test 2>/dev/null
rm -rf /tmp/wrapper-direnv-test
```

- [ ] **Step 5: No git commit** — outside the repo. Proceed to Task 3.

---

## Task 3: Wire the wrapper into VSCode and verify end-to-end (closes C7)

This is the plan's single genuinely unverified step (spec C7): whether VSCode's `claudeCode.claudeProcessWrapper` machine setting actually gets honored the way the extension's source implies. Two-phase rollout so a failure is diagnosable and instantly revertible.

**Files:**
- Modify: `/home/ubuntu/.vscode-server/data/Machine/settings.json`

**Interfaces:**
- Consumes: `/home/ubuntu/.claude/claude-direnv-wrapper.sh` (Task 2).
- Produces: nothing consumed by later tasks programmatically — this is a manual/verification gate. If it fails, stop and fall back to `claudeCode.useTerminal: true` (spec §"为什么一定要用 wrapper" discussion) before continuing to Task 4.

- [ ] **Step 1: Snapshot the current settings file (rollback point)**

```bash
cp /home/ubuntu/.vscode-server/data/Machine/settings.json /tmp/vscode-machine-settings.bak.json
cat /home/ubuntu/.vscode-server/data/Machine/settings.json
```

- [ ] **Step 2: Phase A — point the setting at a no-op passthrough wrapper first**

Don't jump straight to the direnv-aware wrapper — if VSCode fails to launch claude at all, you need to know whether the *mechanism* (wrapper invocation) or the *content* (direnv sourcing) is at fault.

```bash
cat > /tmp/wrapper-passthrough.sh <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x /tmp/wrapper-passthrough.sh

python3 -c "
import json
p = '/home/ubuntu/.vscode-server/data/Machine/settings.json'
d = json.load(open(p))
d['claudeCode.claudeProcessWrapper'] = '/tmp/wrapper-passthrough.sh'
json.dump(d, open(p, 'w'), indent=4)
"
cat /home/ubuntu/.vscode-server/data/Machine/settings.json
```

- [ ] **Step 3: Reload the VSCode window**

In the editor: `Ctrl+Shift+P` → "Developer: Reload Window" (or "Reload Window").

- [ ] **Step 4: Confirm claude still starts and responds under Phase A**

Open a new Claude Code chat in the reloaded window and send a trivial message (e.g. "ok"). It must respond normally. If it does not start at all, the wrapper-invocation mechanism itself is broken — stop, restore the backup (`cp /tmp/vscode-machine-settings.bak.json /home/ubuntu/.vscode-server/data/Machine/settings.json`, reload), and report back before continuing.

- [ ] **Step 5: Phase B — switch to the real direnv-aware wrapper**

```bash
python3 -c "
import json
p = '/home/ubuntu/.vscode-server/data/Machine/settings.json'
d = json.load(open(p))
d['claudeCode.claudeProcessWrapper'] = '/home/ubuntu/.claude/claude-direnv-wrapper.sh'
json.dump(d, open(p, 'w'), indent=4)
"
```

Reload the window again (`Ctrl+Shift+P` → Reload Window).

- [ ] **Step 6: Confirm claude still starts under Phase B**

Same check as Step 4 — a new chat must respond normally. This isolates "does direnv-load.sh break something" from "does the wrapper mechanism work."

- [ ] **Step 7: Zero-token proof that env injection reaches the live claude process**

Using the same disposable `.envrc` technique as Task 2 Step 3, but this time against a real VSCode-launched session:

```bash
mkdir -p /tmp/wrapper-e2e-test
echo 'export WRAPPER_E2E_PROBE=hit' > /tmp/wrapper-e2e-test/.envrc
direnv allow /tmp/wrapper-e2e-test
```

Open `/tmp/wrapper-e2e-test` as a VSCode workspace (or open a new Claude Code chat with that folder as the workspace root), then from **any terminal** on the host:

```bash
for p in $(pgrep -f 'native-binary/claude'); do
  cwd=$(readlink /proc/$p/cwd 2>/dev/null)
  if [ "$cwd" = "/tmp/wrapper-e2e-test" ]; then
    echo "pid=$p cwd=$cwd"
    tr '\0' '\n' < /proc/$p/environ | grep WRAPPER_E2E_PROBE || echo "  FAIL: not injected"
  fi
done
```

Expected: a line `WRAPPER_E2E_PROBE=hit`. This costs zero API tokens — it inspects the process's own environment, no message needs to be sent.

- [ ] **Step 8: Note the permission-mode behavior change (C6)**

While the Phase B session is open, do one permission-requiring action (e.g. ask it to run a shell command that needs approval) and confirm the approval prompt still appears normally. The extension source shows `resolvePermissionModeInCli: !bn("claudeProcessWrapper")` — setting the wrapper moves permission-mode resolution into the extension. This should be invisible in practice; this step exists only to catch a regression early rather than discover it later mid-task.

- [ ] **Step 9: Clean up test fixtures**

```bash
direnv deny /tmp/wrapper-e2e-test 2>/dev/null
rm -rf /tmp/wrapper-e2e-test /tmp/wrapper-passthrough.sh /tmp/vscode-machine-settings.bak.json
```

- [ ] **Step 10: No git commit** — VSCode machine settings are outside the repo. Proceed to Task 4.

---

## Task 4: Group directories, static `.envrc` files, and the `betting-lab` shadowing fix

**Files:**
- Create: `/home/ubuntu/jerome/.envrc`
- Create: `/home/ubuntu/bridget/.envrc` (and the `~/bridget/` directory itself)
- Create: `/home/ubuntu/.claude-provider/jerome.env`
- Create: `/home/ubuntu/.claude-provider/bridget.env`
- Modify: `/home/ubuntu/jerome/betting-lab/.envrc`

**Interfaces:**
- Produces: two files (`~/.claude-provider/jerome.env`, `~/.claude-provider/bridget.env`) that are the **sole write target** for the provider-switch UI (Task 8/9) and the sole read target for its status scan. Their contract: empty (or comment-only) = official subscription; containing `export ANTHROPIC_BASE_URL=...` + `export ANTHROPIC_AUTH_TOKEN=...` = routed through CCR. This exact contract is depended on by Task 8's scanning logic and Task 9's toggle logic.

- [ ] **Step 1: Create the `.claude-provider` directory and both group env files, starting empty**

Per spec §3.4, initial state: `jerome.env` empty (official), `bridget.env` starts wired to CCR — but CCR's `ANTHROPIC_AUTH_TOKEN` value doesn't exist yet (it's generated in Task 6). Create both empty for now; Task 7 fills in `bridget.env` once the CCR client key exists.

```bash
mkdir -p /home/ubuntu/.claude-provider
cat > /home/ubuntu/.claude-provider/jerome.env <<'EOF'
# 空 = 走官方订阅 OAuth。provider-switch UI 是唯一应该改写这个文件的东西。
EOF
cat > /home/ubuntu/.claude-provider/bridget.env <<'EOF'
# 空 = 走官方订阅 OAuth。provider-switch UI 是唯一应该改写这个文件的东西。
# 将在 Task 7 由 CCR 的 client key 填充，切到 CCR。
EOF
```

- [ ] **Step 2: Create the static group `.envrc` files**

```bash
echo 'source_env_if_exists /home/ubuntu/.claude-provider/jerome.env' > /home/ubuntu/jerome/.envrc
direnv allow /home/ubuntu/jerome

mkdir -p /home/ubuntu/bridget
echo 'source_env_if_exists /home/ubuntu/.claude-provider/bridget.env' > /home/ubuntu/bridget/.envrc
direnv allow /home/ubuntu/bridget
```

- [ ] **Step 3: Fix the `betting-lab` shadowing (C3)**

Read its current `.envrc` first — spec records it as `source ./venv/bin/activate`, confirm that's still accurate before editing:

```bash
cat /home/ubuntu/jerome/betting-lab/.envrc
```

Prepend `source_up` so it still inherits `~/jerome/.envrc`'s provider config instead of shadowing it entirely:

```bash
{ echo 'source_up'; cat /home/ubuntu/jerome/betting-lab/.envrc; } > /tmp/betting-lab-envrc.new
mv /tmp/betting-lab-envrc.new /home/ubuntu/jerome/betting-lab/.envrc
direnv allow /home/ubuntu/jerome/betting-lab
cat /home/ubuntu/jerome/betting-lab/.envrc
```

- [ ] **Step 4: Verify the full resolution chain for both groups (zero cost, no claude involved)**

```bash
# jerome 组：应为空（官方）
cd /home/ubuntu/jerome && BASH_ENV=/home/ubuntu/.claude/direnv-bash-env.sh bash -c 'echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-(unset, official)}"'

# betting-lab：应继承 jerome 组的值，同时保留 venv 激活
cd /home/ubuntu/jerome/betting-lab && BASH_ENV=/home/ubuntu/.claude/direnv-bash-env.sh bash -c 'echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-(unset, official)} VIRTUAL_ENV=${VIRTUAL_ENV:-(none)}"'

# bridget 组：目前也应为空（CCR 值还没填）
cd /home/ubuntu/bridget && BASH_ENV=/home/ubuntu/.claude/direnv-bash-env.sh bash -c 'echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-(unset, official)}"'
```

Expected: all three print `(unset, official)` for `ANTHROPIC_BASE_URL`; `betting-lab` additionally shows its venv path (not "none" — if it prints none, `source_up` isn't working and step 3 needs revisiting).

- [ ] **Step 5: No git commit** — all of these paths are outside `docker-gitops`. Proceed to Task 5.

---

## Task 5: CCR compose stack

**Files:**
- Create: `vps_oracle/compose/ccr/docker-compose.yml`
- Create: `vps_oracle/compose/ccr/.env.example`
- Create: `vps_oracle/compose/ccr/.gitignore` (repo-root `.gitignore` already covers `.env`/`*.env`, but this stack's directory gets its own to make the exclusion locally obvious — matches no existing precedent, so skip it; rely on root `.gitignore` instead, confirmed to already match)

**Interfaces:**
- Produces: a CCR gateway reachable at `http://127.0.0.1:3456` from the host (consumed by Task 4/7's `bridget.env`), and a management UI at `http://127.0.0.1:3458` (consumed manually by Task 6).

- [ ] **Step 1: Generate the management-UI auth token**

```bash
openssl rand -hex 32
```

Keep this value — it goes into `.env` in Step 3.

- [ ] **Step 2: Write the compose file**

```yaml
services:
  ccr:
    build:
      context: https://github.com/musistudio/claude-code-router.git#v3.0.20
    image: claude-code-router:3.0.20   # 构建自 pin 死的 git tag；上游没有发布镜像，这是等价的"锁版本"
    container_name: ccr
    hostname: ccr
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
    env_file:
      - .env   # 需要 CCR_WEB_AUTH_TOKEN（管理面板/RPC 口令）和 ZHIPU_API_KEY（智谱 key），见 .env.example
    environment:
      TZ: "Asia/Hong_Kong"
      CCR_PUBLIC_BASE_URL: "http://127.0.0.1:3458"
    ports:
      # 例外：claude 进程跑在宿主机上、不在容器里，够不到 proxy 网络，只能发布到宿主机端口。
      # 两个端口都只绑 127.0.0.1，不对外暴露；管理面板(3458)如需从别的机器访问，走 SSH 端口转发。
      - "127.0.0.1:3456:8080"   # gateway，jerome/bridget 的 .env 文件里 ANTHROPIC_BASE_URL 指这里
      - "127.0.0.1:3458:8080"   # management UI/RPC — 实际由 CCR 自己在容器内区分路由，见上游 docker/README.md
    volumes:
      - ccr-data:/data   # 装 SQLite 配置 + API key + 日志，属于敏感状态，故意不用仓库内可见的 bind mount
    networks:
      - proxy

networks:
  proxy:
    external: true

volumes:
  ccr-data:
```

> Note for the implementer: upstream's own `docker/README.md` maps both the gateway and the management UI through the same internal port via its bundled nginx (`3458:8080` in its example). Confirm the exact internal port split (gateway vs. mgmt) against `docker/README.md` and `docker/nginx.conf` in the CCR repo at tag `v3.0.20` before finalizing — if they're actually on different internal ports, adjust the two `ports:` lines accordingly. Do not guess; read the file.

- [ ] **Step 3: Write `.env.example` (committed) and the real `.env` (gitignored)**

```bash
cat > vps_oracle/compose/ccr/.env.example <<'EOF'
CCR_WEB_AUTH_TOKEN=replace-with-output-of-openssl-rand-hex-32
ZHIPU_API_KEY=replace-with-zhipu-api-key
EOF
```

```bash
cat > vps_oracle/compose/ccr/.env <<EOF
CCR_WEB_AUTH_TOKEN=<粘贴 Step 1 生成的值>
ZHIPU_API_KEY=<粘贴智谱后台的真实 key，不要照抄这个占位符>
EOF
```

- [ ] **Step 4: Confirm the file is actually ignored before it ever touches git**

```bash
git check-ignore -v vps_oracle/compose/ccr/.env
```

Expected: prints a match against the root `.gitignore`'s `.env` or `*.env` rule. If this prints nothing, **stop** — do not proceed to `git add` anything in this directory until it does.

- [ ] **Step 5: Bring the stack up and confirm the container starts**

Per CLAUDE.md, confirm with the user before applying changes that start new containers — this creates a new stack rather than recreating an existing one, but check in before running it if uncertain.

```bash
cd vps_oracle/compose/ccr && docker compose up -d
docker compose logs --tail=50 ccr
docker ps --filter name=ccr --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
```

Expected: container `Up`, ports `127.0.0.1:3456->...` and `127.0.0.1:3458->...` listed.

- [ ] **Step 6: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/ccr/docker-compose.yml vps_oracle/compose/ccr/.env.example
git status --short   # confirm .env is NOT staged
git commit -m "$(cat <<'EOF'
Add claude-code-router (CCR) compose stack

Fronts the Zhipu subscription behind a local gateway so Claude Code's
bridget group can route to it without any repo file holding the raw
Zhipu key more than once.
EOF
)"
```

---

## Task 6: One-time CCR provider/routing setup + issue a client key

CCR v3.0.20 configures providers and routing rules through its own web UI (SQLite-backed), not a hand-editable static file — confirmed by reading the upstream repo during planning; there is no verified JSON schema to script against. This task is a guided manual walkthrough with a scripted, zero-ambiguity verification at the end.

**Files:** none in this repo. Produces a value (the CCR client key) consumed by Task 7.

**Interfaces:**
- Produces: a CCR-issued client API key (string), to be pasted into `~/.claude-provider/bridget.env` in Task 7 as `ANTHROPIC_AUTH_TOKEN`.

- [ ] **Step 1: Reach the management UI**

From a machine that can reach the VPS, open an SSH tunnel (the UI is bound to `127.0.0.1` on the host, per Task 5's deliberate port binding):

```bash
ssh -L 3458:127.0.0.1:3458 ubuntu@<vps_oracle 的 SSH 地址>
```

Then browse to `http://127.0.0.1:3458` on the local machine. Log in / complete first-run setup using `CCR_WEB_AUTH_TOKEN` from `vps_oracle/compose/ccr/.env`.

- [ ] **Step 2: Add Zhipu as a provider**

In the UI: Providers → Add Provider. Zhipu's GLM coding-plan endpoint is Anthropic-Messages-compatible — select that protocol, enter the `ZHIPU_API_KEY` from `vps_oracle/compose/ccr/.env` as the credential, and select/confirm the GLM model(s) offered. Save.

- [ ] **Step 3: Configure routing per the spec's default rule**

In the UI: Routing. Per spec §5 open-item default: route `background` to the cheaper/lighter GLM tier, and `default` / `think` / `longContext` to the primary GLM tier. If the UI only exposes a subset of these categories for this provider, use whatever subset it supports and note the discrepancy in Task 12's README rather than blocking on it.

- [ ] **Step 4: Issue a client key for Claude Code**

In the UI: the client-keys section (separate from `CCR_WEB_AUTH_TOKEN`, which only protects the management UI). Create a new client key scoped for this use. Copy its value — this is the token Task 7 puts in `bridget.env`.

- [ ] **Step 5: Verify the gateway answers with that key — zero downstream cost, uses curl not claude**

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST http://127.0.0.1:3456/v1/messages \
  -H "Authorization: Bearer <client key from Step 4>" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-3-5-sonnet-20241022","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}'
```

Expected: a `200` (or another 2xx) — not `401`/`403` (bad key) and not `000`/connection-refused (gateway down or routing rule missing for this model name). If it's not 2xx, fix the routing/provider setup in Steps 2–3 before proceeding; do not paste a non-working key into `bridget.env` in Task 7.

- [ ] **Step 6: No git commit** — this task's output is a secret value, not a file change.

---

## Task 7: Wire `bridget.env` to CCR and prove the full chain end-to-end

**Files:**
- Modify: `/home/ubuntu/.claude-provider/bridget.env`

**Interfaces:**
- Consumes: the CCR client key from Task 6 Step 4.
- Produces: the first real, working instance of the toggle state that Task 8/9's UI will manage going forward.

- [ ] **Step 1: Write the CCR-routed state into `bridget.env`**

```bash
cat > /home/ubuntu/.claude-provider/bridget.env <<EOF
export ANTHROPIC_BASE_URL=http://127.0.0.1:3456
export ANTHROPIC_AUTH_TOKEN=<Task 6 Step 4 的 client key>
EOF
```

- [ ] **Step 2: Confirm direnv picks it up without re-running `direnv allow`** (this is the C2 constraint from spec §2.6 — confirms the file, not `.envrc`, was the only thing touched)

```bash
cd /home/ubuntu/bridget && BASH_ENV=/home/ubuntu/.claude/direnv-bash-env.sh bash -c 'echo "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"'
```

Expected: `ANTHROPIC_BASE_URL=http://127.0.0.1:3456` with **no** direnv trust-prompt error in the output.

- [ ] **Step 3: Zero-token, real-process proof for a `bridget`-group project**

Requires at least one project directory to exist under `~/bridget/` — if none exists yet, create a throwaway one for this test only:

```bash
mkdir -p /home/ubuntu/bridget/_verify-task7
cd /home/ubuntu/bridget/_verify-task7
timeout 20 /home/ubuntu/.claude/claude-direnv-wrapper.sh env | grep ANTHROPIC
```

Expected: both `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` printed with the values from Step 1. (`env` here stands in for the real claude binary — this checks what environment the wrapper hands to whatever it execs, without spending any tokens.)

```bash
rm -rf /home/ubuntu/bridget/_verify-task7
```

- [ ] **Step 4: Confirm `jerome.env` is unaffected (the core isolation guarantee — R1)**

```bash
cd /home/ubuntu/jerome && BASH_ENV=/home/ubuntu/.claude/direnv-bash-env.sh bash -c 'echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-(still unset, still official)}"'
```

Expected: `(still unset, still official)`. This is the one check in the whole plan that most directly validates the user's original stated fear did not materialize.

- [ ] **Step 5: No git commit** — outside the repo.

---

## Task 8: `provider-switch` — status-scanning core (pure logic, no HTTP yet)

Split out from the HTTP layer (Task 9) because this module's correctness — "does it report the true state" — is the entire point of R3/R4 and deserves its own tests independent of the web framework wrapper around it.

**Files:**
- Create: `vps_oracle/compose/provider-switch/status.py`
- Test: `vps_oracle/compose/provider-switch/test_status.py`

**Interfaces:**
- Produces (consumed by Task 9):
  - `GROUPS = {"jerome": "/home/ubuntu/.claude-provider/jerome.env", "bridget": "/home/ubuntu/.claude-provider/bridget.env"}`
  - `read_config(env_path: str) -> dict` — returns `{"routed": bool, "base_url": str | None}` by parsing the file for an `ANTHROPIC_BASE_URL=` line (handles both `export X=Y` and bare `X=Y`, ignores comments/blank lines).
  - `check_connectivity(base_url: str, timeout: float = 2.0) -> bool` — `True` if a request to `base_url` gets any HTTP response within `timeout` seconds, `False` on any connection error/timeout. Official (no `base_url`) is always reported connective (there's nothing to probe — OAuth's validity isn't this tool's concern).
  - `count_pending_sessions(group_dir: str) -> int` — counts currently-running `claude` processes whose cwd is under `group_dir`, by scanning `pgrep -f native-binary/claude` and comparing `/proc/<pid>/cwd` against `group_dir` as a path prefix.
  - `scan_group(name: str, env_path: str, group_dir: str) -> dict` — combines the three above into `{"name": name, "routed": bool, "base_url": str|None, "reachable": bool, "pending_official_sessions": int}`.

- [ ] **Step 1: Write the failing tests**

```python
cat > vps_oracle/compose/provider-switch/test_status.py <<'EOF'
import os
import subprocess
import sys
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread

sys.path.insert(0, os.path.dirname(__file__))
import status


class TestReadConfig(unittest.TestCase):
    def test_empty_file_is_official(self):
        path = "/tmp/test-empty.env"
        open(path, "w").write("# just a comment\n")
        self.addCleanup(os.remove, path)
        result = status.read_config(path)
        self.assertEqual(result, {"routed": False, "base_url": None})

    def test_missing_file_is_official(self):
        result = status.read_config("/tmp/does-not-exist.env")
        self.assertEqual(result, {"routed": False, "base_url": None})

    def test_export_line_is_routed(self):
        path = "/tmp/test-routed.env"
        open(path, "w").write(
            "export ANTHROPIC_BASE_URL=http://127.0.0.1:3456\n"
            "export ANTHROPIC_AUTH_TOKEN=abc123\n"
        )
        self.addCleanup(os.remove, path)
        result = status.read_config(path)
        self.assertEqual(result, {"routed": True, "base_url": "http://127.0.0.1:3456"})

    def test_bare_assignment_without_export_also_counts(self):
        path = "/tmp/test-bare.env"
        open(path, "w").write("ANTHROPIC_BASE_URL=http://127.0.0.1:3456\n")
        self.addCleanup(os.remove, path)
        result = status.read_config(path)
        self.assertTrue(result["routed"])


class TestConnectivity(unittest.TestCase):
    def test_official_always_reachable(self):
        self.assertTrue(status.check_connectivity(None))

    def test_live_endpoint_is_reachable(self):
        server = HTTPServer(("127.0.0.1", 0), BaseHTTPRequestHandler)
        port = server.server_port
        Thread(target=server.handle_request, daemon=True).start()
        time.sleep(0.1)
        self.assertTrue(status.check_connectivity(f"http://127.0.0.1:{port}"))
        server.server_close()

    def test_dead_endpoint_is_unreachable(self):
        self.assertFalse(status.check_connectivity("http://127.0.0.1:1", timeout=0.5))


class TestPendingSessions(unittest.TestCase):
    def test_counts_zero_when_nothing_running(self):
        count = status.count_pending_sessions("/tmp/definitely-no-claude-here")
        self.assertEqual(count, 0)


class TestScanGroup(unittest.TestCase):
    def test_official_group_shape(self):
        path = "/tmp/test-scan-official.env"
        open(path, "w").write("")
        self.addCleanup(os.remove, path)
        result = status.scan_group("jerome", path, "/tmp/nonexistent-group-dir")
        self.assertEqual(result["name"], "jerome")
        self.assertFalse(result["routed"])
        self.assertIsNone(result["base_url"])
        self.assertTrue(result["reachable"])
        self.assertIsInstance(result["pending_official_sessions"], int)


if __name__ == "__main__":
    unittest.main()
EOF
```

- [ ] **Step 2: Run to verify it fails (module doesn't exist yet)**

```bash
cd vps_oracle/compose/provider-switch && python3 test_status.py
```

Expected: `ModuleNotFoundError: No module named 'status'`.

- [ ] **Step 3: Implement `status.py`**

```python
cat > vps_oracle/compose/provider-switch/status.py <<'EOF'
"""Live-state scanning for the jerome/bridget provider groups.

No caching anywhere in this module by design — every call re-reads the
filesystem and re-probes the network, because the UI's whole point is
to never show a stale toggle position (R3/R4 in the design spec).
"""
import os
import re
import subprocess
import urllib.error
import urllib.request

GROUPS = {
    "jerome": {
        "env_path": "/home/ubuntu/.claude-provider/jerome.env",
        "group_dir": "/home/ubuntu/jerome",
    },
    "bridget": {
        "env_path": "/home/ubuntu/.claude-provider/bridget.env",
        "group_dir": "/home/ubuntu/bridget",
    },
}

_BASE_URL_RE = re.compile(r'^\s*(?:export\s+)?ANTHROPIC_BASE_URL=(\S+)\s*$')


def read_config(env_path):
    if not os.path.exists(env_path):
        return {"routed": False, "base_url": None}
    with open(env_path) as f:
        for line in f:
            m = _BASE_URL_RE.match(line)
            if m:
                return {"routed": True, "base_url": m.group(1)}
    return {"routed": False, "base_url": None}


def check_connectivity(base_url, timeout=2.0):
    if base_url is None:
        return True
    try:
        urllib.request.urlopen(base_url, timeout=timeout)
        return True
    except urllib.error.HTTPError:
        return True  # 服务器活着，能应答就算连通，不管状态码
    except Exception:
        return False


def count_pending_sessions(group_dir):
    try:
        pids = subprocess.run(
            ["pgrep", "-f", "native-binary/claude"],
            capture_output=True, text=True, check=False,
        ).stdout.split()
    except FileNotFoundError:
        return 0
    count = 0
    for pid in pids:
        try:
            cwd = os.readlink(f"/proc/{pid}/cwd")
        except OSError:
            continue
        if cwd == group_dir or cwd.startswith(group_dir + "/"):
            count += 1
    return count


def scan_group(name, env_path, group_dir):
    config = read_config(env_path)
    reachable = check_connectivity(config["base_url"])
    pending = count_pending_sessions(group_dir)
    return {
        "name": name,
        "routed": config["routed"],
        "base_url": config["base_url"],
        "reachable": reachable,
        "pending_official_sessions": pending,
    }
EOF
```

- [ ] **Step 4: Run tests, verify all pass**

```bash
cd vps_oracle/compose/provider-switch && python3 test_status.py -v
```

Expected: all tests `ok`, zero failures/errors.

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/provider-switch/status.py vps_oracle/compose/provider-switch/test_status.py
git commit -m "$(cat <<'EOF'
Add live status-scanning core for provider-switch

Reads group .env files, probes connectivity, and counts still-running
claude sessions on every call — no cached/remembered state anywhere,
per the design's requirement that the UI never lies about what's live.
EOF
)"
```

---

## Task 9: `provider-switch` — HTTP app, toggle logic, Dockerfile, compose

**Files:**
- Create: `vps_oracle/compose/provider-switch/app.py`
- Create: `vps_oracle/compose/provider-switch/test_app.py`
- Create: `vps_oracle/compose/provider-switch/Dockerfile`
- Create: `vps_oracle/compose/provider-switch/docker-compose.yml`

**Interfaces:**
- Consumes: `status.py`'s `GROUPS`, `scan_group` (Task 8).
- Produces: an HTTP service — `GET /` (HTML status page) and `POST /toggle` (form field `group`, flips that group's `.env` between empty and a CCR-routed block) — that Task 10 puts behind NPM.

- [ ] **Step 1: Write the failing tests for the toggle logic (not yet the HTTP layer)**

```python
cat > vps_oracle/compose/provider-switch/test_app.py <<'EOF'
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import app


class TestToggle(unittest.TestCase):
    def setUp(self):
        self.path = "/tmp/test-toggle.env"
        open(self.path, "w").write("")
        self.addCleanup(lambda: os.path.exists(self.path) and os.remove(self.path))

    def test_toggle_from_official_writes_ccr_block(self):
        app.toggle_group(self.path, ccr_base_url="http://127.0.0.1:3456", ccr_token="tok-abc")
        content = open(self.path).read()
        self.assertIn("ANTHROPIC_BASE_URL=http://127.0.0.1:3456", content)
        self.assertIn("ANTHROPIC_AUTH_TOKEN=tok-abc", content)

    def test_toggle_from_ccr_clears_file(self):
        open(self.path, "w").write(
            "export ANTHROPIC_BASE_URL=http://127.0.0.1:3456\n"
            "export ANTHROPIC_AUTH_TOKEN=tok-abc\n"
        )
        app.toggle_group(self.path, ccr_base_url="http://127.0.0.1:3456", ccr_token="tok-abc")
        content = open(self.path).read()
        self.assertNotIn("ANTHROPIC_BASE_URL", content)
        self.assertNotIn("ANTHROPIC_AUTH_TOKEN", content)

    def test_toggle_is_atomic_no_tmp_file_left_behind(self):
        app.toggle_group(self.path, ccr_base_url="http://127.0.0.1:3456", ccr_token="tok-abc")
        self.assertFalse(os.path.exists(self.path + ".tmp"))


if __name__ == "__main__":
    unittest.main()
EOF
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd vps_oracle/compose/provider-switch && python3 test_app.py
```

Expected: `ModuleNotFoundError: No module named 'app'`.

- [ ] **Step 3: Implement `app.py`**

```python
cat > vps_oracle/compose/provider-switch/app.py <<'EOF'
"""Toggle UI for the jerome/bridget Claude provider groups.

Single-file stdlib HTTP server, matching this repo's existing
vikunja-notify-relay pattern. GET / always re-scans; nothing is cached
or remembered between requests, by design (see status.py).
"""
import os
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import status

CCR_BASE_URL = os.environ["CCR_BASE_URL"]
CCR_TOKEN = os.environ["CCR_TOKEN"]


def toggle_group(env_path, ccr_base_url, ccr_token):
    current = status.read_config(env_path)
    tmp_path = env_path + ".tmp"
    if current["routed"]:
        content = "# 空 = 走官方订阅 OAuth。provider-switch UI 是唯一应该改写这个文件的东西。\n"
    else:
        content = (
            f"export ANTHROPIC_BASE_URL={ccr_base_url}\n"
            f"export ANTHROPIC_AUTH_TOKEN={ccr_token}\n"
        )
    with open(tmp_path, "w") as f:
        f.write(content)
    os.replace(tmp_path, env_path)


def render_page(scans):
    rows = []
    for s in scans:
        state = "CCR (Zhipu)" if s["routed"] else "Official"
        health = "reachable" if s["reachable"] else "UNREACHABLE"
        pending = s["pending_official_sessions"]
        pending_note = f"{pending} session(s) still running with the old provider" if pending else "no running sessions"
        rows.append(f"""
        <tr>
          <td>{s['name']}</td>
          <td>{state}</td>
          <td>{health}</td>
          <td>{pending_note}</td>
          <td><form method="post" action="/toggle"><input type="hidden" name="group" value="{s['name']}">
              <button type="submit">Switch to {"Official" if s["routed"] else "CCR (Zhipu)"}</button></form></td>
        </tr>""")
    return f"""<!doctype html><html><head><title>Claude Provider Switch</title></head>
<body>
<h1>Claude Provider Switch</h1>
<p>State is re-scanned on every page load — nothing here is cached.</p>
<table border="1" cellpadding="6">
<tr><th>Group</th><th>Provider</th><th>Endpoint</th><th>Pending sessions</th><th>Action</th></tr>
{''.join(rows)}
</table>
<p>Switching only affects sessions started after the switch.</p>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def do_GET(self):
        if self.path != "/":
            self.send_response(404)
            self.end_headers()
            return
        scans = [
            status.scan_group(name, cfg["env_path"], cfg["group_dir"])
            for name, cfg in status.GROUPS.items()
        ]
        body = render_page(scans).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/toggle":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        fields = urllib.parse.parse_qs(raw.decode())
        group = (fields.get("group") or [""])[0]
        if group not in status.GROUPS:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"unknown group")
            return
        toggle_group(status.GROUPS[group]["env_path"], CCR_BASE_URL, CCR_TOKEN)
        self.send_response(303)
        self.send_header("Location", "/")
        self.end_headers()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"listening on :{port}", flush=True)
    server.serve_forever()
EOF
```

- [ ] **Step 4: Run tests, verify all pass**

```bash
cd vps_oracle/compose/provider-switch && python3 test_app.py -v
```

Expected: all `ok`.

- [ ] **Step 5: Write the Dockerfile (mirrors `notify-relay`'s pattern)**

```bash
cat > vps_oracle/compose/provider-switch/Dockerfile <<'EOF'
FROM python:3.12.7-alpine3.20
WORKDIR /app
COPY status.py app.py .
CMD ["python3", "app.py"]
EOF
```

Note: unlike `notify-relay`, this cannot run as `USER nobody` — it must write files owned by `ubuntu` (uid 1001) under `~/.claude-provider/` on the host, so it needs to run as that uid. Handled via `user:` in the compose file below rather than in the image.

- [ ] **Step 6: Write the compose file**

```bash
cat > vps_oracle/compose/provider-switch/docker-compose.yml <<'EOF'
services:
  provider-switch:
    build: .
    image: provider-switch:1.0.0
    container_name: provider-switch
    hostname: provider-switch
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
    user: "1001:1001"   # 需要以宿主机 ubuntu 用户写 ~/.claude-provider/ 下的文件，不能用 nobody
    environment:
      TZ: "Asia/Hong_Kong"
      PORT: "8080"
      CCR_BASE_URL: "http://127.0.0.1:3456"
      CCR_TOKEN: "${CCR_CLIENT_TOKEN}"   # Task 6 生成的 CCR client key，走 .env
    env_file:
      - .env
    volumes:
      - /home/ubuntu/.claude-provider:/home/ubuntu/.claude-provider
    networks:
      - proxy
    # NPM 反代配置见 vps_oracle/compose/ccr/README.md 里的 "接入 NPM" 一节

networks:
  proxy:
    external: true
EOF

cat > vps_oracle/compose/provider-switch/.env.example <<'EOF'
CCR_CLIENT_TOKEN=replace-with-the-CCR-client-key-from-task-6
EOF

cat > vps_oracle/compose/provider-switch/.env <<EOF
CCR_CLIENT_TOKEN=<Task 6 生成的 client key，跟 bridget.env 里的一致>
EOF
```

- [ ] **Step 7: Confirm `.env` is gitignored**

```bash
git check-ignore -v vps_oracle/compose/provider-switch/.env
```

Expected: a match. Stop if not.

- [ ] **Step 8: Bring the stack up**

Confirm with the user before applying (per CLAUDE.md — new container).

```bash
cd vps_oracle/compose/provider-switch && docker compose up -d
docker compose logs --tail=30 provider-switch
```

- [ ] **Step 9: curl-based end-to-end test against the running container**

```bash
curl -s http://127.0.0.1:8080/ | grep -o '<td>jerome</td>\|<td>bridget</td>'
```

(Adjust host port if the compose file above ends up needing one published for this direct test — the intended final access path is via NPM per Task 10, but a temporary published port, or `docker exec ... curl localhost:8080/`, works for this verification step. Use `docker exec provider-switch wget -qO- http://localhost:8080/` if no host port is published.)

Expected output includes both `<td>jerome</td>` and `<td>bridget</td>`.

Test the toggle round-trip against the **`bridget`** group only (never touch `jerome` in an automated test — accidentally leaving `jerome` routed to CCR would be exactly the failure mode this whole project exists to prevent):

```bash
docker exec provider-switch python3 -c "
import status
before = status.read_config(status.GROUPS['bridget']['env_path'])
print('before:', before)
"
# toggle once
docker exec provider-switch wget -qO- --post-data='group=bridget' http://localhost:8080/toggle > /dev/null
docker exec provider-switch python3 -c "
import status
after = status.read_config(status.GROUPS['bridget']['env_path'])
print('after:', after)
"
# toggle back to restore Task 7's state
docker exec provider-switch wget -qO- --post-data='group=bridget' http://localhost:8080/toggle > /dev/null
```

Expected: `before` and `after` differ in `routed`; after the second toggle, `bridget.env` matches what Task 7 Step 1 wrote (verify with `cat /home/ubuntu/.claude-provider/bridget.env`).

- [ ] **Step 10: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/provider-switch/app.py vps_oracle/compose/provider-switch/test_app.py \
        vps_oracle/compose/provider-switch/Dockerfile vps_oracle/compose/provider-switch/docker-compose.yml \
        vps_oracle/compose/provider-switch/.env.example
git status --short   # confirm .env is NOT staged
git commit -m "$(cat <<'EOF'
Add provider-switch web UI

Serves a toggle page that always re-scans jerome/bridget state live
(config + connectivity + pending sessions) rather than remembering the
last click, per the design's no-cached-state requirement.
EOF
)"
```

---

## Task 10: NPM reverse proxy + homepage cards

**Files:**
- Modify: `vps_oracle/compose/homepage/config/services.yaml`
- (NPM configuration is done in its admin panel, not a repo file — see README's "给服务接入 NPM 反代" section)

**Interfaces:** none — this is pure wiring/documentation, no code interfaces produced or consumed.

- [ ] **Step 1: Configure the NPM proxy host for `provider-switch`**

Follow README's table exactly (`Domain Names: provider.jerome.cloudns.asia`, `Forward Hostname/IP: provider-switch`, `Forward Port: 8080`, `Access List: self-only`, SSL per the table). Remember the known gotcha: re-open the record after saving to confirm Force SSL / HTTP/2 didn't silently reset.

- [ ] **Step 2: Decide the CCR management-UI card's link and note the caveat**

CCR's management UI is deliberately bound to `127.0.0.1` only (Task 5) — it is not proxied through NPM, so a public HTTPS URL doesn't work for it. Use the host's internal LAN IP directly (`http://10.0.0.95:3458`), consistent with the existing k3s NodePort precedent in this same README, and say so explicitly in the card description so a future reader isn't confused by a card that only works from inside the LAN / over SSH tunnel.

- [ ] **Step 3: Add both homepage cards**

```bash
cat >> vps_oracle/compose/homepage/config/services.yaml <<'EOF'

    - Provider Switch:
        icon: docker.png
        href: https://provider.jerome.cloudns.asia
        description: Toggle Claude Code jerome/bridget groups between official and Zhipu (CCR)
        container: provider-switch
        server: my-docker

    - CCR Admin:
        icon: docker.png
        href: http://10.0.0.95:3458
        description: claude-code-router management UI (LAN/SSH-tunnel only, not internet-exposed)
        container: ccr
        server: my-docker
EOF
```

Confirm indentation matches the existing entries exactly (2 leading spaces before `- <Name>:`, matching the tail of the file read during planning) before saving — re-read the file after appending to check.

- [ ] **Step 4: Apply and verify**

```bash
cd vps_oracle/compose/homepage && docker compose up -d
curl -s https://provider.jerome.cloudns.asia -o /dev/null -w '%{http_code}\n'   # from a machine allowed by the self-only access list
```

Expected: homepage dashboard shows both new cards; the HTTPS URL returns `200` (or a login/access-list challenge if not on the allowed network — confirms the access list is doing its job, not a failure).

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/homepage/config/services.yaml
git commit -m "添加 provider-switch 和 CCR 的 homepage 卡片"
```

---

## Task 11: Write `vps_oracle/compose/ccr/README.md`

Per spec §3.11 — the deliverable the user explicitly asked for, aimed at future-self adding a third group.

**Files:**
- Create: `vps_oracle/compose/ccr/README.md`

**Interfaces:** none — documentation only, terminal task in the plan.

- [ ] **Step 1: Write the README**

```bash
cat > vps_oracle/compose/ccr/README.md <<'EOF'
# CCR — claude-code-router

把智谱订阅接到本机 Claude Code 里，按项目分组（`jerome` / `bridget`）独立切换官方订阅 / CCR。完整设计过程见 [`docs/superpowers/specs/2026-08-09-claude-provider-group-switch-design.md`](../../../docs/superpowers/specs/2026-08-09-claude-provider-group-switch-design.md)。

## 原理速览

```
启动 claude
 ├─ 终端      → ~/.bashrc 的 direnv hook
 └─ VSCode    → claudeCode.claudeProcessWrapper → ~/.claude/claude-direnv-wrapper.sh
                        │
                        ↓ direnv 按 cwd 向上找最近的 .envrc（各组目录下静态放一个）
   ~/jerome/.envrc      → source_env_if_exists ~/.claude-provider/jerome.env
   ~/bridget/.envrc     → source_env_if_exists ~/.claude-provider/bridget.env
                        │                          ↑ provider-switch UI 的唯一写入点
                        ↓ ANTHROPIC_BASE_URL
              ├─ 未设置              → 官方订阅 OAuth
              └─ 127.0.0.1:3456     → 本目录的 CCR 容器 → 智谱 GLM（按规则分流）
```

`.envrc` 文件本身**永远不改**——改它会让 direnv 拒绝加载（信任机制导致的），所有切换都是改它 `source_env_if_exists` 引用的那个 `.env` 文件。

## 加一个新分组

以新增 `~/sandbox/` 组为例：

```bash
mkdir -p ~/sandbox
echo 'source_env_if_exists ~/.claude-provider/sandbox.env' > ~/sandbox/.envrc
direnv allow ~/sandbox
touch ~/.claude-provider/sandbox.env          # 空文件 = 走官方订阅

# 在 vps_oracle/compose/provider-switch/status.py 的 GROUPS 字典里加一条：
#   "sandbox": {"env_path": "/home/ubuntu/.claude-provider/sandbox.env", "group_dir": "/home/ubuntu/sandbox"}
# 改完:
cd vps_oracle/compose/provider-switch && docker compose up -d --build
```

命名约定：分组名 = 目录名 = env 文件名，照抄上面的模式就不会出岔子。

## 四个坑

1. **`.envrc` 只能写那一行 `source_env_if_exists ...`，任何后续改动都要重新 `direnv allow`**——不然 direnv 会整个拒绝加载这个 `.envrc`，变量全部消失（不是变错，是消失；实测见设计文档 §2.6）。
2. **组内项目如果自己也有 `.envrc`，会遮蔽组级的那一个**（direnv 只认最近的一个，不叠加）。已知的例子是 `betting-lab`，靠在它的 `.envrc` 首行加 `source_up` 解决。新项目如果需要自己的 `.envrc`，记得也加这一行。
3. **切换只对新开的会话生效**。已经在跑的 claude 进程环境是启动时定死的，UI 上切一下不会影响它们——这也是为什么 provider-switch 的页面要显示"还有几个会话挂在旧 provider 上"。
4. **把已有项目搬到别的组目录下会断开会话历史**。`~/.claude/projects/` 下的目录名是按路径编码的，项目目录一动，`--resume` 就找不到旧会话了（文件还在，只是找不到）。要搬项目，提前想清楚。

## 验证一个组是否真的挂对了 provider（零 token 成本）

```bash
for p in $(pgrep -f 'native-binary/claude'); do
  cwd=$(readlink /proc/$p/cwd 2>/dev/null)
  echo "pid=$p cwd=$cwd"
  tr '\0' '\n' < /proc/$p/environ | grep ANTHROPIC_BASE_URL || echo "  -> 官方订阅（未设置）"
done
```

## 改组名 / 删组

direnv 的授权记录是按 `.envrc` 的**绝对路径**存的（`~/.local/share/direnv/allow/`），改目录名等于换了一个新 `.envrc`，要重新 `direnv allow`。同时会触发上面第 4 条的会话历史问题。要改趁项目/会话还少的时候改。

删组：从 `status.py` 的 `GROUPS` 里删掉那一条，`docker compose up -d --build` 重启 provider-switch；`~/.claude-provider/<组名>.env` 和 `~/<组名>/.envrc` 手动删除或留着都行（留着不会被扫描到，纯粹是死文件）。

## 回滚整个机制

1. 把 `~/.vscode-server/data/Machine/settings.json` 里的 `claudeCode.claudeProcessWrapper` 删掉，Reload Window——VSCode 路径回到直接启动 claude，不再经过 wrapper。
2. 终端路径本来就不依赖这套机制（走 `.bashrc` 自带的 direnv hook），不用管。
3. `docker compose down` 这个目录和 `provider-switch/` 目录，两个容器都停了，`~/.claude-provider/*.env` 留空即可，所有项目回到纯官方订阅。
EOF
```

- [ ] **Step 2: Add the pointer from `provider-switch/`**

```bash
cat > vps_oracle/compose/provider-switch/README.md <<'EOF'
# provider-switch

原理、加分组步骤、已知坑，见 [`../ccr/README.md`](../ccr/README.md)——两个栈是同一套机制的两半，文档只写一份，避免两边说法漂移。
EOF
```

- [ ] **Step 3: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/ccr/README.md vps_oracle/compose/provider-switch/README.md
git commit -m "$(cat <<'EOF'
Document CCR provider-group mechanism and how to add a new group

Written for future-self extending past jerome/bridget: the four
concrete gotchas hit during design (static .envrc, project-level
shadowing, session-restart requirement, resume-history breakage) and
a copy-pasteable procedure for the next group.
EOF
)"
```

---

## Plan-Level Self-Review Notes

- **Spec coverage:** R1 (Task 4/7 Step 4 directly tests isolation), R2 (Task 9), R3/R4 (Task 8's no-cache scan + Task 9's per-request re-scan), R5 (Alpine + stdlib, no framework, matches `notify-relay`'s ~88MB precedent), R6 (Tasks 1–4, 7). C1–C8 each have an explicit owning task or step (C7 → Task 3, C6 → Task 3 Step 8, C3 → Task 4 Step 3, C2 → Task 4/7 verification steps, C4/C5 → documented in Task 11 rather than "fixed" since they're inherent tradeoffs, C8 → flag to user after Task 6, not a task of its own since it's a manual account-security action outside this repo's scope).
- **Known gap flagged inline, not hidden:** Task 5 Step 2 contains an explicit note that the exact internal port split for CCR's gateway vs. management UI must be confirmed against the upstream repo's `docker/README.md` at execution time rather than trusted blindly — this project moves fast (5 tags in 2 weeks observed during planning) and I did not get a fully certain answer via search. This is called out rather than silently guessed.
- **CCR routing-category coverage:** Task 6 Step 3 explicitly allows for the UI not exposing exactly `background`/`think`/`longContext` as named categories, with a fallback instruction rather than blocking.

---

Plan complete and saved to `docs/superpowers/plans/2026-08-09-claude-provider-group-switch.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
