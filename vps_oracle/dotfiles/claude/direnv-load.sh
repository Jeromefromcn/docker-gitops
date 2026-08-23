# 对当前目录求值 direnv 并注入环境变量。被 source，不要 exit。
if command -v direnv >/dev/null 2>&1; then
  __d="$(BASH_ENV= timeout 5 direnv export bash 2>/dev/null </dev/null)"
  [ -n "$__d" ] && eval "$__d"
  unset __d
fi
