# Claude Code Group-level Provider Switching — Design Document

- Date: 2026-08-09
- Status: design confirmed, pending implementation
- Hosts involved: vps_oracle (`instance-20260321-2043`, private IP 10.0.0.95)

---

## 1. Background & Motivation

The token quota from the official Claude Code subscription is insufficient, and the unit price of buying extra tokens is high. The alternative is to buy a second subscription from Zhipu AI and have Claude Code switch to Zhipu's models when needed.

But the "switch" cannot be global. There are ~19 projects under `~/jerome/` on this machine, varying widely in importance and complexity:

- Some projects (complex refactors, architectural design, production systems) must use Claude's official premium models
- Others (practice problems, copywriting, experimental projects) are fully served by Zhipu, saving a lot of quota

**The core requirement is isolation**: downgrading group B to Zhipu must never drag group A down with it. The user's explicitly stated concern is — "What I worry about is that after I downgrade one group, it will by default affect the other group's projects that need the more premium model."

This concern defines the whole design's evaluation criterion: **any mechanism that can silently leak across groups is unacceptable**, even if it is cleaner.

### 1.1 Requirements List

| # | Requirement | Source |
|---|---|---|
| R1 | Provider config for the two groups is mutually isolated | User's core requirement |
| R2 | A UI to toggle per group (official / CCR) | User explicitly requested |
| R3 | The UI shows the **real situation**, not "what was last clicked" | User explicitly requested |
| R4 | The UI queries live on every open, records no state | User explicitly requested |
| R5 | CCR deployed via Docker, as resource-light as possible | User explicitly requested |
| R6 | Directory-level environment switching uses direnv | User explicitly requested (later validated and kept) |

---

## 2. Exploration Process

This section records the detours taken and the evidence gathered during design. The conclusion was not right from the start; it was overturned twice along the way.

### 2.1 Starting point: direnv looked like the obvious answer

The user already has a mature direnv practice for isolating git tokens per directory:

- `~/.claude/direnv-bash-env.sh`: runs `direnv export bash` for the current directory and evals it
- The `env` of `~/.claude/settings.json` sets `BASH_ENV` to point at it

The principle is bash's built-in behavior — **when a non-interactive bash starts and `BASH_ENV` is set, it sources the file it points at first**. This exactly matches Claude Code's pattern of spawning a fresh `bash -c` for every Bash tool call. This approach has already handled two gotchas:

1. **Infinite recursion**: `direnv export` internally spawns another bash to parse `.envrc`, and it inherits the same `BASH_ENV`, so it calls `direnv export` again…… the fix is `BASH_ENV= direnv export bash` to clear it for that layer
2. **stdin hang**: the stdin underlying bash is a pipe that never sends EOF, so `direnv export` deadlocks waiting on stdin. The fix is `</dev/null`

The natural thought: copying this mechanism for provider switching should work.

### 2.2 First reversal: BASH_ENV can't lift the provider

Checking the process tree surfaced the problem:

```
3707132  server-main.js                     ← VSCode server, shared by all windows
└─ 4000770  extensionHost                   ← starts when SSH connects, environment fixed thereafter
   └─ 4003147  .../native-binary/claude --setting-sources=user,project,local ...
```

The user uses the VSCode extension, and `claude` is a child process **directly spawned** by extensionHost — **no bash in between**. With no bash process, `BASH_ENV`'s bash built-in behavior never fires.

The deeper reason is the **process direction**:

| | git token scenario | provider scenario |
|---|---|---|
| Variable consumer | `git` (a **downstream** of bash) | the `claude` process itself (an **upstream** of bash) |
| Can BASH_ENV override it | ✅ | ❌ a child process can't change its parent's environment |

Live evidence — in `/proc/4004115/environ`, the `ANTHROPIC*` / `DIRENV*` variables are entirely blank.

A boundary of the `BASH_ENV` mechanism itself was also measured:

| Scenario | direnv variables visible? |
|---|---|
| Bash tool subprocess, and **the starting cwd already has `.envrc`** | ✅ |
| After `cd`ing into it **within** a Bash tool | ❌ `BASH_ENV` has already run at process start |

That is: `BASH_ENV` evaluates the cwd at bash **startup**; `cd`ing later inside the command does not re-evaluate.

### 2.3 Midway approach: project-level settings.local.json (later rejected)

Noticing `--setting-sources=user,project,local` on the command line indicates project-level `.claude/settings.json` / `settings.local.json` are read, and `env` is a valid key (the user's global config already uses it to set `BASH_ENV`).

A probe with a fake endpoint (listen, watch where claude connects; the request never reaches the real API so zero token cost) confirmed:

```
CONNECTED from ('127.0.0.1', 51274)
POST /v1/messages?beta=true HTTP/1.1
Authorization: Bearer dummy-probe-token        ← token also overridden
User-Agent: claude-cli/2.1.226 (external, claude-vscode, agent-sdk/0.3.226)
```

**Confirmed effective**: project-level `settings.local.json`'s `env` can override both endpoint and auth token, and works for both the terminal and extension launch paths.

This also ruled out another candidate `claudeCode.environmentVariables` — it has `"scope": "machine"`, so in VSCode it **cannot be set per workspace**, useless for grouping; and its own description says "Prefer setting environment variables in Claude's settings.json".

The conclusion at the time was to abandon direnv and switch to settings.local.json. **This conclusion was later overturned.**

### 2.4 Second reversal: the user's question led to claudeProcessWrapper

The user pressed: can the BASH_ENV idea really not be reused?

Re-examining — **the direction judgment was right, but the conclusion converged too early**. It is true that BASH_ENV can't lift the provider, but the user's **idea** (find a hook that runs on every launch, evaluate direnv for the current directory inside that hook) is fully transplantable, as long as the claude process's own hook can be found.

Grepping the extension's `package.json` found:

```json
"claudeCode.claudeProcessWrapper": {
  "type": "string", "scope": "machine",
  "description": "Executable path used to launch the Claude process."
}
```

Then grepping `extension.js` (2.5MB of minified code) for the implementation of `resolveClaudeBinary()`:

```js
if (e) return { pathToClaudeCodeExecutable: e,
                executableArgs: r ? (n ? [n, r] : [r]) : [], env: t }
```

`e` is the configured wrapper path, and the real binary is packed into `executableArgs` and passed to it as an argument. **So the wrapper only needs to `exec "$@"`, no hard-coded claude path, and extension upgrades won't break it.**

Two other preconditions were also verified:
- The claude process's cwd is the workspace directory (`/proc/4003147/cwd -> /home/ubuntu/jerome/docker-gitops`)
- The terminal path already has a direnv hook (`eval "$(direnv hook bash)"` at `~/.bashrc:136`)

Live test of the wrapper mechanism:

```
CONNECTED
HEAD /api/hello HTTP/1.1
User-Agent: Bun/1.4.0
Host: 127.0.0.1:59998        ← the address written in .envrc
```

After the claude process started, it sent a connectivity pre-check to the endpoint specified by `.envrc`. **direnv's variables genuinely reached the claude process itself.**

So the approach returned to direnv. The final comparison of the four mechanisms:

| Mechanism | Terminal launch | VSCode extension | Per-directory capable |
|---|---|---|---|
| `BASH_ENV` + direnv | ✅ | ❌ no bash in between | ✅ |
| `claudeCode.environmentVariables` | ❌ | ✅ | ❌ machine scope |
| project-level `settings.local.json` `env` | ✅ | ✅ | ✅ |
| **`claudeProcessWrapper` + direnv** | ✅ (using existing hook) | ✅ | ✅ |

### 2.5 The decisive reason direnv wins

Returning to direnv is not just "it also works"; it is a tier stronger than settings.local.json, because **`.envrc` can evaluate dynamically**:

```bash
# .envrc for the project/top-level directory — written once, never changed again
source_env_if_exists ~/.claude-provider/jerome.env
```

So **switching one group = changing one file**, rather than walking 19 projects rewriting `settings.local.json`. This also solves three things at once:

1. The Zhipu key exists in exactly one place; rotation takes effect immediately, never scattered into 19 projects, never accidentally committed
2. In-group inconsistency is impossible (all projects read the same file); the `mixed` state (inconsistent in-group config) that would otherwise need designing simply disappears
3. R4 "records no state" becomes literally true — the UI reads the single config file, and the system holds no copy anywhere

### 2.6 direnv trust model: one hard constraint

Since the UI repeatedly rewrites the config file, it must first be confirmed whether direnv's trust mechanism requires a re-`direnv allow` every time. If it did, the toggle would be meaningless. Tested:

| Operation | Result |
|---|---|
| Normal read after `direnv allow` | `PROVIDER=official` ✅ |
| **Rewriting the file that `source_env_if_exists` references** (no re-allow) | `PROVIDER=zhipu` ✅ takes effect immediately |
| Changing `.envrc` itself | **variables disappear entirely** ❌ direnv refuses to load |

**This fixes one hard design constraint: `.envrc` must be static, written once and never touched; the UI only rewrites the file it sources.**

A bonus good property: if `.envrc` is ever broken, the variables **disappear** rather than becoming wrong, and claude falls back to the official subscription — the failure direction is safe, never silently leaking to Zhipu.

### 2.7 Two flips on CCR's positioning

- **At first** CCR was considered possibly redundant: Zhipu provides an Anthropic-compatible endpoint, so setting `ANTHROPIC_BASE_URL` directly is enough, saving a container
- **Midway** (under the settings.local.json approach) a reason to keep CCR was found: the real key would be written into 19 projects' config files, whereas going through CCR means the projects only write a local address, and the key is confined to the container
- **In the end** this reason evaporated with the direnv approach — under direnv the key was already single-copy

The user ultimately decided to keep CCR, and the **sole reason is model dispatch** (dispatching background / think / longContext to different model tiers). This is a deliberate trade-off: one extra container and one more failure point, in exchange for the ability to control cost by task type.

### 2.8 Grouping method

Three options were considered: a central yaml lookup table, per-project self-declaration, and path-prefix auto-grouping.

The user chose path prefix, and proposed an improvement — **don't create subdirectories under `~/jerome/`, but create a second directory at its sibling level**. This way none of the existing 19 projects need to move. Adopted.

---

## 3. Final Design

### 3.1 Overall data flow

```
start claude
 ├─ Terminal → direnv hook in ~/.bashrc (already present, unchanged)
 └─ VSCode   → claudeCode.claudeProcessWrapper → direnv-load.sh
                        │
                        ↓ direnv walks up from cwd to the nearest .envrc
   ~/jerome/.envrc      → source_env_if_exists ~/.claude-provider/jerome.env
   ~/bridget/.envrc     → source_env_if_exists ~/.claude-provider/bridget.env
                        │                          ↑ the UI's only write point
                        ↓ ANTHROPIC_BASE_URL
              ├─ unset               → official subscription OAuth (~/.claude/.credentials.json)
              └─ 127.0.0.1:3456     → CCR container → Zhipu GLM (dispatch by rule)
```

### 3.2 Directory layout

```
~/jerome/                 jerome group, 19 projects stay in place
    .envrc                ← new, the only change; static
    quant-trading-system/
    betting-lab/
        .envrc            ← already exists, needs source_up prepended on the first line
    ...

~/bridget/                bridget group
    .envrc                ← static
    <projects>/

~/.claude-provider/
    jerome.env            ← the UI only changes these two files
    bridget.env
```

**Naming convention**: group name = directory name = env filename (`~/<group>/` ↔ `~/.claude-provider/<group>.env`). Generalize this way when adding a third group, see 3.11.

Projects themselves **don't need** a `.envrc` — direnv walks up to the nearest one.

> ⚠️ direnv takes the **nearest** `.envrc`, **without stacking**. A project's own `.envrc` would shadow the top-level one. Among the current 19 projects only `betting-lab` is in this situation (its `.envrc` content is `source ./venv/bin/activate`), and needs `source_up` prepended on its first line.

### 3.3 Host scripts

Three files sharing one piece of logic; the two known gotchas (recursion, stdin) are confined to the kernel so it only needs fixing in one place.

**`~/.claude/direnv-load.sh`** — the only real logic, sourced

```bash
# Evaluate direnv for the current directory and inject env vars. Sourced, do not exit.
if command -v direnv >/dev/null 2>&1; then
  __d="$(BASH_ENV= timeout 5 direnv export bash 2>/dev/null </dev/null)"
  [ -n "$__d" ] && eval "$__d"
  unset __d
fi
```

**`~/.claude/direnv-bash-env.sh`** — existing file slimmed down, behavior unchanged

```bash
case $- in *i*) return 0 2>/dev/null || exit 0 ;; esac
. /home/ubuntu/.claude/direnv-load.sh
```

**`~/.claude/claude-direnv-wrapper.sh`** — new

```bash
#!/usr/bin/env bash
. /home/ubuntu/.claude/direnv-load.sh
exec "$@"          # real binary passed in as an argument by the extension
```

Config: VSCode setting `claudeCode.claudeProcessWrapper` = `/home/ubuntu/.claude/claude-direnv-wrapper.sh` (machine scope, set in the Remote [SSH] tab), Reload Window after changing.

### 3.4 Group config files

`~/.claude-provider/jerome.env`, `~/.claude-provider/bridget.env`.

**Initial state**: `jerome.env` is official, `bridget.env` is CCR.

**Official state** = the file is empty (or comments only). No `ANTHROPIC_*` set, claude goes through subscription OAuth.

**CCR state**:

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:3456
export ANTHROPIC_AUTH_TOKEN=<CCR local passphrase>
```

`<CCR local passphrase>` is a locally self-signed random string, unrelated to the Zhipu key, serving only to let CCR reject requests from non-local sources. It appears in both `~/.claude-provider/*.env` and CCR's config, and the two places must match. The real Zhipu key exists only in `vps_oracle/compose/ccr/.env`, not in any group file.

> Switching back to official is **emptying the file**, not setting the value to an empty string. Whether an empty string would still override the OAuth credentials is unverified; at implementation time it must be confirmed by live testing with the 2.3 probe technique.

### 3.5 CCR stack

`vps_oracle/compose/ccr/`

- Image pinned to a specific tag
- `ports: 127.0.0.1:3456:3456`
- Real Zhipu key in `vps_oracle/compose/ccr/.env` (`.gitignore` already covers `.env` and `*.env`)
- Dispatch rule: background goes to the cheap tier, the rest to the main tier (specific models TBD, see open items)

> ⚠️ **A deliberate exception to the repo convention**: the README stipulates "admin panels / internal services never publish ports, always go through NPM reverse proxy". CCR must publish a port because its consumer `claude` runs **on the host rather than in a container**, so it can't use the docker network. The mitigation is binding `127.0.0.1`, not exposing externally. This should be written into the compose file's comment.

It is confirmed that host port 3456 is free (the `vikunja` container also uses 3456 internally, but it is not published to the host, so no conflict).

### 3.6 Toggle UI

`vps_oracle/compose/provider-switch/`

Follow the existing pattern of `vikunja/notify-relay` in this repo: **a single `app.py`, `python:3.12-alpine`, pure standard library with no framework**. The reference image is ~88MB, resident memory in the tens of MB, satisfying R5.

| Endpoint | Behavior |
|---|---|
| `GET /` | live-scans and returns the page, **reads no cache** |
| `POST /toggle` | atomically rewrites the corresponding group's `.env` |

- Mount `~/.claude-provider/` into the container
- `notify-relay` uses `USER nobody`, but this service must write host files, so it must run as uid 1001 (`ubuntu`)

### 3.7 Judging the "real situation" (R3 / R4)

Each group shows three independent signals, all required:

1. **Config**: whether `<group>.env` has `ANTHROPIC_BASE_URL`
2. **Connectivity**: actually request the currently-pointed-at endpoint. If the CCR container is down it's a red light — reporting "switched to Zhipu" based only on config would be fake
3. **Pending effect**: the number of **running** claude processes under that group (`pgrep -f native-binary/claude` combined with comparing `/proc/<pid>/cwd`)

Signal 3 is required because **environment variables are read at process start; a switch only affects newly started sessions**. The UI must let the user see "there are still N sessions hanging onto the old provider", otherwise R3 cannot truly be satisfied.

### 3.8 Error handling

- Write files with "write tmp + `rename`" atomic replacement, avoiding direnv reading a half-written file
- CCR probe failure: show a red light but **don't block** the switch (the user may be trying to switch away)
- If `.envrc` is changed such that direnv refuses to load, it degrades to the official subscription — the safe direction

### 3.9 Testing strategy

| Layer | Method |
|---|---|
| Script | Given a cwd, assert the variable set after `direnv export` is correct |
| UI | Start the container, curl `/` and `/toggle`, assert the file content changes |
| End-to-end | switch → start a new session → inspect `/proc/<pid>/environ`, **zero token cost** |
| Wrapper | Two stages: first use a no-op wrapper (only `exec "$@"`) to confirm VSCode can start claude normally, then switch to the full version. Rollback = delete the setting + Reload Window |

### 3.10 Repo convention

Both new stacks must satisfy the README conventions: `TZ: "Asia/Hong_Kong"`, logging 10m×5, `restart: unless-stopped`, pin a specific tag, `security_opt: [no-new-privileges:true]`, attach the `proxy` external network.

- UI via NPM reverse proxy: `provider.jerome.cloudns.asia`, Access List `self-only`, configured per the README table (note that Force SSL / HTTP/2 silently reset after saving, need re-checking)
- Both services need homepage cards (`vps_oracle/compose/homepage/config/services.yaml`), descriptions in English
- CCR's port-publish exception is in 3.5

### 3.11 Deliverable: `vps_oracle/compose/ccr/README.md`

At implementation wrap-up, this document must be written, aimed at "myself, months later, wanting to add a third group". Content requirements:

1. **Big-picture walkthrough** — one paragraph explaining the direnv → wrapper → CCR chain, with the 3.1 data-flow diagram
2. **Complete steps to add a new group**, copy-paste-executable:
   ```bash
   # example: adding a ~/sandbox/ group
   mkdir -p ~/sandbox
   echo 'source_env_if_exists ~/.claude-provider/sandbox.env' > ~/sandbox/.envrc
   direnv allow ~/sandbox
   touch ~/.claude-provider/sandbox.env          # empty = official subscription
   # finally, register ~/sandbox in the UI's group config, restart the provider-switch container
   ```
3. **Four gotchas that must be called out** (one sentence + consequence each):
   - `.envrc` can only contain that one line; **any later change requires re-`direnv allow`**, otherwise the variables fail entirely (per 2.6)
   - If a project inside the group has its own `.envrc`, it **shadows the group-level one**, need to add `source_up` (per 3.2)
   - A switch **only affects newly started sessions**, existing processes unaffected (per C1)
   - Moving an existing project into a new group **breaks the `--resume` session history** (per C4)
4. **Verification method** — the zero-cost `/proc/<pid>/environ` check command, and how to confirm a new group is actually attached
5. **Renaming/deleting a group**, including the fact that `direnv allow` records are stored by absolute path (per C5)
6. **Rollback** — how to fully detach a group and how to disable the wrapper

> Placed under `ccr/` per the user's directive. `provider-switch/` only holds a one-line pointer link to it, to avoid two documents each saying their own thing.

---

## 4. Known Constraints & Risks

| # | Item | Note |
|---|---|---|
| C1 | A switch only affects **newly started sessions** | Environment variables are read at process start. The UI must explicitly prompt and show the number of running sessions |
| C2 | `.envrc` must be static | Changing it itself triggers direnv's trust check, making the variables fail entirely (per 2.6 testing) |
| C3 | A project's own `.envrc` shadows the top-level one | Currently only `betting-lab`, needs `source_up` |
| C4 | Moving a project / renaming a directory breaks session history | The `~/.claude/projects/` directory names are path-encoded; `--resume` can't find old sessions |
| C5 | Renaming a directory requires re-`direnv allow` | direnv authorization records are stored by the `.envrc`'s **absolute path** (confirmed by testing) |
| C6 | The wrapper changes how the permission mode is resolved | The extension source has `resolvePermissionModeInCli: !bn("claudeProcessWrapper")`; after setting the wrapper, resolution switches to the extension side. Looks benign, but the behavior change needs watching |
| C7 | Whether VSCode actually calls the wrapper is not yet verified end-to-end | The wrapper's call contract is verified (source reading + hand simulation succeeded), but the config item has not actually been set and Reloaded. This is the first implementation step and the only unknown |
| C8 | The Zhipu key has already appeared in the conversation history | Recommend rotating it once in the Zhipu console after configuration is complete |

---

## 5. Open Items

1. **The specific models for CCR's dispatch rules** — which tier background / think / longContext each maps to, TBD. Default implementation: "background goes to the cheap tier, the rest to the main tier"
2. **Which existing projects migrate to the bridget group** — to be decided by the user. Can be left empty to start running, migrate later; migrating triggers C4

> Closed: the directory name is set as `~/bridget/`, group names `jerome` / `bridget`, env filenames match the directory names. The Zhipu key has been provided, stored in `vps_oracle/compose/ccr/.env` (gitignored).

---

## 6. Appendix: key evidence commands

For later reproduction or writing summaries.

```bash
# process tree: confirm claude is a child of extensionHost
ps -eo pid,ppid,args | grep -E "claude|extensionHost"

# the claude process's own environment and cwd
tr '\0' '\n' < /proc/<pid>/environ | grep -iE "ANTHROPIC|DIRENV"
readlink /proc/<pid>/cwd

# the wrapper call semantics in the extension source
EXT=~/.vscode-server/extensions/anthropic.claude-code-<version>-linux-arm64
grep -o ".\{200\}claudeProcessWrapper.\{400\}" "$EXT/extension.js"

# zero-token endpoint probe: listen, watch where claude connects to
python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',59998));s.listen(1);c,_=s.accept();print(c.recv(300).decode())" &
cd <test dir> && ./wrapper.sh <real claude> -p hi

# direnv authorization records stored by absolute path
for f in ~/.local/share/direnv/allow/*; do cat "$f"; done
```