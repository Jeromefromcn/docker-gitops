# vps_oracle/compose/switchboard

A generic, config-driven toggle UI (stdlib, `app.py` + `config.py`). Sits on the `proxy` network and is reverse-proxied via NPM to `https://switchboard.jerome.cloudns.asia` (access list=self-only).

The engine itself knows nothing about what any specific toggle is — it only reads `switches.ini` for the list of toggles, then drives each toggle's three scripts `switches/<id>/{status,on,off}.sh`: `GET /` runs each toggle's `status.sh` live (no caching), and `POST /toggle` runs `on.sh` or `off.sh` depending on the current state. Adding/removing a toggle only requires adding/removing a `switches/<id>/` directory + three scripts + one section in `switches.ini`, with no change to `app.py`/`config.py` (though if a new toggle needs a new host path or secret you must also change `docker-compose.yml`'s volumes/environment and rebuild the image — config alone isn't enough). Design details in [`../../../docs/superpowers/specs/2026-08-13-switchboard-generic-toggle-design.md`](../../../docs/superpowers/specs/2026-08-13-switchboard-generic-toggle-design.md).

`status.sh`'s exit code is a three-state contract: exit 0 = **on**; exit 2 = **error** (an anomaly the script detected itself, e.g. a permission error reading a config file — treated as ERROR like a timeout or a missing script, never misread as "safely off"); any other non-zero = **off**. `on.sh`/`off.sh` have only two states: exit 0 = success, non-zero = failure.

`status.sh`'s exit code is a three-state contract: exit 0 = **on**; exit 2 = **error** (an anomaly the script detected itself, e.g. a permission error reading a config file — treated as ERROR like a timeout or a missing script, never misread as "safely off"); any other non-zero = **off**. `on.sh`/`off.sh` have only two states: exit 0 = success, non-zero = failure.

Toggles currently registered:

| id | description |
|---|---|
| `jerome-ccr` | Claude provider switch for the jerome group (Official ↔ CCR) |
| `bridget-ccr` | Claude provider switch for the bridget group (Official ↔ CCR) |
| `evidence-ccr` | Claude provider switch for the evidence group (Official ↔ CCR) |

> CCR = [claude-code-router](https://github.com/musistudio/claude-code-router), a routing gateway that can route to **any** OpenAI-compatible provider (Zhipu GLM, DeepSeek, Qwen, ...). Zhipu is only the current upstream config, not CCR itself; to change the upstream just change the provider in the CCR admin panel — the CCR toggles stay untouched (see [`../ccr/README.md`](../ccr/README.md)).
| `jerome-account` | Claude subscription account switch for the jerome group (Jerome ↔ Charles, `CLAUDE_CONFIG_DIR` pointer; orthogonal to the provider switch) |
| `bridget-account` | Claude subscription account switch for the bridget group (Jerome ↔ Charles, `CLAUDE_CONFIG_DIR` pointer; orthogonal to the provider switch) |
| `evidence-account` | Claude subscription account switch for the evidence group (Jerome ↔ Charles, `CLAUDE_CONFIG_DIR` pointer; orthogonal to the provider switch) |

For the full documentation of the whole group-switching system these toggles belong to (direnv + group env + CCR + this UI + NPM), the steps for adding a new group, known gotchas, rollback, etc., see [`../ccr/README.md`](../ccr/README.md); for the mechanism and one-time setup of multi-subscription account switching (the `<group>-account` toggles), see [`../ccr/ACCOUNTS.md`](../ccr/ACCOUNTS.md).

## Account-related file inventory (Jerome ↔ Yin/Charles; as of 2026-08-16, sub2 = full mirror)

The only isolation anchor left between the two accounts is the login token. Inside `~/.claude-configs/sub2/` (Charles/Yin's `CLAUDE_CONFIG_DIR`), every entry except `.credentials.json` and `.claude.json` is symlinked to `~/.claude` — **switching accounts = just swapping the token**, with environment/memory/history all the same.

> **Maintenance rule**: every time a **new top-level entry** appears under `~/.claude`, add a `ln -s ~/.claude/<new entry> sub2/`,
> otherwise the Charles side can't read it and the mirror silently falls out of sync (no error). Changes to the **contents** of `plugins/`, `hooks/`, `scripts/`, `CLAUDE.md`,
> `settings.json` need no action — those are inside directories and sync automatically through the existing symlinks.

### Inside configDir (`~/.claude-configs/sub2/`)

| entry | type | owner | description |
|---|---|---|---|
| `.credentials.json` | real file | **Yin only** | OAuth login token, the single identity anchor for the account, never symlinked |
| `.claude.json` | real file | **Yin only** | account profile cache (email/plan tier/rate-limit) + `modelAccessCache`/eligibility cache. Sharing would cross-contaminate the two accounts' eligibility caches, so it stays local |
| `.oauth_refresh.lock` | directory (CLI internal mutex) | **own per account** | the lock the CLI holds while refreshing an OAuth token; sits right next to `.credentials.json`, generated per `CLAUDE_CONFIG_DIR`, appears on demand. Symlinking would make the two accounts queue behind each other while refreshing tokens that are unrelated, so like `.credentials.json` it is never symlinked |
| `CLAUDE.md` `settings.json` `hooks/` `plugins/` `scripts/` `rules/` | symlink → `~/.claude` | shared | global config/plugins/hooks/rules |
| `projects/` | symlink → `~/.claude` | shared | **memory** (`projects/<path>/memory/`) + per-session transcripts `.jsonl` |
| `sessions/` `history.jsonl` `session-env/` `shell-snapshots/` `file-history/` | symlink → `~/.claude` | shared | **session index / global history / environment snapshots / file edit history** |
| `cache/` `telemetry/` `stats-cache.json` `downloads/` `backups/` `auto-job-log/` `channels/` `plans/` `tasks/` `ide/` | symlink → `~/.claude` | shared | caches/logs/app state, safe to overwrite |
| `daemon/` `daemon.lock` `daemon.log` `daemon.status.json` `jobs/` | symlink → `~/.claude` | shared | background daemon (supervisor/worker process state, `/tmp` socket index) + task queue; runtime state of a single-machine unique process, not account identity |
| `.last-cleanup` `.last-update-result.json` `.claude-code-notify-hooks.json` | symlink → `~/.claude` | shared | cleanup/update/notify state |
| `claude-direnv-wrapper.sh` `direnv-bash-env.sh` `direnv-load.sh` | symlink → `~/.claude` | shared | group-injection wrapper and helpers (actually referenced by absolute path, so symlinking them is harmless) |

### Outside configDir, account-switch related

| path | type | owner | description |
|---|---|---|---|
| `~/.claude.json` (HOME root) | real file | **Jerome only** | Jerome's global state (the default configDir's state file sits in HOME root, not inside `~/.claude/`) |
| `~/.claude-configs/sub2/.claude.json` | real file | **Yin only** | see table above |
| `~/.claude-account/<group>.env` | real file | **writable by switchboard** | account pointer: `export CLAUDE_CONFIG_DIR=…sub2` = Yin, empty = Jerome. The container only mounts this directory |
| `~/.claude-provider/<group>.env` | real file | **writable by switchboard** | provider pointer (CCR) |
| `<group>/.envrc` | real file | group static config | only `source_env_if_exists ~/.claude-account/<group>.env`, never rewritten by the UI |