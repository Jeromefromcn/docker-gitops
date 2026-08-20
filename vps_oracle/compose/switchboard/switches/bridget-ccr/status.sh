#!/usr/bin/env python3
import json
import os
import re
import sys
import urllib.error
import urllib.request

PROFILE_ID = "bridget"
ROUTING_PATH = "/model-routing/routing.json"
TIER_VARS = {
    "opusModel": "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "sonnetModel": "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "haikuModel": "ANTHROPIC_DEFAULT_HAIKU_MODEL",
}

try:
    env_path = "/home/ubuntu/.claude-provider/bridget.env"
    base_url_re = re.compile(r'^\s*(?:export\s+)?ANTHROPIC_BASE_URL=(\S+)')

    lines = []
    base_url = None
    if os.path.exists(env_path):
        with open(env_path) as f:
            lines = f.readlines()
        for line in lines:
            m = base_url_re.match(line)
            if m:
                base_url = m.group(1).strip("'\"")
                break

    if base_url is None:
        sys.exit(1)

    # Self-heal: every status check (i.e. every switchboard page load — see
    # config.py's "nothing cached, re-scan live" design) re-syncs the three
    # tier env var lines from ccr's current profile config, so editing a
    # profile in the ccr admin panel takes effect without a manual
    # off/on toggle. Best-effort — if the export file is missing/unreadable,
    # leave the existing lines alone rather than fail the whole status check.
    try:
        with open(ROUTING_PATH) as f:
            routing = json.load(f).get(PROFILE_ID, {})
        desired = {
            var: routing[key] for key, var in TIER_VARS.items() if routing.get(key)
        }
        kept = [
            l for l in lines
            if not any(l.startswith(f"export {v}=") for v in TIER_VARS.values())
        ]
        new_lines = kept + [f"export {v}={val}\n" for v, val in desired.items()]
        if new_lines != lines:
            tmp_path = env_path + ".tmp"
            with open(tmp_path, "w") as f:
                f.writelines(new_lines)
            os.chmod(tmp_path, 0o600)
            os.replace(tmp_path, env_path)
    except (OSError, ValueError, KeyError):
        pass

    try:
        urllib.request.urlopen(os.environ["CCR_BASE_URL"], timeout=2.0)
        reachable = True
    except urllib.error.HTTPError:
        reachable = True
    except Exception:
        reachable = False

    print(f"CCR {base_url} — {'reachable' if reachable else 'UNREACHABLE'}")
    sys.exit(0)
except Exception:
    # Any unexpected crash (e.g. a permission error reading env_path) must
    # report as ERROR, not silently masquerade as "off" — sys.exit(1)/(0)
    # above raise SystemExit, a BaseException, so they pass through this
    # except Exception unaffected.
    sys.exit(2)
