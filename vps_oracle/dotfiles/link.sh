#!/usr/bin/env bash
# Regenerate the symlinks for every config file in this directory, pointing
# back into $HOME / the relevant system directory.
# Use case: after this repo moves location, or after a fresh clone on a new
# machine, run this script once to re-link every dotfile listed below back
# to where it belongs.
#
# By default this never overwrites an existing real file (one that isn't
# already a symlink, or isn't a symlink pointing into this directory),
# to avoid clobbering local config that isn't managed here yet; pass
# --force once you've confirmed you want to overwrite it.

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# "<real path on the system>|<relative path within this directory>"
PAIRS=(
  "$HOME/.claude/CLAUDE.md|claude/CLAUDE.md"
  "$HOME/.claude/rules|claude/rules"
  "$HOME/.claude/claude-direnv-wrapper.sh|claude/claude-direnv-wrapper.sh"
  "$HOME/.claude/direnv-load.sh|claude/direnv-load.sh"
  "$HOME/.claude/direnv-bash-env.sh|claude/direnv-bash-env.sh"
  "$HOME/.claude/settings.json|claude/settings.json"
  "$HOME/.claude/.claude-code-notify-hooks.json|claude-code-notify/.claude-code-notify-hooks.json"
  "$HOME/.claude/claude-code-notify/config.env|claude-code-notify/config.env"
  "$HOME/.bashrc|shell/.bashrc"
  "$HOME/.bash_aliases|shell/.bash_aliases"
  "$HOME/.profile|shell/.profile"
  "$HOME/.bash_secrets|shell/.bash_secrets"
  "$HOME/.gitconfig|git/.gitconfig"
  "$HOME/.gitconfig-jerome|git/.gitconfig-jerome"
  "$HOME/.gitconfig-bridget|git/.gitconfig-bridget"
  "$HOME/.gitconfig-evidence|git/.gitconfig-evidence"
  "$HOME/.vscode-server/data/Machine/settings.json|vscode/machine-settings.json"
  "$HOME/bridget/.envrc|shell-env/bridget.envrc"
  "$HOME/jerome/.envrc|shell-env/jerome.envrc"
  "$HOME/evidence/.envrc|shell-env/evidence.envrc"
  "$HOME/claude/jerome/CLAUDE.md|claude-jerome/CLAUDE.md"
  "$HOME/claude/jerome/start-claude.sh|claude-jerome/start-claude.sh"
  "$HOME/claude/jerome/.claude/settings.local.json|claude-jerome/.claude/settings.local.json"
  "$HOME/.config/git/ignore|config/git-ignore"
  "$HOME/.config/rclone/rclone.conf|config/rclone.conf"
  "$HOME/.config/gh/config.yml|config/gh-config.yml"
  "$HOME/.config/gh/hosts.yml|config/gh-hosts.yml"
  "$HOME/.config/helm/repositories.yaml|config/helm-repositories.yaml"
)

for pair in "${PAIRS[@]}"; do
  live="${pair%%|*}"
  rel="${pair#*|}"
  target="$DOTFILES_DIR/$rel"

  if [ ! -e "$target" ]; then
    echo "Skipping (no such file in this directory — may be a gitignored real file like config.env that hasn't been created yet): $target"
    continue
  fi

  if [ -L "$live" ]; then
    current="$(readlink "$live")"
    if [ "$current" = "$target" ]; then
      echo "Already linked: $live"
    else
      echo "Re-linking: $live (used to point to $current)"
      ln -sf "$target" "$live"
    fi
    continue
  fi

  if [ -e "$live" ]; then
    if [ "$FORCE" = "1" ]; then
      echo "Overwriting (--force): $live"
      ln -sf "$target" "$live"
    else
      echo "Skipping ($live already exists as a real file, not a symlink — pass --force to overwrite)"
    fi
    continue
  fi

  mkdir -p "$(dirname "$live")"
  ln -s "$target" "$live"
  echo "New link: $live -> $target"
done
