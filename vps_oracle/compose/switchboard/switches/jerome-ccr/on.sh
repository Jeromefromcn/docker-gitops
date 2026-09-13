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
# The model in routing.json is that profile's default model (the ccr panel's
# "model" field). Mapping it to ANTHROPIC_DEFAULT_MODEL is what makes the
# claude CLI's /model default land on it; otherwise the CLI can't find the
# variable and falls back to cc's built-in default (the 1M tier), which ccr
# then re-maps by the model tier to pro — that was the root cause of
# "showing pro by default". Same mechanism as the three tier variables below:
# ccr only exports strings; switchboard is responsible for mapping them onto
# the CLI process environment.
if routing.get("model"):
    content += f"export ANTHROPIC_DEFAULT_MODEL={routing['model']}\n"
if routing.get("opusModel"):
    content += f"export ANTHROPIC_DEFAULT_OPUS_MODEL={routing['opusModel']}\n"
if routing.get("sonnetModel"):
    content += f"export ANTHROPIC_DEFAULT_SONNET_MODEL={routing['sonnetModel']}\n"
if routing.get("haikuModel"):
    content += f"export ANTHROPIC_DEFAULT_HAIKU_MODEL={routing['haikuModel']}\n"
# Third-party models (byteplus/deepseek etc.) run against a 200k context
# window by default when cc CLI doesn't recognize them; declaring 1M
# explicitly removes that limit, same provenance as the opus/sonnet/haiku
# three tiers (flash actually reaches 1M).
content += "export CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000\n"

with open(tmp_path, "w") as f:
    f.write(content)
os.chmod(tmp_path, 0o600)
os.replace(tmp_path, env_path)
