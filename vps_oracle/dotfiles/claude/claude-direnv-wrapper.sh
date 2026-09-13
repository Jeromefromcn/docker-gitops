#!/usr/bin/env bash
# Invoked by the VSCode extension with the workspace directory as cwd:
# wrapper <real-claude> <args...>
# If the extension fails to resolve its built-in claude path, $1 ends up
# being a CLI flag like "--xxx" directly, rather than an executable path.
# In that case `exec "$@"` breaks: bash's exec builtin parses a first
# argument starting with "-" as its own option, failing with
# "exec: --: invalid option".
# Use -f/-x to check whether $1 is actually an executable file; if not,
# fall back to the claude on PATH.
. /home/ubuntu/.claude/direnv-load.sh
if [ -n "$1" ] && [ -f "$1" ] && [ -x "$1" ]; then
  exec "$@"
else
  exec claude "$@"
fi
