#!/usr/bin/env python3
import json
import os

PROFILE_ID = "evidence"
ROUTING_PATH = "/model-routing/routing.json"
env_path = "/home/ubuntu/.claude-provider/evidence.env"
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
    f"export ANTHROPIC_AUTH_TOKEN={os.environ['CCR_TOKEN_EVIDENCE']}\n"
)
# The model in routing.json is that profile's default model; mapping it to
# ANTHROPIC_DEFAULT_MODEL is what makes the claude CLI's /model default land
# on it, otherwise it falls back to cc's built-in default and ccr re-maps it
# to the opus tier. Same mechanism as the three tier variables below (see
# jerome-ccr/on.sh).
# NOTE: jerome-ccr/on.sh describes this same fallback landing on the "pro"
# tier rather than "opus" — unconfirmed whether that's a genuine per-profile
# difference or a stale copy-paste; verify against actual CCR behavior before
# relying on either wording.
if routing.get("model"):
    content += f"export ANTHROPIC_DEFAULT_MODEL={routing['model']}\n"
if routing.get("opusModel"):
    content += f"export ANTHROPIC_DEFAULT_OPUS_MODEL={routing['opusModel']}\n"
if routing.get("sonnetModel"):
    content += f"export ANTHROPIC_DEFAULT_SONNET_MODEL={routing['sonnetModel']}\n"
if routing.get("haikuModel"):
    content += f"export ANTHROPIC_DEFAULT_HAIKU_MODEL={routing['haikuModel']}\n"
# Third-party models run against a 200k context window by default when cc CLI
# doesn't recognize them; declaring 1M removes the limit.
content += "export CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000\n"

with open(tmp_path, "w") as f:
    f.write(content)
os.chmod(tmp_path, 0o600)
os.replace(tmp_path, env_path)
