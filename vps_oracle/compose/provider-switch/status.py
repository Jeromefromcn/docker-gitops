"""Live-state scanning for the jerome/bridget provider groups.

No caching anywhere in this module by design — every call re-reads the
filesystem and re-probes the network, because the UI's whole point is
to never show a stale toggle position (R3/R4 in the design spec).
"""
import os
import re
import subprocess
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


def count_pending_sessions(group_dir):
    try:
        pids = subprocess.run(
            ["pgrep", "-f", "native-binary/claude"],
            capture_output=True, text=True, check=False,
        ).stdout.split()
    except FileNotFoundError:
        return 0
    count = 0
    for pid in pids:
        try:
            cwd = os.readlink(f"/proc/{pid}/cwd")
        except OSError:
            continue
        if cwd == group_dir or cwd.startswith(group_dir + "/"):
            count += 1
    return count


def scan_group(name, env_path, group_dir):
    config = read_config(env_path)
    reachable = check_connectivity(config["base_url"])
    pending = count_pending_sessions(group_dir)
    return {
        "name": name,
        "routed": config["routed"],
        "base_url": config["base_url"],
        "reachable": reachable,
        "pending_official_sessions": pending,
    }
