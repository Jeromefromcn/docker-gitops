#!/usr/bin/env bash
# checks/direnv-envrc-trust.sh
#
# Detects a group .envrc whose direnv trust has been revoked — the state
# where direnv silently stops loading the file because its content hash
# changed since it was last `direnv allow`ed. It is ALERT ONLY, and never
# auto-fixes: the fix is `direnv allow`, which is itself the trust
# mechanism — direnv blocks a changed .envrc precisely so a human reviews
# it first (an .envrc is arbitrary shell, and a compromised edit must not
# be silently re-trusted).
#
# Why this exists: the 2026-09-13 incident (see
# docs/incidents/2026-09-13-switchboard-direnv-envrc-trust-revoked.md) —
# a comment-only translation sweep edited shell-env/*.envrc, whose
# deployed symlinks point straight at the group ~/<group>/.envrc; direnv
# revoked trust, so the pointer-file env (ANTHROPIC_*/CLAUDE_CONFIG_DIR)
# stopped being injected and switchboard "stopped switching" with no
# error anywhere. The hex name of the direnv allow-state file does not
# equal any obvious hash of the path, so instead of reverse-engineering
# it this check asks direnv directly: `direnv export bash` from each group
# dir prints "is blocked" on stderr (exit 1) when trust is revoked, and
# the normal export blob (exit 0) when allowed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Space-separated list of directories whose .envrc must stay direnv-allowed.
# Defaults to the three group dirs that are symlinked to shell-env/*.envrc.
DIRS="${INSPECTOR_DIRENV_DIRS:-$HOME/jerome $HOME/bridget $HOME/evidence}"

command -v direnv >/dev/null 2>&1 || {
  emit_result "alert" "flagged" "check:direnv-envrc-trust.sh" \
    "direnv is not installed on the host — .envrc trust cannot be verified"
  exit 0
}

for d in $DIRS; do
  [ -e "$d/.envrc" ] || continue

  blocked="$( (cd "$d" && BASH_ENV= timeout 5 direnv export bash </dev/null 2>&1) \
              | grep -F 'is blocked' || true )"
  [ -n "$blocked" ] || continue

  emit_result "alert" "flagged" "direnv $d/.envrc" \
    "trust revoked (direnv: 'is blocked') — the group's provider/account env is no longer injected. Review the file first, then run: cd $d && direnv allow"
done