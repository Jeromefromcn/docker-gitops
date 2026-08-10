"""Live-state scanning for the jerome/bridget provider groups.

No caching anywhere in this module by design — every call re-reads the
filesystem and re-probes the network, because the UI's whole point is
to never show a stale toggle position (R3/R4 in the design spec).
"""
import os
import re
import urllib.error
import urllib.request

GROUPS = {
    "jerome": {
        "env_path": "/home/ubuntu/.claude-provider/jerome.env",
    },
    "bridget": {
        "env_path": "/home/ubuntu/.claude-provider/bridget.env",
    },
}

# Matches up to the value token only — deliberately doesn't anchor on what
# follows it, so a trailing inline comment (`... # note`) or a quoted value
# (`="http://..."`) don't make a routed group misreport as Official.
_BASE_URL_RE = re.compile(r'^\s*(?:export\s+)?ANTHROPIC_BASE_URL=(\S+)')


def read_config(env_path):
    if not os.path.exists(env_path):
        return {"routed": False, "base_url": None}
    with open(env_path) as f:
        for line in f:
            m = _BASE_URL_RE.match(line)
            if m:
                return {"routed": True, "base_url": m.group(1).strip("'\"")}
    return {"routed": False, "base_url": None}


def check_connectivity(base_url, timeout=2.0):
    if base_url is None:
        return True
    try:
        urllib.request.urlopen(base_url, timeout=timeout)
        return True
    except urllib.error.HTTPError:
        return True  # 服务器活着，能应答就算连通，不管状态码
    except Exception:
        return False


def scan_group(name, env_path, ccr_reachable):
    # ccr_reachable is precomputed once by the caller (see app.py's do_GET)
    # via check_connectivity, rather than re-probed per group here — every
    # routed group shares the same CCR gateway, so probing it once per
    # request instead of once per group avoids redundant identical requests.
    config = read_config(env_path)
    reachable = ccr_reachable if config["routed"] else True
    return {
        "name": name,
        "routed": config["routed"],
        "base_url": config["base_url"],
        "reachable": reachable,
    }
