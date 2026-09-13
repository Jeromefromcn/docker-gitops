# Multi-account directory isolation (CLAUDE_CONFIG_DIR)

Bind **different Claude subscription accounts** to different project groups, orthogonal to and stackable on provider switching (official ↔ CCR). The mechanism is a separate `CLAUDE_CONFIG_DIR` per account, injected per-directory via direnv — whichever directory you `cd` into is which account.

Official docs: `CLAUDE_CONFIG_DIR` overrides the default `~/.claude`, and **login state, settings, session history, plugins — everything** lives under this directory (see the [env-vars docs](https://code.claude.com/docs/en/env-vars)). So each independent configDir = one independently logged-in account.

## Why this is orthogonal to provider switching

- provider switching changes `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` in the dynamic `.env` (when going through CCR these two lines override OAuth).
- account binding changes `CLAUDE_CONFIG_DIR` in the **static `.envrc`** (pointing to each account's config directory).
- The two live in different files, different layers: `.envrc` is always static (the account is a structural property of the directory), and only `.env` is rewritten by the UI (the provider is the switchable part). So **the switchboard UI doesn't change**.

## Layout (zero changes to the primary account, a separate directory only for the second account)

| Group | `.envrc` | configDir | Account |
|---|---|---|---|
| `~/jerome/` | unchanged | default `~/.claude` | Account A (existing login/settings/memory all preserved) |
| `~/bridget/` | add one line `export CLAUDE_CONFIG_DIR=…` + the original `source_env_if_exists` | `~/.claude-configs/bridget` | Account B |

Full contents of `~/bridget/.envrc`:

```bash
export CLAUDE_CONFIG_DIR="$HOME/.claude-configs/bridget"
source_env_if_exists /home/ubuntu/.claude-provider/bridget.env
```

## One-time login (done once per separate account)

```bash
mkdir -p ~/.claude-configs/bridget
cd ~/bridget            # direnv has already injected CLAUDE_CONFIG_DIR
direnv allow            # editing .envrc requires re-trusting once
claude login            # OAuth is stored in ~/.claude-configs/bridget, bound to Account B
```

Afterwards, any claude session opened under `~/bridget/` uses Account B.

## Result matrix (each directory = a fixed account × a switchable provider)

| Directory | Official mode | CCR mode |
|---|---|---|
| `~/jerome/` | Account A subscription | Zhipu (account-independent; the env overrides OAuth) |
| `~/bridget/` | Account B subscription | Zhipu (account-independent) |

When going through CCR, `ANTHROPIC_BASE_URL` / `AUTH_TOKEN` override OAuth, so whichever account is bound in the configDir doesn't matter — CCR uses its own Zhipu key.

## Gotchas

1. **configDir is a wholesale swap, not just the login state.** `CLAUDE_CONFIG_DIR` moves settings, the global `CLAUDE.md`, project memory (`projects/…`), MCP config, and plugins **all** over. So `~/bridget/` by default can't read your global `~/.claude/CLAUDE.md` and `settings.json` — to keep them, symlink or copy them over (**don't symlink `.credentials.json`**, otherwise account isolation is defeated):

   ```bash
   cd ~/.claude-configs/bridget
   ln -s ~/.claude/CLAUDE.md .
   ln -s ~/.claude/settings.json .   # copy rather than symlink if each account should edit its own
   ```

   (`jerome` uses the default `~/.claude` and is unaffected. The `sub2` account actually in use is already a full mirror — see "UI live account switching" step 2 below, no need to link one by one.)

2. **The VSCode extension has a known bug ([#30538](https://github.com/anthropics/claude-code/issues/30538)): its own `environmentVariables` setting doesn't honor `CLAUDE_CONFIG_DIR`.** But this repo's injection path doesn't go through that — `claudeProcessWrapper` exports it at the shell layer and then `exec claude`, so the claude process reads it from its own environment and should sidestep the bug. **After wiring it up, be sure to verify in VSCode that the account actually switched** (the terminal path is unaffected by this bug).

3. **Even with `CLAUDE_CONFIG_DIR` set, an empty `.claude/` may still be left in the project directory ([#3833](https://github.com/anthropics/claude-code/issues/3833)).** That's purely cosmetic and doesn't affect isolation — the config that actually takes effect still comes from the configDir.

4. **An account is static by default, unlike the provider, which the UI can switch live.** Switching accounts = `cd` into another directory (direnv swaps the configDir). A session already running has its environment fixed; only new sessions pick it up (same as provider switching). **Exception: the `jerome`/`bridget`/`evidence` groups each have a `-account` toggle so you can switch accounts live via the UI within the same directory** (see "UI live account switching" below).

## Adding a third account

```bash
mkdir -p ~/carol ~/.claude-configs/carol
cat > ~/carol/.envrc <<'EOF'
export CLAUDE_CONFIG_DIR="$HOME/.claude-configs/carol"
source_env_if_exists /home/ubuntu/.claude-provider/carol.env
EOF
touch /home/ubuntu/.claude-provider/carol.env
cd ~/carol && direnv allow && claude login
# Then register the carol-ccr toggle in switchboard + rebuild switchboard (see "Adding a new group" in ../README.md)
```

## UI live account switching (dynamic CLAUDE_CONFIG_DIR switch; implemented for jerome/bridget/evidence)

**Within the same directory**, use switchboard to switch between several already-logged-in subscription accounts (no `cd` needed). Orthogonal to provider switching: the provider toggles switch `ANTHROPIC_*` in `.claude-provider/<group>.env`, while the account toggles switch `CLAUDE_CONFIG_DIR` in `.claude-account/<group>.env`.

The key: **don't touch `.envrc`**. `.envrc` stays static, with just one extra `source_env_if_exists` line pointing at `.claude-account/<group>.env` (a one-time `direnv allow`, after which you never need to re-allow). The switchboard `<group>-account` toggle rewrites this pointer file — sidestepping the earlier gotcha where "you'd have to rewrite `.envrc`, triggering a re-allow", so beyond directory isolation there's now a viable UI switching path too.

One-time setup (using jerome as an example):

```bash
# 1. Create Charles's configDir + log in once (interactive OAuth, manual only)
mkdir -p ~/.claude-configs/sub2
CLAUDE_CONFIG_DIR=/home/ubuntu/.claude-configs/sub2 claude login

# 2. Mirroring (since 2026-08-16 sub2 is already a full mirror, no manual linking needed).
#    sub2 is a whole-disc mirror of ~/.claude: except that .credentials.json (login token)
#    and .claude.json (account profile/eligibility cache) are kept local, everything else
#    is symlinked to ~/.claude — beyond CLAUDE.md/settings/plugins/hooks/scripts, memory
#    (projects/), session history (sessions/, history.jsonl), session-env, stats-cache etc.
#    are all shared. Switching accounts = only the token changes; the environment, memory,
#    and history are the same. Going forward, remember to add ln -s for any new entries in
#    ~/.claude, otherwise Charles's side can't read them.

# 3. Create the pointer-file directory (the switchboard container only mounts this directory)
mkdir -p ~/.claude-account

# 4. Add one line to the target directory's .envrc + a one-time allow
#    Append to ~/jerome/.envrc: source_env_if_exists /home/ubuntu/.claude-account/jerome.env
cd ~/jerome && direnv allow
```

Toggle side (already registered in switchboard as `jerome-account` / `bridget-account` / `evidence-account`, group=CC Account): `on.sh` writes `export CLAUDE_CONFIG_DIR=/home/ubuntu/.claude-configs/sub2`; `off.sh` clears it (back to default `~/.claude` = Jerome); `status.sh` determines the three-way state from the pointer file content alone — Charles / Jerome (default `~/.claude`) / unknown value = ERROR (contract: exit 0=on / 2=error / everything else=off). **No check for "whether the target configDir is logged in"**: the container deliberately doesn't mount `~/.claude-configs`, so it can't see `.credentials.json` or verify it — logging in is a setup-time precondition (see step 1 above).

**Security**: the switchboard container only mounts `.claude-account/`, and does **not** mount `~/.claude` or `~/.claude-configs/` (those two hold `.credentials.json`). The toggle scripts never touch the configDir itself.

**Result matrix** (within `~/jerome/`; `~/bridget/` / `~/evidence/` are analogous):

| account toggle | provider toggle | Effect |
|---|---|---|
| Jerome | Official | Jerome official |
| Jerome | CCR | Zhipu |
| Charles | Official | Charles official (environment + memory/history fully shared with Jerome, only the token changes) |
| Charles | CCR | Zhipu (account-independent) |

> Note: with provider=CCR the traffic goes through the claude-code-router gateway (routable to any OpenAI-compatible provider); "Zhipu" in the table is the current upstream routing target, not CCR itself.

**Gotcha**: switching only affects newly opened sessions (same as provider switching). sub2 shares memory/history with `~/.claude` (the same files), so **don't run long sessions for two accounts at the same time** — shared files like memory, todos, and `.claude.json` are last-writer-wins, and concurrent writes overwrite each other (the same risk level as one account in two terminals). The reason `.claude.json` stays local: it caches the account profile (email/plan/rate-limit tier) and model-access/eligibility, and sharing it would mingle the two accounts' eligibility caches.

## Verification

```bash
# In a bridget project directory, confirm configDir was injected correctly
# (using the same wrapper real claude uses). First use the UI to switch
# bridget-account to Charles, then:
cd ~/bridget/any-project
/home/ubuntu/.claude/claude-direnv-wrapper.sh env | grep CLAUDE_CONFIG_DIR
# Should output CLAUDE_CONFIG_DIR=/home/ubuntu/.claude-configs/sub2 (Charles)

# Switching back to Jerome (bridget-account = off) should show no such line
# (falling back to the default ~/.claude)
cd ~/bridget && /home/ubuntu/.claude/claude-direnv-wrapper.sh env | grep CLAUDE_CONFIG_DIR || echo '(unset = default ~/.claude, Jerome)'
```