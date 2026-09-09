#!/usr/bin/env python3
"""Enforce the compose conventions in .claude/rules/compose-conventions.md.

Runs at the YAML level on purpose: `docker compose config` would need the
gitignored .env files of every stack, so it cannot run in CI. This checks
what is actually committed.

Usage: python3 .github/scripts/check-compose-conventions.py [repo_root]
Exit 0 = clean, 1 = violations found.
"""
import glob
import os
import re
import sys

import yaml

# Services allowed to publish a host port, with the reason from README.md.
# Adding an entry here is a deliberate act — the default is "no published port".
PORT_EXCEPTIONS = {
    ("3x-ui", "3x-ui"): "VLESS+Reality raw TCP, client connects directly, not via NPM",
    ("npm", "app"): "the reverse proxy itself terminates 80/443",
    ("ccr", "ccr"): "consumer is the host-native claude CLI; bound to 127.0.0.1 only",
    ("apprise", "apprise"): "bound to 127.0.0.1 only",
}

# Environment values that look like credentials but aren't. Each entry needs
# a reason; the default is "a secret-shaped key must not hold a literal".
SECRET_EXCEPTIONS = {
    ("llm", "open-webui", "OPENAI_API_KEYS"):
        "placeholder — open-webui requires the var, the local llama-cpp backend ignores it",
}

# Real violations that are known and accepted for now. These print as warnings
# instead of failing the build, so the debt stays visible and greppable rather
# than being silently allowlisted. Empty this dict, don't grow it.
KNOWN_VIOLATIONS = {
    ("dify", "plugin_daemon", "DIFY_INNER_API_KEY"):
        "live credential committed in plain text; rotating it means restarting the "
        "whole dify stack — move to .env when dify is next touched",
    ("dify", "api", "INNER_API_KEY_FOR_PLUGIN"): "same credential as dify/plugin_daemon",
    ("dify", "worker", "INNER_API_KEY_FOR_PLUGIN"): "same credential as dify/plugin_daemon",
}

SECRETY = re.compile(r"(password|passwd|secret|token|api_?key|access_?key)", re.I)
# A ${VAR} reference, an empty value, a boolean flag, or a plain number: not a secret.
SAFE_VALUE = re.compile(
    r"^\s*(\$\{[^}]+\}|\$[A-Za-z_]\w*|true|false|yes|no|on|off|\d+|)\s*$", re.I
)


def env_items(env):
    if isinstance(env, dict):
        return list(env.items())
    if isinstance(env, list):
        out = []
        for item in env:
            k, _, v = str(item).partition("=")
            out.append((k, v))
        return out
    return []


def check_service(stack, name, svc, problems, warnings):
    def bad(msg):
        problems.append(f"{stack}/{name}: {msg}")

    logging = svc.get("logging")
    if not isinstance(logging, dict):
        bad("no `logging` block — logs can fill the disk")
    else:
        opts = logging.get("options") or {}
        if logging.get("driver") != "json-file":
            bad(f"logging.driver is {logging.get('driver')!r}, expected 'json-file'")
        if not opts.get("max-size"):
            bad("logging.options.max-size not set")
        if not opts.get("max-file"):
            bad("logging.options.max-file not set")

    if svc.get("restart") != "unless-stopped":
        bad(f"restart is {svc.get('restart')!r}, expected 'unless-stopped'")

    image = svc.get("image")
    if image:
        ref = image.split("/")[-1]
        if "@sha256:" in image:
            pass
        elif ":" not in ref:
            bad(f"image {image!r} has no tag — pin a tag or digest")
        elif ref.rsplit(":", 1)[1] in ("latest", "master", "main", "stable"):
            bad(f"image {image!r} uses a moving tag — pin a tag or digest")
    elif "build" not in svc:
        bad("neither `image` nor `build` set")

    items = env_items(svc.get("environment"))
    if not any(k == "TZ" for k, _ in items):
        bad("no TZ set — logs will silently fall back to UTC")

    for key, value in items:
        if not SECRETY.search(key) or SAFE_VALUE.match(str(value)):
            continue
        if (stack, name, key) in SECRET_EXCEPTIONS:
            continue
        known = KNOWN_VIOLATIONS.get((stack, name, key))
        if known:
            warnings.append(f"{stack}/{name}: inline secret in {key} — accepted for now: {known}")
        else:
            bad(f"environment {key} looks like an inline secret — use .env / env_file")

    if svc.get("ports"):
        reason = PORT_EXCEPTIONS.get((stack, name))
        if not reason:
            bad(
                f"publishes host ports {svc['ports']} — services should go through NPM "
                f"on the `proxy` network. If this is a real exception, add it to "
                f"PORT_EXCEPTIONS in this script with a reason."
            )

    for net in (svc.get("networks") or {}).values() if isinstance(svc.get("networks"), dict) else []:
        ip = (net or {}).get("ipv4_address")
        if ip and ip.startswith("172.19.1."):
            bad(f"static IP {ip} is inside the dynamic pool 172.19.1.0/24 — use 172.19.0.x")


def main(root="."):
    problems, warnings, stacks = [], [], 0
    for path in sorted(glob.glob(os.path.join(root, "*/compose/*/docker-compose.yml"))):
        stack = os.path.basename(os.path.dirname(path))
        stacks += 1
        try:
            doc = yaml.safe_load(open(path, encoding="utf-8"))
        except yaml.YAMLError as exc:
            problems.append(f"{stack}: YAML parse error: {str(exc).splitlines()[0]}")
            continue
        for name, svc in ((doc or {}).get("services") or {}).items():
            if isinstance(svc, dict):
                check_service(stack, name, svc, problems, warnings)

    ci = os.environ.get("GITHUB_ACTIONS")
    for w in warnings:
        print(f"::warning::{w}" if ci else f"WARN  {w}")
    for p in problems:
        print(f"::error::{p}" if ci else f"FAIL  {p}")
    print(
        f"\nchecked {stacks} stack(s): {len(problems)} violation(s), "
        f"{len(warnings)} accepted violation(s)"
    )
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
