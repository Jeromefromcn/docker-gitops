#!/usr/bin/env python3
"""Every lab Deployment that Prometheus scrapes must load lab-metrics-defaults.

That ConfigMap carries the latency-histogram bucket env vars (see
k3s/apps/lab-environment/k8s/metrics-defaults.yaml). A scraped service that does
not load it exposes no _bucket series, so its p90/p95/p99 columns on the Lab
Business dashboards stay blank with no error anywhere. Lane templates are checked
too: tests/test-lanes.sh requires them to mirror the baseline container.

Run from the repo root, or point --root at a tree with the same layout.
"""
import argparse
import glob
import os
import sys

import yaml

CONFIGMAP = "lab-metrics-defaults"
LAB = "k3s/apps/lab-environment"


def documents(path):
    with open(path) as f:
        return [d for d in yaml.safe_load_all(f) if isinstance(d, dict)]


def loads_configmap(template):
    containers = (template.get("spec") or {}).get("containers") or []
    return any((ref.get("configMapRef") or {}).get("name") == CONFIGMAP
               for c in containers for ref in c.get("envFrom") or [])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    root = ap.parse_args().root
    paths = sorted(glob.glob(os.path.join(root, LAB, "k8s", "*.yaml"))
                   + glob.glob(os.path.join(root, LAB, "lanes", "*", "deployment.yaml")))
    errors, defined = [], False
    for path in paths:
        rel = os.path.relpath(path, root)
        for doc in documents(path):
            if doc.get("kind") == "ConfigMap" and (doc.get("metadata") or {}).get("name") == CONFIGMAP:
                defined = True
            if doc.get("kind") != "Deployment":
                continue
            template = (doc.get("spec") or {}).get("template") or {}
            annotations = (template.get("metadata") or {}).get("annotations") or {}
            if str(annotations.get("prometheus.io/scrape")).lower() != "true":
                continue
            if not loads_configmap(template):
                name = (doc.get("metadata") or {}).get("name")
                errors.append(f"::error file={rel}::Deployment {name} is scraped by Prometheus but does not "
                              f"load the {CONFIGMAP} ConfigMap via envFrom, so it exposes no latency histogram")
    if not defined:
        errors.append(f"::error::ConfigMap {CONFIGMAP} is not defined under {LAB}/k8s/")
    for e in errors:
        print(e)
    if not errors:
        print(f"lab-metrics-defaults: {len(paths)} files checked, OK")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
