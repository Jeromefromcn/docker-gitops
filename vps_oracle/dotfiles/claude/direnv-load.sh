# Evaluate direnv for the current directory and inject its environment
# variables. This is sourced, not executed — never exit.
if command -v direnv >/dev/null 2>&1; then
  __d="$(BASH_ENV= timeout 5 direnv export bash 2>/dev/null </dev/null)"
  [ -n "$__d" ] && eval "$__d"
  unset __d
fi
