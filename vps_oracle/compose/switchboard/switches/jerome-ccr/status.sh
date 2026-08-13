#!/usr/bin/env python3
import os
import re
import sys
import urllib.error
import urllib.request

env_path = "/home/ubuntu/.claude-provider/jerome.env"
base_url_re = re.compile(r'^\s*(?:export\s+)?ANTHROPIC_BASE_URL=(\S+)')

base_url = None
if os.path.exists(env_path):
    with open(env_path) as f:
        for line in f:
            m = base_url_re.match(line)
            if m:
                base_url = m.group(1).strip("'\"")
                break

if base_url is None:
    sys.exit(1)

try:
    urllib.request.urlopen(os.environ["CCR_BASE_URL"], timeout=2.0)
    reachable = True
except urllib.error.HTTPError:
    reachable = True
except Exception:
    reachable = False

print(f"CCR {base_url} — {'reachable' if reachable else 'UNREACHABLE'}")
sys.exit(0)
