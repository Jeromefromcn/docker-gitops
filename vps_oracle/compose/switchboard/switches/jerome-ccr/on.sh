#!/usr/bin/env python3
import json
import os

# The original default ccr profile — renamed to "Jerome" in the ccr admin
# panel, but its id stayed "default-claude-code" (renaming a profile doesn't
# change its id).
PROFILE_ID = "default-claude-code"
ROUTING_PATH = "/model-routing/routing.json"
env_path = "/home/ubuntu/.claude-provider/jerome.env"
tmp_path = env_path + ".tmp"

# Best-effort: if the export file is missing/unreadable (e.g. ccr just
# restarted and hasn't written it yet), fall back to no tier overrides
# rather than fail the whole switch — status.sh self-heals this on the next
# page load once the file shows up.
routing = {}
try:
    with open(ROUTING_PATH) as f:
        routing = json.load(f).get(PROFILE_ID, {})
except (OSError, ValueError):
    pass

content = (
    f"export ANTHROPIC_BASE_URL={os.environ['CCR_HOST_BASE_URL']}\n"
    f"export ANTHROPIC_AUTH_TOKEN={os.environ['CCR_TOKEN_JEROME']}\n"
)
# routing.json 里的 model 就是该 profile 的默认模型（ccr 面板 "model" 字段），
# 映射成 ANTHROPIC_DEFAULT_MODEL 才能让 claude CLI 的 /model default 落到它，
# 否则 CLI 找不到该变量会回落 cc 内置默认（1M 档），ccr 再按 model 档重映射
# 成 pro —— 这正是之前"默认显示 pro"的根因。与下面三个 tier 变量同一套
# 机制：ccr 只导出字符串，switchboard 负责映射到 CLI 进程环境。
if routing.get("model"):
    content += f"export ANTHROPIC_DEFAULT_MODEL={routing['model']}\n"
if routing.get("opusModel"):
    content += f"export ANTHROPIC_DEFAULT_OPUS_MODEL={routing['opusModel']}\n"
if routing.get("sonnetModel"):
    content += f"export ANTHROPIC_DEFAULT_SONNET_MODEL={routing['sonnetModel']}\n"
if routing.get("haikuModel"):
    content += f"export ANTHROPIC_DEFAULT_HAIKU_MODEL={routing['haikuModel']}\n"
# 第三方模型（byteplus/deepseek 等）cc CLI 不识别时默认按 200k 窗口执行；
# 显式声明 1M 才去掉这条限制，与 opus/sonnet/haiku 三档同源（flash 实测可到 1M）。
content += "export CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000\n"

with open(tmp_path, "w") as f:
    f.write(content)
os.chmod(tmp_path, 0o600)
os.replace(tmp_path, env_path)
