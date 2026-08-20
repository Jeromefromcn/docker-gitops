#!/usr/bin/env python3
import json
import os

PROFILE_ID = "bridget"
ROUTING_PATH = "/model-routing/routing.json"
env_path = "/home/ubuntu/.claude-provider/bridget.env"
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
    f"export ANTHROPIC_AUTH_TOKEN={os.environ['CCR_TOKEN_BRIDGET']}\n"
)
if routing.get("opusModel"):
    content += f"export ANTHROPIC_DEFAULT_OPUS_MODEL={routing['opusModel']}\n"
if routing.get("sonnetModel"):
    content += f"export ANTHROPIC_DEFAULT_SONNET_MODEL={routing['sonnetModel']}\n"
if routing.get("haikuModel"):
    content += f"export ANTHROPIC_DEFAULT_HAIKU_MODEL={routing['haikuModel']}\n"

with open(tmp_path, "w") as f:
    f.write(content)
os.chmod(tmp_path, 0o600)
os.replace(tmp_path, env_path)
