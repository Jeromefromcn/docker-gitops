#!/usr/bin/env python3
import os

env_path = "/home/ubuntu/.claude-provider/jerome.env"
tmp_path = env_path + ".tmp"
content = (
    f"export ANTHROPIC_BASE_URL={os.environ['CCR_HOST_BASE_URL']}\n"
    f"export ANTHROPIC_AUTH_TOKEN={os.environ['CCR_TOKEN']}\n"
)
with open(tmp_path, "w") as f:
    f.write(content)
os.replace(tmp_path, env_path)
