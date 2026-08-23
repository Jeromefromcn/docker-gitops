#!/usr/bin/env bash
# 重建本目录下所有配置文件在 $HOME / 系统目录里的软链。
# 用途：本仓库搬了位置、或者在新机器上重新 clone 之后，跑一次这个脚本
# 把下面列的每个 dotfile 重新软链回它该在的地方。
#
# 默认不覆盖已经存在的真实文件（不是软链、不是指向本目录的软链），
# 避免误删你还没纳管的本机配置；确认要覆盖就加 --force。

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# "<系统里的真实路径>|<本目录下的相对路径>"
PAIRS=(
  "$HOME/.claude/CLAUDE.md|claude/CLAUDE.md"
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
  "$HOME/.vscode-server/data/Machine/settings.json|vscode/machine-settings.json"
)

for pair in "${PAIRS[@]}"; do
  live="${pair%%|*}"
  rel="${pair#*|}"
  target="$DOTFILES_DIR/$rel"

  if [ ! -e "$target" ]; then
    echo "跳过（本目录下没有这个文件，可能是 config.env 这类被 gitignore 的真身还没建）: $target"
    continue
  fi

  if [ -L "$live" ]; then
    current="$(readlink "$live")"
    if [ "$current" = "$target" ]; then
      echo "已连接: $live"
    else
      echo "重新连接: $live（原本指向 $current）"
      ln -sf "$target" "$live"
    fi
    continue
  fi

  if [ -e "$live" ]; then
    if [ "$FORCE" = "1" ]; then
      echo "覆盖（--force）: $live"
      ln -sf "$target" "$live"
    else
      echo "跳过（$live 已存在真实文件，不是软链，加 --force 才覆盖）"
    fi
    continue
  fi

  mkdir -p "$(dirname "$live")"
  ln -s "$target" "$live"
  echo "新建连接: $live -> $target"
done
