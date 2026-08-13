"""Generic config-driven switch engine.

Loads switches.ini, runs each switch's status/on/off scripts under the
timeout + locking + ERROR-on-broken-status contract documented in
docs/superpowers/specs/2026-08-13-switchboard-generic-toggle-design.md.
Every call re-reads switches.ini and re-runs the scripts — nothing here is
cached, by design (the UI's whole point is to never show a stale state).
"""
import configparser
import fcntl
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor

SWITCHES_DIR = os.path.join(os.path.dirname(__file__), "switches")
CONFIG_PATH = os.path.join(os.path.dirname(__file__), "switches.ini")
# Lock files live outside SWITCHES_DIR on purpose: switches/ is COPY'd into the
# image as root:root, but the container runs as an unprivileged uid — a lock
# file next to the scripts it protects would raise PermissionError on every
# toggle. LOCK_DIR is a separate, writable-by-the-container location instead.
LOCK_DIR = os.environ.get("LOCK_DIR", "/tmp/switchboard-locks")

STATUS_TIMEOUT = 5
ACTION_TIMEOUT = 15
MAX_WORKERS = 8


def load_switches(config_path=None):
    if config_path is None:
        config_path = CONFIG_PATH
    parser = configparser.ConfigParser()
    parser.read(config_path)
    switches = []
    for switch_id in parser.sections():
        section = parser[switch_id]
        switches.append({
            "id": switch_id,
            "group": section.get("group", ""),
            "label": section.get("label", switch_id),
            "on_label": section.get("on_label", "On"),
            "off_label": section.get("off_label", "Off"),
        })
    return switches


def _script_path(switch_id, name, switches_dir):
    return os.path.join(switches_dir, switch_id, name)


def check_status(switch_id, switches_dir=None):
    if switches_dir is None:
        switches_dir = SWITCHES_DIR
    path = _script_path(switch_id, "status.sh", switches_dir)
    try:
        result = subprocess.run(
            [path], capture_output=True, text=True, timeout=STATUS_TIMEOUT,
        )
    except (subprocess.TimeoutExpired, OSError):
        return {"state": "error", "detail": ""}
    detail = ""
    for line in result.stdout.splitlines():
        if line.strip():
            detail = line.strip()
            break
    if result.returncode == 0:
        state = "on"
    elif result.returncode == 2:
        state = "error"
    else:
        state = "off"
    return {"state": state, "detail": detail}


def scan_all(switches, switches_dir=None):
    if switches_dir is None:
        switches_dir = SWITCHES_DIR
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        pairs = list(pool.map(
            lambda s: (s["id"], check_status(s["id"], switches_dir)), switches,
        ))
        return dict(pairs)


def toggle(switch_id, switches_dir=None, lock_dir=None):
    if switches_dir is None:
        switches_dir = SWITCHES_DIR
    if lock_dir is None:
        lock_dir = LOCK_DIR
    lock_path = os.path.join(lock_dir, switch_id + ".lock")
    try:
        os.makedirs(lock_dir, exist_ok=True)
        lock_file = open(lock_path, "a+")
    except OSError as exc:
        return False, str(exc)
    with lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        status = check_status(switch_id, switches_dir)
        if status["state"] == "error":
            return False, "status check failed; refusing to toggle an unknown state"
        action = "off.sh" if status["state"] == "on" else "on.sh"
        path = _script_path(switch_id, action, switches_dir)
        try:
            result = subprocess.run(
                [path], capture_output=True, text=True, timeout=ACTION_TIMEOUT,
            )
        except (subprocess.TimeoutExpired, OSError) as exc:
            return False, str(exc)
        return result.returncode == 0, result.stderr
