# switchboard 通用开关框架 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `vps_oracle/compose/provider-switch/` — a hardcoded two-provider (jerome/bridget CCR) toggle UI — into `vps_oracle/compose/switchboard/`, a generic config-driven toggle framework where adding or removing a switch never requires touching the engine's Python code, only a `switches.ini` entry and a `switches/<id>/{status,on,off}.sh` script trio.

**Architecture:** `config.py` is the generic engine: it parses `switches.ini` (stdlib `configparser`, not YAML — see Global Constraints), and for each switch it runs `status.sh` (exit 0/non-zero → on/off, first stdout line → optional detail text), and on `POST /toggle` re-checks status under a per-switch lock and runs the opposite of `on.sh`/`off.sh`. `app.py` is the thin HTTP layer (`http.server`, stdlib only) that renders the table and dispatches `/toggle`. The two existing CCR switches (jerome, bridget) become the first two entries — their logic (read env file, atomic tmp+rename write, CCR connectivity probe) moves out of `app.py`/`status.py` and into `switches/jerome-ccr/*.sh` and `switches/bridget-ccr/*.sh`, unchanged in behavior.

**Tech Stack:** Python 3.12 stdlib only (`http.server`, `configparser`, `subprocess`, `concurrent.futures`, `fcntl` — no third-party packages), POSIX `sh` scripts that shell out to `python3` for anything needing real parsing/atomicity, Docker Compose.

**Spec:** [`docs/superpowers/specs/2026-08-13-switchboard-generic-toggle-design.md`](../specs/2026-08-13-switchboard-generic-toggle-design.md)

## Global Constraints

- No third-party Python dependencies — stdlib only. This is why `switches.ini` uses `configparser` (INI), not YAML: the existing `provider-switch/README.md` documents "纯标准库无框架" as the pattern this service follows (matching `vikunja-notify-relay`), and the `Dockerfile` has no `pip install` step. Introducing PyYAML would break that.
- Pin image tags/digests, never `latest` (README, CLAUDE.md). Image stays `switchboard:1.0.0`.
- `TZ: "Asia/Hong_Kong"`, `logging: {driver: json-file, options: {max-size: "10m", max-file: "5"}}`, `restart: unless-stopped`, `security_opt: [no-new-privileges:true]` — all already present in the current `docker-compose.yml`; preserve them through the rename (README).
- No host-published ports; reached only via the `proxy` Docker network + NPM (README) — unchanged from today.
- Never commit secrets. `CCR_TOKEN`/`CCR_CLIENT_TOKEN` stay in `.env` (gitignored) and are inherited by switch scripts via the container's environment — never written into `switches.ini` or any committed script.
- One change per commit, scoped to one logical step (CLAUDE.md).
- User-visible copy (homepage card description) in English; repo comments/docs/commit messages in Chinese, matching this repo's existing convention (root README "约定" section) and the existing code in this exact service.
- **Do not run `docker compose up -d` (or `--build`) for this stack during plan execution.** It replaces the live `provider-switch` container that real `claude` CLI sessions under `~/jerome/` and `~/bridget/` currently depend on for provider routing (CLAUDE.md: confirm before applying changes that recreate a container). Tasks in this plan stop at `docker compose build` (image build only, does not touch the running container). The actual cutover is called out separately in "Manual Follow-up" at the end of this plan and needs a human go-ahead at execution time.
- **Never execute a committed switch script against its real hardcoded host path** (`/home/ubuntu/.claude-provider/jerome.env` / `bridget.env`) during testing/verification — those files are live and read by real `claude` sessions right now. Task 9/10's verification steps use `sed`-substituted scratch copies instead; follow them exactly.
- Do not `git push` as part of this plan. All tasks end at a local commit on `main` (matching this repo's existing workflow of direct commits to `main`). Pushing is called out separately in "Manual Follow-up" because it triggers ArgoCD to auto-sync the homepage change onto the live k3s cluster.

---

## Task 1: Rename `provider-switch/` → `switchboard/` (pure rename, no content change)

**Files:**
- Rename (git mv): `vps_oracle/compose/provider-switch/` → `vps_oracle/compose/switchboard/` (all files inside move as-is)

**Interfaces:** None — this task changes no code, only the directory path. Confirms the existing test suite is unaffected by the move before any content changes begin.

- [ ] **Step 1: Rename the directory with git mv (preserves history)**

```bash
cd /home/ubuntu/jerome/docker-gitops
git mv vps_oracle/compose/provider-switch vps_oracle/compose/switchboard
```

- [ ] **Step 2: Verify the existing tests still pass unchanged (imports are relative to `__file__`, so a pure move shouldn't break anything)**

```bash
cd vps_oracle/compose/switchboard
python3 -m unittest test_app.py test_status.py -v
```

Expected: all existing tests pass (same as before the move — this step only proves the rename itself introduced no breakage; `status.py`/`test_status.py` still exist at this point and get retired in Task 8).

- [ ] **Step 3: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add -A
git commit -m "Rename provider-switch to switchboard ahead of generic toggle-framework rewrite"
```

---

## Task 2: `config.py` — `load_switches()`

**Files:**
- Create: `vps_oracle/compose/switchboard/config.py`
- Test: `vps_oracle/compose/switchboard/test_config.py`

**Interfaces:**
- Produces: `load_switches(config_path=None) -> list[dict]`. Each dict has keys `id`, `group`, `label`, `on_label`, `off_label` (all strings; `group` defaults to `""`, `on_label`/`off_label` default to `"On"`/`"Off"`). `config_path=None` means "use the module-level `CONFIG_PATH`, read fresh at call time" — this indirection (not a function-signature default) is required so tests can monkeypatch `config.CONFIG_PATH` and have it take effect (a literal `config_path=CONFIG_PATH` default would freeze the value at import time, not call time).
- Also produces module constants later tasks rely on: `SWITCHES_DIR`, `CONFIG_PATH`, `STATUS_TIMEOUT=5`, `ACTION_TIMEOUT=15`, `MAX_WORKERS=8`.

- [ ] **Step 1: Write the failing test**

```bash
cat > vps_oracle/compose/switchboard/test_config.py <<'EOF'
import os
import sys
import tempfile
import textwrap
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import config


class TestLoadSwitches(unittest.TestCase):
    def test_parses_sections_into_switch_dicts(self):
        with tempfile.TemporaryDirectory() as tmp:
            ini_path = os.path.join(tmp, "switches.ini")
            with open(ini_path, "w") as f:
                f.write(textwrap.dedent("""\
                    [demo]
                    group = Test
                    label = Demo
                    on_label = Enabled
                    off_label = Disabled
                    """))
            switches = config.load_switches(ini_path)
            self.assertEqual(switches, [{
                "id": "demo",
                "group": "Test",
                "label": "Demo",
                "on_label": "Enabled",
                "off_label": "Disabled",
            }])

    def test_missing_optional_fields_fall_back_to_defaults(self):
        with tempfile.TemporaryDirectory() as tmp:
            ini_path = os.path.join(tmp, "switches.ini")
            with open(ini_path, "w") as f:
                f.write("[bare]\n")
            switches = config.load_switches(ini_path)
            self.assertEqual(switches, [{
                "id": "bare",
                "group": "",
                "label": "bare",
                "on_label": "On",
                "off_label": "Off",
            }])

    def test_missing_config_file_is_empty_list(self):
        switches = config.load_switches("/tmp/does-not-exist-switches.ini")
        self.assertEqual(switches, [])
EOF
```

The `if __name__ == "__main__": unittest.main()` boilerplate is deliberately *not* added here — Tasks 3/4 append more test classes with `cat >>`, and Task 5 is the last one to append, so it adds that block once, at the true end of the file. Every "run test" step in this plan uses `python3 -m unittest test_config.py`, which imports the module (so `__name__` is `"test_config"`, not `"__main__"`) — the guard is never exercised either way, but keeping it only at the real end avoids a confusing mid-file placement.

- [ ] **Step 2: Run test to verify it fails (module doesn't exist yet)**

```bash
cd vps_oracle/compose/switchboard && python3 -m unittest test_config.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'config'`.

- [ ] **Step 3: Write minimal implementation**

```bash
cat > vps_oracle/compose/switchboard/config.py <<'EOF'
"""Generic config-driven switch engine.

Loads switches.ini, runs each switch's status/on/off scripts under the
timeout + locking + ERROR-on-broken-status contract documented in
docs/superpowers/specs/2026-08-13-switchboard-generic-toggle-design.md.
Every call re-reads switches.ini and re-runs the scripts — nothing here is
cached, by design (the UI's whole point is to never show a stale state).
"""
import configparser
import os

SWITCHES_DIR = os.path.join(os.path.dirname(__file__), "switches")
CONFIG_PATH = os.path.join(os.path.dirname(__file__), "switches.ini")

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
EOF
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd vps_oracle/compose/switchboard && python3 -m unittest test_config.py -v
```

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/switchboard/config.py vps_oracle/compose/switchboard/test_config.py
git commit -m "Add switchboard config.py: load_switches() parses switches.ini"
```

---

## Task 3: `config.py` — `check_status()`

**Files:**
- Modify: `vps_oracle/compose/switchboard/config.py`
- Test: `vps_oracle/compose/switchboard/test_config.py`

**Interfaces:**
- Consumes: nothing new from Task 2 beyond the module constants.
- Produces: `check_status(switch_id, switches_dir=None) -> {"state": "on"|"off"|"error", "detail": str}`. Runs `<switches_dir>/<switch_id>/status.sh` with a timeout of `STATUS_TIMEOUT` seconds. Exit 0 → `"on"`, non-zero → `"off"`. First non-blank stdout line (stripped) → `detail`, else `""`. Timeout, missing script, or any `OSError` → `{"state": "error", "detail": ""}` — never silently treated as `"off"` (spec §3.3/§3.4: an error state must never masquerade as a safe "off").

- [ ] **Step 1: Write the failing tests**

```bash
cat >> vps_oracle/compose/switchboard/test_config.py <<'EOF'


import stat


def _write_script(path, body):
    with open(path, "w") as f:
        f.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)


class TestCheckStatus(unittest.TestCase):
    def _switch_dir(self, tmp, switch_id):
        path = os.path.join(tmp, switch_id)
        os.makedirs(path)
        return path

    def test_exit_zero_is_on_with_detail_from_stdout(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = self._switch_dir(tmp, "demo")
            _write_script(os.path.join(d, "status.sh"), "#!/bin/sh\necho hello\nexit 0\n")
            result = config.check_status("demo", switches_dir=tmp)
            self.assertEqual(result, {"state": "on", "detail": "hello"})

    def test_exit_nonzero_is_off_with_no_detail_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = self._switch_dir(tmp, "demo")
            _write_script(os.path.join(d, "status.sh"), "#!/bin/sh\nexit 1\n")
            result = config.check_status("demo", switches_dir=tmp)
            self.assertEqual(result, {"state": "off", "detail": ""})

    def test_timeout_is_error_not_off(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = self._switch_dir(tmp, "demo")
            _write_script(os.path.join(d, "status.sh"), "#!/bin/sh\nsleep 10\n")
            original_timeout = config.STATUS_TIMEOUT
            config.STATUS_TIMEOUT = 0.2
            try:
                result = config.check_status("demo", switches_dir=tmp)
            finally:
                config.STATUS_TIMEOUT = original_timeout
            self.assertEqual(result, {"state": "error", "detail": ""})

    def test_missing_script_is_error_not_off(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._switch_dir(tmp, "demo")
            result = config.check_status("demo", switches_dir=tmp)
            self.assertEqual(result, {"state": "error", "detail": ""})
EOF
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd vps_oracle/compose/switchboard && python3 -m unittest test_config.py -v
```

Expected: FAIL with `AttributeError: module 'config' has no attribute 'check_status'`.

- [ ] **Step 3: Implement**

```bash
python3 - <<'EOF'
import re
path = "vps_oracle/compose/switchboard/config.py"
src = open(path).read()
src = src.replace(
    "import configparser\nimport os\n",
    "import configparser\nimport os\nimport subprocess\n",
)
src += '''

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
    state = "on" if result.returncode == 0 else "off"
    return {"state": state, "detail": detail}
'''
open(path, "w").write(src)
EOF
```

- [ ] **Step 4: Run to verify it passes**

```bash
cd vps_oracle/compose/switchboard && python3 -m unittest test_config.py -v
```

Expected: PASS (7 tests total).

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/switchboard/config.py vps_oracle/compose/switchboard/test_config.py
git commit -m "Add switchboard config.py: check_status() runs status.sh with timeout"
```

---

## Task 4: `config.py` — `scan_all()`

**Files:**
- Modify: `vps_oracle/compose/switchboard/config.py`
- Test: `vps_oracle/compose/switchboard/test_config.py`

**Interfaces:**
- Consumes: `check_status(switch_id, switches_dir)` from Task 3.
- Produces: `scan_all(switches, switches_dir=None) -> dict[str, {"state": str, "detail": str}]` keyed by switch id. Runs every switch's `check_status` concurrently via a bounded thread pool (`MAX_WORKERS=8`) so page load time is the slowest single check, not the sum (spec §3.4).

- [ ] **Step 1: Write the failing test**

```bash
cat >> vps_oracle/compose/switchboard/test_config.py <<'EOF'


class TestScanAll(unittest.TestCase):
    def test_scans_every_switch_and_keys_by_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            for switch_id, exit_code in [("a", "0"), ("b", "1")]:
                d = os.path.join(tmp, switch_id)
                os.makedirs(d)
                _write_script(os.path.join(d, "status.sh"), f"#!/bin/sh\nexit {exit_code}\n")
            switches = [{"id": "a"}, {"id": "b"}]
            scans = config.scan_all(switches, switches_dir=tmp)
            self.assertEqual(scans["a"]["state"], "on")
            self.assertEqual(scans["b"]["state"], "off")
EOF
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd vps_oracle/compose/switchboard && python3 -m unittest test_config.py -v
```

Expected: FAIL with `AttributeError: module 'config' has no attribute 'scan_all'`.

- [ ] **Step 3: Implement**

```bash
python3 - <<'EOF'
path = "vps_oracle/compose/switchboard/config.py"
src = open(path).read()
src = src.replace(
    "import subprocess\n",
    "import subprocess\nfrom concurrent.futures import ThreadPoolExecutor\n",
)
src += '''

def scan_all(switches, switches_dir=None):
    if switches_dir is None:
        switches_dir = SWITCHES_DIR
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        pairs = pool.map(
            lambda s: (s["id"], check_status(s["id"], switches_dir)), switches,
        )
    return dict(pairs)
'''
open(path, "w").write(src)
EOF
```

- [ ] **Step 4: Run to verify it passes**

```bash
cd vps_oracle/compose/switchboard && python3 -m unittest test_config.py -v
```

Expected: PASS (8 tests total).

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/switchboard/config.py vps_oracle/compose/switchboard/test_config.py
git commit -m "Add switchboard config.py: scan_all() runs status checks concurrently"
```

---

## Task 5: `config.py` — `toggle()`

**Files:**
- Modify: `vps_oracle/compose/switchboard/config.py`
- Test: `vps_oracle/compose/switchboard/test_config.py`

**Interfaces:**
- Consumes: `check_status()` from Task 3.
- Produces: `toggle(switch_id, switches_dir=None) -> (ok: bool, stderr: str)`. Acquires an `flock` on `<switches_dir>/<switch_id>/.lock` (serializes concurrent `/toggle` calls for the same switch — the engine owns this, not the scripts). Re-checks status *inside* the lock (avoids a check-then-act race), refuses to act if status is `"error"`. Runs `off.sh` if currently `"on"`, else `on.sh`, with `ACTION_TIMEOUT` seconds. Returns `(True, "")` on exit 0, else `(False, <stderr or exception text>)`.

- [ ] **Step 1: Write the failing tests**

```bash
cat >> vps_oracle/compose/switchboard/test_config.py <<'EOF'


class TestToggle(unittest.TestCase):
    def _write_switch(self, tmp, switch_id, status_exit, marker_path,
                       on_body=None, off_body=None):
        d = os.path.join(tmp, switch_id)
        os.makedirs(d)
        _write_script(os.path.join(d, "status.sh"), f"#!/bin/sh\nexit {status_exit}\n")
        _write_script(
            os.path.join(d, "on.sh"),
            on_body or f"#!/bin/sh\necho on > {marker_path}\nexit 0\n",
        )
        _write_script(
            os.path.join(d, "off.sh"),
            off_body or f"#!/bin/sh\necho off > {marker_path}\nexit 0\n",
        )
        return d

    def test_currently_off_runs_on_script(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = os.path.join(tmp, "marker")
            self._write_switch(tmp, "demo", status_exit="1", marker_path=marker)
            ok, stderr = config.toggle("demo", switches_dir=tmp)
            self.assertTrue(ok)
            self.assertEqual(open(marker).read().strip(), "on")

    def test_currently_on_runs_off_script(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = os.path.join(tmp, "marker")
            self._write_switch(tmp, "demo", status_exit="0", marker_path=marker)
            ok, stderr = config.toggle("demo", switches_dir=tmp)
            self.assertTrue(ok)
            self.assertEqual(open(marker).read().strip(), "off")

    def test_action_failure_returns_stderr(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._write_switch(
                tmp, "demo", status_exit="1", marker_path=os.path.join(tmp, "marker"),
                on_body="#!/bin/sh\necho boom >&2\nexit 1\n",
            )
            ok, stderr = config.toggle("demo", switches_dir=tmp)
            self.assertFalse(ok)
            self.assertIn("boom", stderr)

    def test_unknown_status_refuses_to_toggle(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "demo"))  # no status.sh at all
            ok, stderr = config.toggle("demo", switches_dir=tmp)
            self.assertFalse(ok)


if __name__ == "__main__":
    unittest.main()
EOF
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd vps_oracle/compose/switchboard && python3 -m unittest test_config.py -v
```

Expected: FAIL with `AttributeError: module 'config' has no attribute 'toggle'`.

- [ ] **Step 3: Implement**

```bash
python3 - <<'EOF'
path = "vps_oracle/compose/switchboard/config.py"
src = open(path).read()
src = src.replace("import os\n", "import fcntl\nimport os\n")
src += '''

def toggle(switch_id, switches_dir=None):
    if switches_dir is None:
        switches_dir = SWITCHES_DIR
    lock_path = _script_path(switch_id, ".lock", switches_dir)
    with open(lock_path, "a+") as lock_file:
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
'''
open(path, "w").write(src)
EOF
```

- [ ] **Step 4: Run to verify it passes**

```bash
cd vps_oracle/compose/switchboard && python3 -m unittest test_config.py -v
```

Expected: PASS (12 tests total).

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/switchboard/config.py vps_oracle/compose/switchboard/test_config.py
git commit -m "Add switchboard config.py: toggle() locks, re-checks status, runs on/off script"
```

---

## Task 6: `app.py` — generic `GET /` (render_page + do_GET)

**Files:**
- Modify: `vps_oracle/compose/switchboard/app.py` (full rewrite of `render_page`/`Handler.do_GET`; also writes a placeholder `do_POST` and the real `__main__` server-startup block — `do_POST` is replaced with the real `/toggle` handling in Task 7, `__main__` is not touched again)
- Test: `vps_oracle/compose/switchboard/test_app.py` (full rewrite, replacing the old `GROUPS`-monkeypatch tests)

**Interfaces:**
- Consumes: `config.load_switches()`, `config.scan_all(switches)` from Tasks 2/4. Also relies on being able to monkeypatch `config.CONFIG_PATH` / `config.SWITCHES_DIR` at test time (works because Task 2-5 used the `if x is None: x = MODULE_CONST` pattern instead of literal parameter defaults).
- Produces: `render_page(switches, scans) -> str` (HTML). `Handler` (a `BaseHTTPRequestHandler` subclass) — `do_GET` serves `/`.

This task replaces the whole file. The old `do_POST`/`toggle_group`/`PROVIDER_LABELS`/CCR-specific env vars are removed here; Task 7 adds the new generic `do_POST`.

- [ ] **Step 1: Write the failing tests (new test_app.py, replacing the old one)**

```bash
cat > vps_oracle/compose/switchboard/test_app.py <<'EOF'
import os
import stat
import sys
import tempfile
import textwrap
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from threading import Thread

sys.path.insert(0, os.path.dirname(__file__))
import app
import config


def _write_script(path, body):
    with open(path, "w") as f:
        f.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)


class SwitchboardTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.switches_dir = os.path.join(self.tmp.name, "switches")
        os.makedirs(self.switches_dir)
        self.config_path = os.path.join(self.tmp.name, "switches.ini")

        self.original_config_path = config.CONFIG_PATH
        self.original_switches_dir = config.SWITCHES_DIR
        config.CONFIG_PATH = self.config_path
        config.SWITCHES_DIR = self.switches_dir
        self.addCleanup(self._restore_config)

    def _restore_config(self):
        config.CONFIG_PATH = self.original_config_path
        config.SWITCHES_DIR = self.original_switches_dir

    def _write_ini(self, content):
        with open(self.config_path, "w") as f:
            f.write(content)

    def _write_switch(self, switch_id, status_exit, on_body="exit 0\n", off_body="exit 0\n"):
        d = os.path.join(self.switches_dir, switch_id)
        os.makedirs(d)
        _write_script(os.path.join(d, "status.sh"), f"#!/bin/sh\nexit {status_exit}\n")
        _write_script(os.path.join(d, "on.sh"), f"#!/bin/sh\n{on_body}")
        _write_script(os.path.join(d, "off.sh"), f"#!/bin/sh\n{off_body}")

    def start_server(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
        Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        return server.server_port


class TestDoGet(SwitchboardTestCase):
    def test_renders_switch_state_and_labels(self):
        self._write_ini(textwrap.dedent("""\
            [demo]
            group = Test
            label = Demo
            on_label = Enabled
            off_label = Disabled
            """))
        self._write_switch("demo", status_exit="0")
        port = self.start_server()
        body = urllib.request.urlopen(f"http://127.0.0.1:{port}/").read().decode()
        self.assertIn("Demo", body)
        self.assertIn("Enabled", body)
        self.assertIn("Switch to Disabled", body)

    def test_error_state_hides_toggle_button(self):
        self._write_ini("[demo]\nlabel = Demo\n")
        os.makedirs(os.path.join(self.switches_dir, "demo"))  # no status.sh
        port = self.start_server()
        body = urllib.request.urlopen(f"http://127.0.0.1:{port}/").read().decode()
        self.assertIn("ERROR", body)
        self.assertNotIn("<form", body)

    def test_unknown_path_is_404(self):
        self._write_ini("")
        port = self.start_server()
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/nope")
        self.assertEqual(ctx.exception.code, 404)
EOF
```

Same reasoning as `test_config.py` in Task 2: the `if __name__ == "__main__":` boilerplate is deferred to Task 7, which is the last task to append to this file, so it ends up once, at the true end.

- [ ] **Step 2: Run to verify it fails**

```bash
cd vps_oracle/compose/switchboard && python3 -m unittest test_app.py -v
```

Expected: FAIL — `app.py` still imports the retired `status` module / references `CCR_BASE_URL` etc. and won't even import cleanly against the new tests.

- [ ] **Step 3: Rewrite `app.py`**

```bash
cat > vps_oracle/compose/switchboard/app.py <<'EOF'
"""Generic config-driven switch UI. GET / re-scans every switch's status.sh
live; nothing is cached. POST /toggle runs the appropriate on.sh/off.sh for
one switch. See docs/superpowers/specs/2026-08-13-switchboard-generic-toggle-design.md.
"""
import html
import os
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import config

STATE_LABEL_KEY = {"on": "on_label", "off": "off_label"}


def render_page(switches, scans):
    rows = []
    for s in switches:
        scan = scans[s["id"]]
        state = scan["state"]
        group = html.escape(s["group"])
        name = html.escape(s["label"])
        detail = html.escape(scan["detail"])
        if state == "error":
            state_cell = "ERROR"
            action_cell = ""
        else:
            state_cell = html.escape(s[STATE_LABEL_KEY[state]])
            other = "off" if state == "on" else "on"
            action_label = html.escape(s[STATE_LABEL_KEY[other]])
            action_cell = (
                f'<form method="post" action="/toggle">'
                f'<input type="hidden" name="id" value="{html.escape(s["id"])}">'
                f'<button type="submit">Switch to {action_label}</button></form>'
            )
        rows.append(f"""
        <tr>
          <td>{group}</td>
          <td>{name}</td>
          <td>{state_cell}</td>
          <td>{detail}</td>
          <td>{action_cell}</td>
        </tr>""")
    return f"""<!doctype html><html><head><title>Switchboard</title></head>
<body>
<h1>Switchboard</h1>
<p>State is re-scanned on every page load — nothing here is cached.</p>
<table border="1" cellpadding="6">
<tr><th>Group</th><th>Name</th><th>State</th><th>Detail</th><th>Action</th></tr>
{''.join(rows)}
</table>
</body></html>"""


def render_error_page(switch_id, stderr):
    return f"""<!doctype html><html><head><title>Switchboard — error</title></head>
<body>
<h1>Toggle failed: {html.escape(switch_id)}</h1>
<pre>{html.escape(stderr)}</pre>
<p><a href="/">Back</a></p>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def do_GET(self):
        if self.path != "/":
            self.send_response(404)
            self.end_headers()
            return
        switches = config.load_switches()
        scans = config.scan_all(switches)
        body = render_page(switches, scans).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.send_response(404)
        self.end_headers()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    bind_host = os.environ.get("BIND_HOST", "127.0.0.1")
    server = ThreadingHTTPServer((bind_host, port), Handler)
    print(f"listening on {bind_host}:{port}", flush=True)
    server.serve_forever()
EOF
```

`do_POST` is a placeholder 404 for now — Task 7 replaces it with the real `/toggle` handling. `urllib.parse` is imported but unused until Task 7; that's fine, it's about to be used.

- [ ] **Step 4: Run to verify it passes**

```bash
cd vps_oracle/compose/switchboard && python3 -m unittest test_app.py -v
```

Expected: PASS (3 tests — `TestDoGet`'s three tests; no `TestDoPost` yet, that's Task 7).

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/switchboard/app.py vps_oracle/compose/switchboard/test_app.py
git commit -m "Rewrite switchboard app.py GET / as a generic config-driven renderer"
```

---

## Task 7: `app.py` — generic `POST /toggle`

**Files:**
- Modify: `vps_oracle/compose/switchboard/app.py`
- Test: `vps_oracle/compose/switchboard/test_app.py`

**Interfaces:**
- Consumes: `config.load_switches()`, `config.toggle(switch_id)` from Tasks 2/5. `render_error_page(switch_id, stderr)` from Task 6.
- Produces: `Handler.do_POST` handling `/toggle` — reads `id` from a `application/x-www-form-urlencoded` body, 400s on unknown/missing id, calls `config.toggle`, 303-redirects to `/` on success, 500s with `render_error_page` on failure.

- [ ] **Step 1: Write the failing tests**

```bash
cat >> vps_oracle/compose/switchboard/test_app.py <<'EOF'


class TestDoPost(SwitchboardTestCase):
    def test_toggle_runs_on_script_and_redirects(self):
        self._write_ini("[demo]\nlabel = Demo\n")
        marker = os.path.join(self.tmp.name, "marker")
        self._write_switch("demo", status_exit="1", on_body=f"echo on > {marker}\nexit 0\n")
        port = self.start_server()
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/toggle", data=b"id=demo", method="POST",
        )
        resp = urllib.request.urlopen(req)  # urllib follows the 303 redirect
        self.assertEqual(resp.status, 200)
        self.assertEqual(open(marker).read().strip(), "on")

    def test_unknown_switch_id_is_rejected(self):
        self._write_ini("[demo]\nlabel = Demo\n")
        self._write_switch("demo", status_exit="1")
        port = self.start_server()
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/toggle", data=b"id=not-a-real-switch", method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req)
        self.assertEqual(ctx.exception.code, 400)

    def test_action_failure_renders_error_page(self):
        self._write_ini("[demo]\nlabel = Demo\n")
        self._write_switch("demo", status_exit="1", on_body="echo boom >&2\nexit 1\n")
        port = self.start_server()
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/toggle", data=b"id=demo", method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req)
        self.assertEqual(ctx.exception.code, 500)
        self.assertIn(b"boom", ctx.exception.read())


if __name__ == "__main__":
    unittest.main()
EOF
```

This is the last task to append to `test_app.py`, so this is where its `if __name__ == "__main__":` boilerplate finally lands (Task 6 deliberately omitted it — see the note there).

- [ ] **Step 2: Run to verify it fails**

```bash
cd vps_oracle/compose/switchboard && python3 -m unittest test_app.py -v
```

Expected: FAIL — `do_POST` currently always 404s, so all three new tests fail (first two expect different codes/behavior, third expects a 500 with "boom").

- [ ] **Step 3: Implement `do_POST`**

```bash
python3 - <<'EOF'
path = "vps_oracle/compose/switchboard/app.py"
src = open(path).read()
old = '''    def do_POST(self):
        self.send_response(404)
        self.end_headers()'''
new = '''    def do_POST(self):
        if self.path != "/toggle":
            self.send_response(404)
            self.end_headers()
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"bad Content-Length")
            return
        raw = self.rfile.read(length) if length else b""
        fields = urllib.parse.parse_qs(raw.decode())
        switch_id = (fields.get("id") or [""])[0]
        known_ids = {s["id"] for s in config.load_switches()}
        if switch_id not in known_ids:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"unknown switch")
            return
        ok, stderr = config.toggle(switch_id)
        if not ok:
            body = render_error_page(switch_id, stderr).encode()
            self.send_response(500)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(303)
        self.send_header("Location", "/")
        self.end_headers()'''
assert old in src
src = src.replace(old, new)
open(path, "w").write(src)
EOF
```

- [ ] **Step 4: Run to verify it passes**

```bash
cd vps_oracle/compose/switchboard && python3 -m unittest test_app.py -v
```

Expected: PASS (6 tests total).

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/switchboard/app.py vps_oracle/compose/switchboard/test_app.py
git commit -m "Implement switchboard app.py POST /toggle against the generic engine"
```

---

## Task 8: Retire `status.py`/`test_status.py`, update Dockerfile's Python file list

**Files:**
- Delete: `vps_oracle/compose/switchboard/status.py`, `vps_oracle/compose/switchboard/test_status.py`
- Modify: `vps_oracle/compose/switchboard/Dockerfile`

**Interfaces:** None — `app.py` no longer imports `status` as of Task 6, so this is pure cleanup of now-dead files.

- [ ] **Step 1: Confirm nothing still references `status.py`**

```bash
cd vps_oracle/compose/switchboard
grep -rn "import status\|from status" . --include="*.py"
```

Expected: no output (Task 6 already removed the only import).

- [ ] **Step 2: Delete the dead files**

```bash
git rm vps_oracle/compose/switchboard/status.py vps_oracle/compose/switchboard/test_status.py
```

- [ ] **Step 3: Update the Dockerfile's COPY list (switches.ini/switches/ are added in Task 11 once they exist — for now just drop status.py)**

Read the current file first:

```bash
cat vps_oracle/compose/switchboard/Dockerfile
```

It currently reads:

```dockerfile
FROM python:3.12.7-alpine3.20
WORKDIR /app
COPY status.py app.py ./
CMD ["python3", "app.py"]
```

Replace the `COPY` line:

```bash
python3 - <<'EOF'
path = "vps_oracle/compose/switchboard/Dockerfile"
src = open(path).read()
src = src.replace("COPY status.py app.py ./", "COPY config.py app.py ./")
open(path, "w").write(src)
EOF
```

- [ ] **Step 4: Run the full test suite to confirm nothing broke**

```bash
cd vps_oracle/compose/switchboard && python3 -m unittest discover -v
```

Expected: PASS (`test_app.py` + `test_config.py`, 18 tests total; no more `test_status.py`).

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/switchboard/Dockerfile
git commit -m "Remove dead status.py/test_status.py, point Dockerfile at config.py"
```

---

## Task 9: `jerome-ccr` switch — real scripts + `switches.ini` entry

**Files:**
- Create: `vps_oracle/compose/switchboard/switches/jerome-ccr/status.sh`, `on.sh`, `off.sh`
- Create: `vps_oracle/compose/switchboard/switches.ini`

**Interfaces:** None consumed from other tasks (these are standalone scripts, run by `config.py`'s subprocess calls per the contract from Tasks 3/5). Produces the `jerome-ccr` switch, consumed by the running system once deployed (Manual Follow-up) and by `../ccr/README.md` (Task 13).

This migrates the old `toggle_group()`/`read_config()`/`check_connectivity()` logic (previously `app.py`+`status.py`, both now deleted) into three scripts scoped to this one switch. Behavior is unchanged: same env file, same atomic tmp+rename write, same CCR connectivity probe. **These scripts hardcode the real, live path `/home/ubuntu/.claude-provider/jerome.env` — do not execute them directly against that path during verification. Use the scratch-copy technique in Step 2/4/6 instead.**

- [ ] **Step 1: Write `status.sh`**

The script contract only requires an executable file — the interpreter is whatever the shebang says, not the `.sh` extension. Writing it directly as `#!/usr/bin/env python3` (rather than a `#!/bin/sh` wrapper that `exec`s into a nested `python3 - <<'PY'` heredoc) gets the same atomic-write/regex correctness this logic needs without the extra layer:

```bash
mkdir -p vps_oracle/compose/switchboard/switches/jerome-ccr
cat > vps_oracle/compose/switchboard/switches/jerome-ccr/status.sh <<'PY'
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
PY
chmod +x vps_oracle/compose/switchboard/switches/jerome-ccr/status.sh
```

- [ ] **Step 2: Verify `status.sh` against a scratch env file (never the real path)**

```bash
cd vps_oracle/compose/switchboard/switches/jerome-ccr

# Case A: routed to CCR, CCR unreachable (closed port, like test_app.py's convention)
tmp_env=$(mktemp)
printf 'export ANTHROPIC_BASE_URL=http://127.0.0.1:3456\n' > "$tmp_env"
tmp_script=$(mktemp)
sed "s#/home/ubuntu/.claude-provider/jerome.env#$tmp_env#" status.sh > "$tmp_script"
chmod +x "$tmp_script"
CCR_BASE_URL=http://127.0.0.1:1 "$tmp_script"; echo "exit=$?"
# Expected: "CCR http://127.0.0.1:3456 — UNREACHABLE" and exit=0
rm -f "$tmp_env" "$tmp_script"

# Case B: not routed (empty file) → exit 1, no output
tmp_env=$(mktemp)
tmp_script=$(mktemp)
sed "s#/home/ubuntu/.claude-provider/jerome.env#$tmp_env#" status.sh > "$tmp_script"
chmod +x "$tmp_script"
CCR_BASE_URL=http://127.0.0.1:1 "$tmp_script"; echo "exit=$?"
# Expected: no output, exit=1
rm -f "$tmp_env" "$tmp_script"

cd /home/ubuntu/jerome/docker-gitops
```

- [ ] **Step 3: Write `on.sh` and `off.sh`**

Same reasoning as Step 1 — direct `#!/usr/bin/env python3` scripts, no shell wrapper:

```bash
cat > vps_oracle/compose/switchboard/switches/jerome-ccr/on.sh <<'PY'
#!/usr/bin/env python3
import os

env_path = "/home/ubuntu/.claude-provider/jerome.env"
tmp_path = env_path + ".tmp"
content = (
    f"export ANTHROPIC_BASE_URL={os.environ['CCR_HOST_BASE_URL']}\n"
    f"export ANTHROPIC_AUTH_TOKEN={os.environ['CCR_TOKEN']}\n"
)
with open(tmp_path, "w") as f:
    f.write(content)
os.replace(tmp_path, env_path)
PY

cat > vps_oracle/compose/switchboard/switches/jerome-ccr/off.sh <<'PY'
#!/usr/bin/env python3
import os

env_path = "/home/ubuntu/.claude-provider/jerome.env"
tmp_path = env_path + ".tmp"
content = "# 空 = 走官方订阅 OAuth。switchboard 是唯一应该改写这个文件的东西。\n"
with open(tmp_path, "w") as f:
    f.write(content)
os.replace(tmp_path, env_path)
PY

chmod +x vps_oracle/compose/switchboard/switches/jerome-ccr/on.sh
chmod +x vps_oracle/compose/switchboard/switches/jerome-ccr/off.sh
```

- [ ] **Step 4: Verify `on.sh`/`off.sh` against scratch files (never the real path)**

```bash
cd vps_oracle/compose/switchboard/switches/jerome-ccr

tmp_env=$(mktemp)
tmp_script=$(mktemp)
sed "s#/home/ubuntu/.claude-provider/jerome.env#$tmp_env#" on.sh > "$tmp_script"
chmod +x "$tmp_script"
CCR_HOST_BASE_URL=http://127.0.0.1:3456 CCR_TOKEN=test-token "$tmp_script"
cat "$tmp_env"
# Expected:
# export ANTHROPIC_BASE_URL=http://127.0.0.1:3456
# export ANTHROPIC_AUTH_TOKEN=test-token
test ! -e "$tmp_env.tmp" && echo "no leftover .tmp file: OK"
rm -f "$tmp_env" "$tmp_script"

tmp_env=$(mktemp)
tmp_script=$(mktemp)
sed "s#/home/ubuntu/.claude-provider/jerome.env#$tmp_env#" off.sh > "$tmp_script"
chmod +x "$tmp_script"
"$tmp_script"
cat "$tmp_env"
# Expected: the "# 空 = ..." comment line
rm -f "$tmp_env" "$tmp_script"

cd /home/ubuntu/jerome/docker-gitops
```

- [ ] **Step 5: Create `switches.ini` with the `jerome-ccr` entry**

```bash
cat > vps_oracle/compose/switchboard/switches.ini <<'EOF'
[jerome-ccr]
group = Provider
label = jerome
on_label = CCR
off_label = Official
EOF
```

- [ ] **Step 6: Run the full test suite once more (switches.ini now exists on disk, but every test still uses its own temp `switches.ini`/`switches_dir` via monkeypatching, so this must still pass unchanged)**

```bash
cd vps_oracle/compose/switchboard && python3 -m unittest discover -v
```

Expected: PASS (same 18 tests as Task 8).

- [ ] **Step 7: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/switchboard/switches/jerome-ccr vps_oracle/compose/switchboard/switches.ini
git commit -m "Add jerome-ccr switch: migrate CCR provider toggle for the jerome group"
```

---

## Task 10: `bridget-ccr` switch — real scripts + `switches.ini` entry

**Files:**
- Create: `vps_oracle/compose/switchboard/switches/bridget-ccr/status.sh`, `on.sh`, `off.sh`
- Modify: `vps_oracle/compose/switchboard/switches.ini`

**Interfaces:** Same as Task 9, mirrored for the `bridget` group. Deliberately duplicated rather than sharing a library with `jerome-ccr` (approved design tradeoff, spec §3.6 — at 2 switches this small a shared abstraction isn't worth the indirection).

- [ ] **Step 1: Write all three scripts (identical to Task 9's, only the env filename differs: `bridget.env` instead of `jerome.env`)**

Same as Task 9: direct `#!/usr/bin/env python3` scripts, no shell wrapper.

```bash
mkdir -p vps_oracle/compose/switchboard/switches/bridget-ccr

cat > vps_oracle/compose/switchboard/switches/bridget-ccr/status.sh <<'PY'
#!/usr/bin/env python3
import os
import re
import sys
import urllib.error
import urllib.request

env_path = "/home/ubuntu/.claude-provider/bridget.env"
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
PY

cat > vps_oracle/compose/switchboard/switches/bridget-ccr/on.sh <<'PY'
#!/usr/bin/env python3
import os

env_path = "/home/ubuntu/.claude-provider/bridget.env"
tmp_path = env_path + ".tmp"
content = (
    f"export ANTHROPIC_BASE_URL={os.environ['CCR_HOST_BASE_URL']}\n"
    f"export ANTHROPIC_AUTH_TOKEN={os.environ['CCR_TOKEN']}\n"
)
with open(tmp_path, "w") as f:
    f.write(content)
os.replace(tmp_path, env_path)
PY

cat > vps_oracle/compose/switchboard/switches/bridget-ccr/off.sh <<'PY'
#!/usr/bin/env python3
import os

env_path = "/home/ubuntu/.claude-provider/bridget.env"
tmp_path = env_path + ".tmp"
content = "# 空 = 走官方订阅 OAuth。switchboard 是唯一应该改写这个文件的东西。\n"
with open(tmp_path, "w") as f:
    f.write(content)
os.replace(tmp_path, env_path)
PY

chmod +x vps_oracle/compose/switchboard/switches/bridget-ccr/status.sh
chmod +x vps_oracle/compose/switchboard/switches/bridget-ccr/on.sh
chmod +x vps_oracle/compose/switchboard/switches/bridget-ccr/off.sh
```

- [ ] **Step 2: Verify all three against scratch files (same technique as Task 9, never the real `bridget.env`)**

```bash
cd vps_oracle/compose/switchboard/switches/bridget-ccr

tmp_env=$(mktemp)
printf 'export ANTHROPIC_BASE_URL=http://127.0.0.1:3456\n' > "$tmp_env"
tmp_script=$(mktemp)
sed "s#/home/ubuntu/.claude-provider/bridget.env#$tmp_env#" status.sh > "$tmp_script"
chmod +x "$tmp_script"
CCR_BASE_URL=http://127.0.0.1:1 "$tmp_script"; echo "exit=$?"
# Expected: "CCR http://127.0.0.1:3456 — UNREACHABLE" and exit=0
rm -f "$tmp_env" "$tmp_script"

tmp_env=$(mktemp)
tmp_script=$(mktemp)
sed "s#/home/ubuntu/.claude-provider/bridget.env#$tmp_env#" on.sh > "$tmp_script"
chmod +x "$tmp_script"
CCR_HOST_BASE_URL=http://127.0.0.1:3456 CCR_TOKEN=test-token "$tmp_script"
cat "$tmp_env"
# Expected: export ANTHROPIC_BASE_URL=... / export ANTHROPIC_AUTH_TOKEN=test-token
rm -f "$tmp_env" "$tmp_script"

tmp_env=$(mktemp)
tmp_script=$(mktemp)
sed "s#/home/ubuntu/.claude-provider/bridget.env#$tmp_env#" off.sh > "$tmp_script"
chmod +x "$tmp_script"
"$tmp_script"
cat "$tmp_env"
# Expected: the "# 空 = ..." comment line
rm -f "$tmp_env" "$tmp_script"

cd /home/ubuntu/jerome/docker-gitops
```

- [ ] **Step 3: Append the `bridget-ccr` entry to `switches.ini`**

```bash
cat >> vps_oracle/compose/switchboard/switches.ini <<'EOF'

[bridget-ccr]
group = Provider
label = bridget
on_label = CCR
off_label = Official
EOF
```

- [ ] **Step 4: Run the full test suite once more**

```bash
cd vps_oracle/compose/switchboard && python3 -m unittest discover -v
```

Expected: PASS (same 18 tests — real switches.ini/switches/ still aren't touched by any test).

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/switchboard/switches/bridget-ccr vps_oracle/compose/switchboard/switches.ini
git commit -m "Add bridget-ccr switch: migrate CCR provider toggle for the bridget group"
```

---

## Task 11: `docker-compose.yml` rename, final `Dockerfile`, build-only verification

**Files:**
- Modify: `vps_oracle/compose/switchboard/docker-compose.yml`
- Modify: `vps_oracle/compose/switchboard/Dockerfile`

**Interfaces:** None. This is the last code task — after this, the image builds successfully with everything needed (`config.py`, `app.py`, `switches.ini`, `switches/`), but the plan deliberately stops short of `docker compose up -d` (Global Constraints — that's in Manual Follow-up).

- [ ] **Step 1: Add `switches.ini` and `switches/` to the Dockerfile's COPY list**

```bash
cat vps_oracle/compose/switchboard/Dockerfile
```

Currently (after Task 8):

```dockerfile
FROM python:3.12.7-alpine3.20
WORKDIR /app
COPY config.py app.py ./
CMD ["python3", "app.py"]
```

```bash
cat > vps_oracle/compose/switchboard/Dockerfile <<'EOF'
FROM python:3.12.7-alpine3.20
WORKDIR /app
COPY config.py app.py switches.ini ./
COPY switches/ ./switches/
CMD ["python3", "app.py"]
EOF
```

- [ ] **Step 2: Rename the service/container/image in `docker-compose.yml`, update comments mentioning the old name**

Read the current file to confirm nothing else in it changed unexpectedly since the design was written:

```bash
cat vps_oracle/compose/switchboard/docker-compose.yml
```

Replace the whole file:

```bash
cat > vps_oracle/compose/switchboard/docker-compose.yml <<'EOF'
services:
  switchboard:
    build: .
    image: switchboard:1.0.0
    container_name: switchboard
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
    user: "1001:1001"   # jerome-ccr/bridget-ccr 开关需要以宿主机 ubuntu 用户写 ~/.claude-provider/ 下的文件，不能用 nobody
    # 挂在 proxy 网络上（和 grafana / vikunja / dify / ccr 等所有走 NPM 反代的
    # 服务一致），NPM 直接用容器名 switchboard:8091 反代进来。不再用
    # network_mode: host：那条路要为 NPM 单独在宿主机 INPUT 链开 iptables 规则
    # （host 网络监听走 INPUT，会被默认的 REJECT 挡掉；只有 docker published 端口
    # 靠 PREROUTING DNAT 绕过 INPUT），不可从 compose 复现。proxy 网络走 docker
    # FORWARD，容器互访天然放行，零 iptables。
    networks:
      - proxy
    environment:
      TZ: "Asia/Hong_Kong"
      PORT: "8091"
      # 容器只在 proxy 网络上、端口不发布到宿主机，绑 0.0.0.0 也只有 proxy 网络
      # 里的容器（NPM）+ 宿主机自己能连，LAN/公网都打不到——NPM 的 access list
      # 再做第二层把关。
      BIND_HOST: "0.0.0.0"
      # jerome-ccr/bridget-ccr 两个开关脚本要用的 CCR 地址，两个不同用途不能混用：
      # - CCR_BASE_URL: 探测用，容器名（ccr 和本服务都在 proxy 网络上）。
      #   跟各组 .env 里的 ANTHROPIC_BASE_URL 不同——那是宿主机上的 claude CLI
      #   要用的地址，容器够不到；但 ccr:8080 是同一个 nginx→gateway，活着与否等价。
      # - CCR_HOST_BASE_URL: 写入各组 .env 的 ANTHROPIC_BASE_URL 用，必须是宿主机
      #   能连到的地址（CCR 的 127.0.0.1:3456:8080 端口发布），因为 .env 是给宿主机
      #   上的 claude CLI 读的，不是给这个容器读的。写错成 CCR_BASE_URL 会让切换
      #   后的 claude CLI 去连一个只在容器网络里存在的地址，直接连不上。
      CCR_BASE_URL: "http://ccr:8080"
      CCR_HOST_BASE_URL: "http://127.0.0.1:3456"
      CCR_TOKEN: "${CCR_CLIENT_TOKEN}"   # CCR client key，走 .env
    env_file:
      - .env
    volumes:
      - /home/ubuntu/.claude-provider:/home/ubuntu/.claude-provider
    # NPM 反代：switchboard.jerome.cloudns.asia → switchboard:8091，access list=self-only。
    # 配置方法见 vps_oracle/compose/npm/README.md 的自动化 API 一节。

networks:
  proxy:
    external: true
EOF
```

- [ ] **Step 3: Build the image (build only — does NOT touch the currently-running `provider-switch` container, which keeps running under its own separate container/image name until the manual cutover)**

```bash
cd vps_oracle/compose/switchboard && docker compose build
```

Expected: image `switchboard:1.0.0` builds successfully. Confirm the two `.sh` trios kept their executable bit through the build:

```bash
docker run --rm switchboard:1.0.0 sh -c "ls -l /app/switches/jerome-ccr /app/switches/bridget-ccr"
```

Expected: all six `.sh` files show `-rwxr-xr-x` (or similar with the execute bit set) — if any show `-rw-r--r--`, the `chmod +x` from Tasks 9/10 didn't get committed with the executable bit; re-run `chmod +x` on the missing file(s), `git add`, and re-commit before proceeding.

- [ ] **Step 4: Run the full test suite one final time**

```bash
cd vps_oracle/compose/switchboard && python3 -m unittest discover -v
```

Expected: PASS (18 tests).

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/switchboard/docker-compose.yml vps_oracle/compose/switchboard/Dockerfile
git commit -m "Rename provider-switch service to switchboard in Dockerfile/docker-compose.yml"
```

---

## Task 12: `switchboard/README.md`

**Files:**
- Modify: `vps_oracle/compose/switchboard/README.md`

**Interfaces:** None — documentation only.

- [ ] **Step 1: Replace the file**

Current content:

```markdown
# vps_oracle/compose/provider-switch

切 Claude Code 后端 provider 的小 HTTP UI（单文件 stdlib，`app.py` + `status.py`）。挂在 `proxy` 网络上，NPM 反代成 `https://provider.jerome.cloudns.asia`（access list=self-only）。每次打开都实时重扫两组的 `.env` 状态 + 探测 CCR 可达性，点按钮原子改写 `/home/ubuntu/.claude-provider/<组>.env`。

整个分组切换系统（direnv + 分组 env + CCR + 本 UI + NPM）的完整文档、加新分组的步骤、四个坑、回滚等，见 [`../ccr/README.md`](../ccr/README.md)。
```

```bash
cat > vps_oracle/compose/switchboard/README.md <<'EOF'
# vps_oracle/compose/switchboard

通用的、配置驱动的开关 UI（stdlib，`app.py` + `config.py`）。挂在 `proxy` 网络上，NPM 反代成 `https://switchboard.jerome.cloudns.asia`（access list=self-only）。

引擎本身不知道任何具体开关是什么——它只读 `switches.ini` 拿到开关清单，对每个开关的 `switches/<id>/{status,on,off}.sh` 三个脚本发号施令：`GET /` 现场跑一遍每个开关的 `status.sh`（不缓存），`POST /toggle` 按当前状态跑 `on.sh` 或 `off.sh`。新增/删除开关只需要加/删一个 `switches/<id>/` 目录 + 三个脚本 + `switches.ini` 里的一个 section，不需要改 `app.py`/`config.py`。设计细节见 [`../../../docs/superpowers/specs/2026-08-13-switchboard-generic-toggle-design.md`](../../../docs/superpowers/specs/2026-08-13-switchboard-generic-toggle-design.md)。

当前登记的开关：

| id | 说明 |
|---|---|
| `jerome-ccr` | jerome 组的 Claude provider 切换（Official ↔ CCR/智谱） |
| `bridget-ccr` | bridget 组的 Claude provider 切换（Official ↔ CCR/智谱） |

这两个开关所属的整个分组切换系统（direnv + 分组 env + CCR + 本 UI + NPM）的完整文档、加新分组的步骤、已知的坑、回滚等，见 [`../ccr/README.md`](../ccr/README.md)。
EOF
```

- [ ] **Step 2: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/compose/switchboard/README.md
git commit -m "Rewrite switchboard README.md for the generic toggle framework"
```

---

## Task 13: Root `README.md` + `ccr/README.md` updates

**Files:**
- Modify: `README.md` (repo root)
- Modify: `vps_oracle/compose/ccr/README.md`

**Interfaces:** None — documentation only. This is the biggest doc task: `ccr/README.md` is the system's main doc and has ~9 distinct `provider-switch`-specific passages to update.

- [ ] **Step 1: Root `README.md` — update the "won't migrate to k3s" table row**

Current (line 32):

```
| `ccr` / `provider-switch` | CCR 的消费者是跑在**宿主机本身**（不是容器）的 `claude` CLI 进程，走不了 docker 网络，所以 CCR 例外地要发布端口，且刻意绑 `127.0.0.1` 不对外暴露（见 `docs/superpowers/specs/2026-08-09-claude-provider-group-switch-design.md`）。这条逻辑在 k3s 下同样成立：k3s 的 pod network 对宿主机进程来说一样是「外部」，要嘛发 NodePort 放弃 `127.0.0.1`-only 的隔离，要嘛留在宿主机层——架构上就不适合迁，跟风险评估无关。provider-switch 是 CCR 的配套开关，同理 |
```

New:

```
| `ccr` / `switchboard` | CCR 的消费者是跑在**宿主机本身**（不是容器）的 `claude` CLI 进程，走不了 docker 网络，所以 CCR 例外地要发布端口，且刻意绑 `127.0.0.1` 不对外暴露（见 `docs/superpowers/specs/2026-08-09-claude-provider-group-switch-design.md`）。这条逻辑在 k3s 下同样成立：k3s 的 pod network 对宿主机进程来说一样是「外部」，要嘛发 NodePort 放弃 `127.0.0.1`-only 的隔离，要嘛留在宿主机层——架构上就不适合迁，跟风险评估无关。switchboard 是 CCR 的配套开关（现已通用化为配置驱动的开关框架，jerome-ccr/bridget-ccr 只是其中两个开关），同理 |
```

Apply with a targeted string replacement (the row is unique in the file, safe to match on the leading cell text):

```bash
python3 - <<'EOF'
path = "README.md"
src = open(path).read()
old = "| `ccr` / `provider-switch` |"
new = "| `ccr` / `switchboard` |"
assert src.count(old) == 1
src = src.replace(old, new)
old2 = "provider-switch 是 CCR 的配套开关，同理 |"
new2 = "switchboard 是 CCR 的配套开关（现已通用化为配置驱动的开关框架，jerome-ccr/bridget-ccr 只是其中两个开关），同理 |"
assert src.count(old2) == 1
src = src.replace(old2, new2)
open(path, "w").write(src)
EOF
```

- [ ] **Step 2: `ccr/README.md` — apply all nine replacements**

Read the file first to have exact current text in view:

```bash
cat vps_oracle/compose/ccr/README.md
```

Apply each replacement (run as one script so a failed `assert` stops before any partial edit is left in an inconsistent state):

```bash
python3 - <<'EOF'
path = "vps_oracle/compose/ccr/README.md"
src = open(path).read()

replacements = [
    (
        "本目录放 CCR 本体；配套的切换 UI 在 `../provider-switch/`。这份 README 是整个分组切换系统的总文档。",
        "本目录放 CCR 本体；配套的切换 UI 在 `../switchboard/`（一个通用的配置驱动开关框架，jerome-ccr/bridget-ccr 只是其中两个开关）。这份 README 是整个分组切换系统的总文档。",
    ),
    (
        "2. **动态 `.claude-provider/<组名>.env`**：真正被改写的文件。空（或只有注释）= 走官方订阅；有两行 `export ANTHROPIC_BASE_URL=… / ANTHROPIC_AUTH_TOKEN=…` = 走 CCR。**provider-switch UI 是唯一应该改写这个文件的东西。**",
        "2. **动态 `.claude-provider/<组名>.env`**：真正被改写的文件。空（或只有注释）= 走官方订阅；有两行 `export ANTHROPIC_BASE_URL=… / ANTHROPIC_AUTH_TOKEN=…` = 走 CCR。**switchboard 的 `jerome-ccr`/`bridget-ccr` 开关是唯一应该改写这个文件的东西。**",
    ),
    (
        "4. **provider-switch UI**（`../provider-switch/`）：挂在 `proxy` 网络上的小 HTTP 服务，通过 NPM 反代成 `https://provider.jerome.cloudns.asia`（access list=self-only）。每次打开页面都**实时重扫**（不缓存）各组的 `.env` 状态 + 探测 CCR 是否可达，点按钮就原子地改写对应 `.env`。",
        "4. **switchboard UI**（`../switchboard/`）：挂在 `proxy` 网络上的通用配置驱动开关服务，通过 NPM 反代成 `https://switchboard.jerome.cloudns.asia`（access list=self-only）。jerome/bridget 的 CCR 切换是它登记的两个开关（`jerome-ccr`/`bridget-ccr`）。每次打开页面都**实时重扫**（不缓存）每个开关的状态；点按钮就跑对应开关的 `on.sh`/`off.sh` 原子改写对应 `.env`。",
    ),
    (
        '''# 3. 在 provider-switch 的 status.GROUPS 里登记这个组
#    （编辑 vps_oracle/compose/provider-switch/status.py 的 GROUPS 字典，
#     加 "alice": {"env_path": ".../alice.env"}）

# 4. 重建 provider-switch 让新组出现在 UI 里
cd vps_oracle/compose/provider-switch && docker compose up -d --build''',
        '''# 3. 在 switchboard 里登记一个新开关 alice-ccr：
#    - 复制 vps_oracle/compose/switchboard/switches/jerome-ccr/ 整个目录为
#      switches/alice-ccr/，把三个脚本里的 jerome.env 路径改成 alice.env
#    - 在 switches.ini 里加一个 section：
#      [alice-ccr]
#      group = Provider
#      label = alice
#      on_label = CCR
#      off_label = Official

# 4. 重建 switchboard 让新开关出现在 UI 里
cd vps_oracle/compose/switchboard && docker compose up -d --build''',
    ),
    (
        "CCR client key（`ccr-profile-…`）在 CCR 管理面板生成；provider-switch 容器通过 `.env` 里的 `CCR_CLIENT_TOKEN` 拿到同一个 key 来写 `.env` 文件。",
        "CCR client key（`ccr-profile-…`）在 CCR 管理面板生成；switchboard 容器通过 `.env` 里的 `CCR_CLIENT_TOKEN` 拿到同一个 key，`alice-ccr` 开关的 `on.sh` 用它写 `.env` 文件。",
    ),
    (
        '''3. **切换只对切换之后新开的 session 生效。** 已经在跑的 claude 进程环境变量已经定型，改 `.env` 不会回头改它。开新 session 才走新 provider。（UI 里那条「Switching only affects sessions started after the switch」就是提醒这个。）''',
        '''3. **切换只对切换之后新开的 session 生效。** 已经在跑的 claude 进程环境变量已经定型，改 `.env` 不会回头改它。开新 session 才走新 provider。''',
    ),
    (
        "curl -sS https://provider.jerome.cloudns.asia/ | grep -oE '<td>(jerome|bridget)</td>|<td>(Official|CCR \\(Zhipu\\))</td>'",
        "curl -sS https://switchboard.jerome.cloudns.asia/ | grep -oE '<td>(jerome|bridget)</td>|<td>(Official|CCR)</td>'",
    ),
    (
        '''- **改名**：改 `status.GROUPS` 的 key、把 `~/<旧>/` 目录和 `~/<旧>/.envrc` 一起 `mv` 成新名、`mv /home/ubuntu/.claude-provider/<旧>.env <新>.env`、重建 provider-switch。注意上面第 4 个坑——移动目录会断旧 session 的 resume 历史。
- **删除**：从 `status.GROUPS` 摘掉、删目录和 `.env`、重建 provider-switch。''',
        '''- **改名**：把 `switches/<旧>-ccr/` 目录连同 `switches.ini` 里对应的 section 一起改名、把 `~/<旧>/` 目录和 `~/<旧>/.envrc` 一起 `mv` 成新名、`mv /home/ubuntu/.claude-provider/<旧>.env <新>.env`（脚本里硬编码的路径也要跟着改）、重建 switchboard。注意上面第 4 个坑——移动目录会断旧 session 的 resume 历史。
- **删除**：从 `switches.ini` 摘掉对应 section、删 `switches/<组>-ccr/` 目录、删 `~/<组>/` 目录和 `.env`、重建 switchboard。''',
    ),
    (
        "跟 provider-switch 一样的标准姿势：挂在 `proxy` 网络，NPM 用容器名 `ccr:8080` 反代",
        "跟 switchboard 一样的标准姿势：挂在 `proxy` 网络，NPM 用容器名 `ccr:8080` 反代",
    ),
    (
        '''## provider-switch 的 NPM 反代（可复现）

provider-switch 走的是 repo 里所有 NPM 反代服务的标准姿势：挂在 `proxy` 网络，NPM 用容器名 `provider-switch:8091` 反代，access list=`self-only`，HTTPS 用 NPM 自己申请的 Let's Encrypt 证书。一次性创建（token 换取 + 建 proxy host 的完整模式见 `../npm/README.md`）：

```bash
cd ../npm && source .npm-automation.env
docker run --rm --network proxy curlimages/curl:latest sh -c "
TOKEN=\\$(curl -sS -X POST http://npm:81/api/tokens -H 'Content-Type: application/json' -d '{\\"identity\\":\\"\\$NPM_AUTOMATION_EMAIL\\",\\"secret\\":\\"\\$NPM_AUTOMATION_PASSWORD\\"}' | sed -n 's/.*\\"token\\":\\"\\([^\\"]*\\)\\".*/\\1/p')
# 1. 先建证书（HTTP-01 challenge，DNS 已有 *.jerome.cloudns.asia 通配）
curl -sS -X POST http://npm:81/api/nginx/certificates -H \\"Authorization: Bearer \\$TOKEN\\" -H 'Content-Type: application/json' -d '{\\"provider\\":\\"letsencrypt\\",\\"nice_name\\":\\"provider.jerome.cloudns.asia\\",\\"domain_names\\":[\\"provider.jerome.cloudns.asia\\"],\\"meta\\":{\\"letsencrypt_agree\\":true,\\"dns_challenge\\":false}}'
# 记下返回的 id（下面 certificate_id 用）
# 2. 再建 proxy host（certificate_id 换成上一步的 id，access_list_id=1 是 self-only）
curl -sS -X POST http://npm:81/api/nginx/proxy-hosts -H \\"Authorization: Bearer \\$TOKEN\\" -H 'Content-Type: application/json' -d '{\\"domain_names\\":[\\"provider.jerome.cloudns.asia\\"],\\"forward_scheme\\":\\"http\\",\\"forward_host\\":\\"provider-switch\\",\\"forward_port\\":8091,\\"certificate_id\\":<id>,\\"ssl_forced\\":true,\\"http2_support\\":true,\\"block_exploits\\":true,\\"allow_websocket_upgrade\\":true,\\"access_list_id\\":1,\\"caching_enabled\\":false,\\"locations\\":[],\\"meta\\":{\\"letsencrypt_agree\\":false,\\"dns_challenge\\":false}}'
"
```

> 为什么 `forward_host` 是容器名 `provider-switch` 而不是 IP：provider-switch 和 NPM 都在 `proxy` 网络上，docker 内嵌 DNS 解析容器名。只有 k3s NodePort 那类宿主机服务才需要填宿主机内网 IP `10.0.0.95`（见根 README 的「反代到 k3s NodePort」坑）。''',
        '''## switchboard 的 NPM 反代（可复现）

switchboard 走的是 repo 里所有 NPM 反代服务的标准姿势：挂在 `proxy` 网络，NPM 用容器名 `switchboard:8091` 反代，access list=`self-only`，HTTPS 用 NPM 自己申请的 Let's Encrypt 证书。一次性创建（token 换取 + 建 proxy host 的完整模式见 `../npm/README.md`）：

```bash
cd ../npm && source .npm-automation.env
docker run --rm --network proxy curlimages/curl:latest sh -c "
TOKEN=\\$(curl -sS -X POST http://npm:81/api/tokens -H 'Content-Type: application/json' -d '{\\"identity\\":\\"\\$NPM_AUTOMATION_EMAIL\\",\\"secret\\":\\"\\$NPM_AUTOMATION_PASSWORD\\"}' | sed -n 's/.*\\"token\\":\\"\\([^\\"]*\\)\\".*/\\1/p')
# 1. 先建证书（HTTP-01 challenge，DNS 已有 *.jerome.cloudns.asia 通配）
curl -sS -X POST http://npm:81/api/nginx/certificates -H \\"Authorization: Bearer \\$TOKEN\\" -H 'Content-Type: application/json' -d '{\\"provider\\":\\"letsencrypt\\",\\"nice_name\\":\\"switchboard.jerome.cloudns.asia\\",\\"domain_names\\":[\\"switchboard.jerome.cloudns.asia\\"],\\"meta\\":{\\"letsencrypt_agree\\":true,\\"dns_challenge\\":false}}'
# 记下返回的 id（下面 certificate_id 用）
# 2. 再建 proxy host（certificate_id 换成上一步的 id，access_list_id=1 是 self-only）
curl -sS -X POST http://npm:81/api/nginx/proxy-hosts -H \\"Authorization: Bearer \\$TOKEN\\" -H 'Content-Type: application/json' -d '{\\"domain_names\\":[\\"switchboard.jerome.cloudns.asia\\"],\\"forward_scheme\\":\\"http\\",\\"forward_host\\":\\"switchboard\\",\\"forward_port\\":8091,\\"certificate_id\\":<id>,\\"ssl_forced\\":true,\\"http2_support\\":true,\\"block_exploits\\":true,\\"allow_websocket_upgrade\\":true,\\"access_list_id\\":1,\\"caching_enabled\\":false,\\"locations\\":[],\\"meta\\":{\\"letsencrypt_agree\\":false,\\"dns_challenge\\":false}}'
"
```

> 为什么 `forward_host` 是容器名 `switchboard` 而不是 IP：switchboard 和 NPM 都在 `proxy` 网络上，docker 内嵌 DNS 解析容器名。只有 k3s NodePort 那类宿主机服务才需要填宿主机内网 IP `10.0.0.95`（见根 README 的「反代到 k3s NodePort」坑）。
>
> 旧的 `provider.jerome.cloudns.asia` proxy host 和证书在完成 Manual Follow-up 的 NPM 切换后需要在 NPM 里手动删除/停用（仓库里没有对应的删除 API 调用记录）。''',
    ),
]

for old, new in replacements:
    count = src.count(old)
    assert count == 1, f"expected exactly 1 occurrence, found {count}:\\n{old[:80]}..."
    src = src.replace(old, new)

open(path, "w").write(src)
EOF
```

- [ ] **Step 3: Verify no stray references remain**

```bash
grep -n "provider-switch\|provider\.jerome" README.md vps_oracle/compose/ccr/README.md
```

Expected: no output (every reference above was either replaced or was already about the *domain being retired*, which Step 2's last replacement already accounted for).

- [ ] **Step 4: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add README.md vps_oracle/compose/ccr/README.md
git commit -m "Update root README and ccr/README.md for the provider-switch to switchboard rename"
```

---

## Task 14: Homepage card

**Files:**
- Modify: `vps_oracle/k3s/apps/homepage/k8s/config/services.yaml`

**Interfaces:** None — documentation/config only. Per root README's own instructions, only this k3s path is live; `vps_oracle/compose/homepage/config/services.yaml` is a stale pre-migration path and must NOT be touched.

- [ ] **Step 1: Replace the "Provider Switch" card**

Current (lines 17-20):

```yaml
    - Provider Switch:
        icon: si-anthropic
        href: https://provider.jerome.cloudns.asia
        description: Claude provider group toggle (Official ↔ CCR/Zhipu)
```

```bash
python3 - <<'EOF'
path = "vps_oracle/k3s/apps/homepage/k8s/config/services.yaml"
src = open(path).read()
old = """    - Provider Switch:
        icon: si-anthropic
        href: https://provider.jerome.cloudns.asia
        description: Claude provider group toggle (Official ↔ CCR/Zhipu)"""
new = """    - Switchboard:
        icon: si-anthropic
        href: https://switchboard.jerome.cloudns.asia
        description: Config-driven toggle framework (Claude provider switching, and more)"""
assert old in src
src = src.replace(old, new)
open(path, "w").write(src)
EOF
```

- [ ] **Step 2: Verify**

```bash
grep -n -A3 "Switchboard:" vps_oracle/k3s/apps/homepage/k8s/config/services.yaml
```

Expected: shows the new 4-line card.

- [ ] **Step 3: Commit (do NOT push — see Manual Follow-up)**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/k3s/apps/homepage/k8s/config/services.yaml
git commit -m "Rename homepage card from Provider Switch to Switchboard"
```

---

## Manual Follow-up (requires explicit human go-ahead — not part of automated task execution)

Everything above is safe to run unattended: it edits files and git-commits locally, and the one Docker action (`docker compose build` in Task 11) only builds an image without touching the live `provider-switch` container. The following three steps have real, harder-to-reverse effects on shared/live systems and must be confirmed with the user immediately before each one, one at a time:

1. **Deploy switchboard, retiring provider-switch:**
   ```bash
   cd vps_oracle/compose/switchboard
   docker compose up -d --build
   docker compose -p provider-switch down   # or however the old stack is identified; confirm container name first with `docker ps`
   ```
   This is the moment jerome/bridget's real Claude Code sessions start being served by the new container instead of the old one. Verify immediately after with the `curl` command in `ccr/README.md`'s "验证" section (now pointed at `switchboard.jerome.cloudns.asia` — which won't resolve until step 2 below, so verify via `docker exec switchboard` / `curl` against the container's internal port first, then again externally after step 2).

2. **NPM cutover:** run the "switchboard 的 NPM 反代" `curl` sequence from the updated `ccr/README.md` to create the new `switchboard.jerome.cloudns.asia` proxy host + certificate, then manually delete/disable the old `provider.jerome.cloudns.asia` proxy host and certificate in the NPM admin UI (no scripted delete exists for this yet). Recheck Force SSL / HTTP/2 after saving — the known "silently resets" gotcha from the root README applies here too.

3. **Push for the homepage card:** `git push` to `main` on the GitHub remote so ArgoCD's `homepage` Application picks up the card rename (`syncPolicy.automated` will apply it within one polling cycle, or trigger `argocd app sync homepage` manually).
