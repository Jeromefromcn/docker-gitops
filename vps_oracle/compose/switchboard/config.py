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
