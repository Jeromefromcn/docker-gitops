# Auto-loads direnv's .envrc for every non-interactive bash invocation
# (used by Claude Code's Bash tool and, via claude-direnv-wrapper.sh, by
# the claude process itself). Sourced via $BASH_ENV.
case $- in
  *i*) return 0 2>/dev/null || exit 0 ;;
esac
. /home/ubuntu/.claude/direnv-load.sh
