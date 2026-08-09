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
        "group_dir": "/home/ubuntu/jerome",
    },
    "bridget": {
        "env_path": "/home/ubuntu/.claude-provider/bridget.env",
        "group_dir": "/home/ubuntu/bridget",
    },
}

_BASE_URL_RE = re.compile(r'^\s*(?:export\s+)?ANTHROPIC_BASE_URL=(\S+)\s*$')


def read_config(env_path):
    if not os.path.exists(env_path):
        return {"routed": False, "base_url": None}
    with open(env_path) as f:
        for line in f:
            m = _BASE_URL_RE.match(line)
            if m:
                return {"routed": True, "base_url": m.group(1)}
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


def scan_group(name, env_path, ccr_base_url):
    config = read_config(env_path)
    # Probe the CCR service URL the container can actually reach (ccr:8080 on
    # the proxy network), NOT the per-group base_url: that value points at the
    # HOST's 127.0.0.1:3456 (what the host-side claude CLI uses), which is
    # unreachable from this container's own namespace. ccr:8080 is the same
    # nginx → same gateway, so its liveness == the host CLI's CCR liveness.
    reachable = check_connectivity(ccr_base_url if config["routed"] else None)
    return {
        "name": name,
        "routed": config["routed"],
        "base_url": config["base_url"],
        "reachable": reachable,
    }
