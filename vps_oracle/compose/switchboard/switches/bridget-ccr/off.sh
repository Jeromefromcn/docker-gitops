#!/usr/bin/env python3
import os

env_path = "/home/ubuntu/.claude-provider/bridget.env"
tmp_path = env_path + ".tmp"
content = "# Empty = use the official-subscription OAuth. switchboard is the only thing that should rewrite this file.\n"
with open(tmp_path, "w") as f:
    f.write(content)
os.replace(tmp_path, env_path)
