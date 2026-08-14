#!/usr/bin/env python3
import os

env_path = "/home/ubuntu/.claude-account/jerome.env"
tmp_path = env_path + ".tmp"
content = "# 空 = Jerome（默認 ~/.claude）。switchboard 是唯一應該改寫這個文件的东西。\n"
with open(tmp_path, "w") as f:
    f.write(content)
os.chmod(tmp_path, 0o600)
os.replace(tmp_path, env_path)
