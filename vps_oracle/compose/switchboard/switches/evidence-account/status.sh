#!/usr/bin/env python3
import os
import re
import sys

env_path = "/home/ubuntu/.claude-account/evidence.env"
sub2_dir = "/home/ubuntu/.claude-configs/sub2"
claude_re = re.compile(r'^\s*(?:export\s+)?CLAUDE_CONFIG_DIR=(\S+)')

try:
    pointer = None
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                m = claude_re.match(line)
                if m:
                    pointer = m.group(1).strip("'\"")
                    break

    # 只以指標檔判定三態：容器刻意不 mount ~/.claude-configs（那是 .credentials.json
    # 所在地），所以無法（也不該）驗證目標 configDir 是否已登入——登入是設定期的前提。
    if pointer == sub2_dir:
        print("Charles (~/.claude-configs/sub2)")
        sys.exit(0)
    if pointer is None or pointer == "/home/ubuntu/.claude":
        print("Jerome (default ~/.claude)")
        sys.exit(1)
    print(f"未知 CLAUDE_CONFIG_DIR: {pointer}")
    sys.exit(2)
except Exception:
    # 任何意外崩潰（例如讀 env_path 的權限錯誤）必須回報為 ERROR，
    # 不能被誤讀成「off」——sys.exit 拋的是 SystemExit（BaseException），不受此 except 影響。
    sys.exit(2)
