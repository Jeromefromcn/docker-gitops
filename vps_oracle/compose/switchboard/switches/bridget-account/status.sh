#!/usr/bin/env python3
import os
import re
import sys

env_path = "/home/ubuntu/.claude-account/bridget.env"
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

    # Determine the three states from the pointer file alone: the container deliberately
    # does not mount ~/.claude-configs (that's where .credentials.json lives), so it can't
    # (and shouldn't) verify whether the target configDir is logged in — login is a
    # setup-time precondition.
    if pointer == sub2_dir:
        print("Charles (~/.claude-configs/sub2)")
        sys.exit(0)
    if pointer is None or pointer == "/home/ubuntu/.claude":
        print("Jerome (default ~/.claude)")
        sys.exit(1)
    print(f"Unknown CLAUDE_CONFIG_DIR: {pointer}")
    sys.exit(2)
except Exception:
    # Any unexpected crash (e.g. a permission error reading env_path) must
    # report as ERROR, not silently masquerade as "off" — sys.exit raises
    # SystemExit, a BaseException, so it is unaffected by this except.
    sys.exit(2)
