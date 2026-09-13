#!/usr/bin/env python3
import os

env_path = "/home/ubuntu/.claude-account/jerome.env"
tmp_path = env_path + ".tmp"
content = "# Empty = Jerome (default ~/.claude). switchboard is the only thing that should rewrite this file.\n"
with open(tmp_path, "w") as f:
    f.write(content)
os.chmod(tmp_path, 0o600)
os.replace(tmp_path, env_path)
