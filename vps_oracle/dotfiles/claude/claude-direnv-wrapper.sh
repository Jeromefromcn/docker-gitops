#!/usr/bin/env bash
# 由 VSCode 扩展以 workspace 目录为 cwd 调用: wrapper <真claude> <args...>
# 若扩展未能解析出内建 claude 路径，$1 会直接是 "--xxx" 这样的 CLI flag，
# 而不是可执行文件路径。这时不能 exec "$@"：bash 的 exec 内建会把开头是
# "-" 的首个参数当成自己的选项解析，报 "exec: --: invalid option"。
# 用 -f/-x 判断 $1 是否真是可执行文件，不是的话退回 PATH 里的 claude。
. /home/ubuntu/.claude/direnv-load.sh
if [ -n "$1" ] && [ -f "$1" ] && [ -x "$1" ]; then
  exec "$@"
else
  exec claude "$@"
fi
