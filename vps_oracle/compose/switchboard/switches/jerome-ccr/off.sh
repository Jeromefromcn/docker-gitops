#!/usr/bin/env python3
import os

env_path = "/home/ubuntu/.claude-provider/jerome.env"
tmp_path = env_path + ".tmp"
content = "# 空 = 走官方订阅 OAuth。switchboard 是唯一应该改写这个文件的东西。\n"
with open(tmp_path, "w") as f:
    f.write(content)
os.replace(tmp_path, env_path)
