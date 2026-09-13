# Comment-only edit to a `.envrc` silently revoked direnv trust and froze group account/provider switching

- Date: 2026-09-13
- Environment: direnv 2.32.1; group-env symlinks `~/jerome/.envrc`, `~/bridget/.envrc`, `~/evidence/.envrc` → repo `vps_oracle/dotfiles/shell-env/*.envrc`; the ccr/switchboard group-switching system
- Symptom: switchboard toggles no longer changed which provider/account a group used ("Switchboard切換不了了")
- Fix: re-ran `direnv allow` in each group directory (done 17:40, artifacts in `~/.local/share/direnv/allow/`)

---

## 1. Conclusion first

**The root cause is direnv's content-hash trust, not switchboard itself.** The `7557ca0` "translate all Chinese content to English" sweep edited the comments in the three `shell-env/*.envrc` files. direnv treats any `.envrc` as arbitrary executable shell, so it binds trust to the file content — any byte change, even a comment, revokes that trust. The already-deployed symlinked `.envrc`s stopped evaluating, so `source_env_if_exists ~/.claude-provider/<group>.env` / `~/.claude-account/<group>.env` never ran, and the `ANTHROPIC_*` / `CLAUDE_CONFIG_DIR` vars that the switchboard UI writes into those pointer files were no longer injected into the group's claude process. The switchboard UI itself was healthy the whole time: its logs showed normal toggle→303→200 flows, and all six `status.sh` scripts returned clean exit codes when run inside the container.

## 2. Evidence chain

- `git ls-files '*.envrc'` → exactly three envrcs tracked: `vps_oracle/dotfiles/shell-env/{bridget,evidence,jerome}.envrc`.
- `git show 7557ca0 -- '*.envrc'` → all three touched, purely comment/string translation (Traditional Chinese → English), no logic lines changed.
- `ls -la ~/jerome/.envrc ~/bridget/.envrc ~/evidence/.envrc` → each is a symlink to its `shell-env/*.envrc` target (deployed by `vps_oracle/dotfiles/link.sh`), so the deployed live files ARE the tracked files — an edit in the repo takes effect immediately.
- `direnv version` → 2.32.1. `ls -la ~/.local/share/direnv/allow/` → three allow entries dated `Sep 13 17:40`, each containing one of the three `.envrc` paths — the re-allow that happened once the root cause was found.
- `docker exec switchboard /app/switches/{jerome,bridget,evidence}{-ccr,-account}/status.sh` → all six exit 0 or 1 with sensible output, none exit 2 (no ERROR) → the switch scripts and the switchboard app were never broken.

## 3. Root cause

direnv's security model: an `.envrc` may contain arbitrary shell, so direnv refuses to evaluate an untrusted file. Trust is granted per-file by `direnv allow`, which records the file (by content hash); on every later evaluation direnv re-checks the file against that record. A changed file no longer matches, so direnv treats it as not-allowed again and silently stops loading it until the operator re-runs `direnv allow`.

The three `.envrc`s are meant to be **static** group-env entry points — this is already documented as gotcha #1 in [`../ccr/README.md`](../ccr/README.md) ("`.envrc` must stay static… If you edit `.envrc` itself, direnv will require re-running `direnv allow`"). The translation sweep treated those files like any other doc (its whole point was "zero Chinese characters remain repo-wide") and edited their comments — which is exactly the one edit this kind of file must never receive, because the deployed symlinks point straight at these same files, so the trust revocation hit the live system immediately and silently.

Why it felt like "switchboard can't switch": the UI's toggle correctly writes the pointer `.env` file, but the pointer only matters once the group's `.envrc` re-sources it into the claude process. With the `.envrc` deactivated, toggling the pointer had no observable effect on the group's provider/account — the claude process stayed on whatever it had before.

## 4. Fix

`cd ~/jerome && direnv allow` (and the same for `~/bridget`, `~/evidence`). Once trust is re-recorded against the new content, direnv resumes loading the static `.envrc` and the pointer-file vars flow again. No repo file was reverted — the `.envrc` comments are legitimately better in English, and reverting them just to restore an old hash would be wrong.

## 5. Verification

From inside a group directory, direnv must inject the environment without a "not allowed" error:

```
cd ~/jerome && BASH_ENV=/home/ubuntu/.claude/direnv-bash-env.sh bash -c 'echo "${ANTHROPIC_BASE_URL:-(unset=official)}"'
```

Expected: prints the CCR base URL when the group's provider pointer points at CCR, rather than `(unset=official)`. Then toggling a switch in the switchboard UI and opening a new claude session in that group should actually flip the provider. The switchboard container needs no restart or rebuild.

## 6. Leftovers / lessons

- The trap: a broad mechanical "translate everything" commit is **not** content-neutral for `.envrc` files, because direnv keys trust on content. The zero-Chinese-character invariant sweep should have either excluded `.envrc`, or been followed by an immediate `direnv allow` across the three group directories.
- A reminder that "repo-internal files" is not a homogeneous category: some files carry side effects on edit, and a repo-wide sweep that touches them can break live behavior without a single failing check.
- The gotcha was already documented (`ccr/README.md`) but that didn't stop the sweep, because nothing in the sweep's checklist flagged `.envrc` as a file-with-side-effects.
- Open question (not done here): a cheap inspector check could verify that each tracked `shell-env/*.envrc`'s deployed symlink target is currently direnv-allowed (compare against the `~/.local/share/direnv/allow/` store), so a future trust-revocation surfaces as an alert rather than a "switchboard stopped working" report.