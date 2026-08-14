#!/usr/bin/env python3
import os

env_path = "/home/ubuntu/.claude-account/jerome.env"
tmp_path = env_path + ".tmp"
content = "export CLAUDE_CONFIG_DIR=/home/ubuntu/.claude-configs/sub2\n"
with open(tmp_path, "w") as f:
    f.write(content)
os.chmod(tmp_path, 0o600)
os.replace(tmp_path, env_path)
