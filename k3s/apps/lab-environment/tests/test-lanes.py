#!/usr/bin/env python3
"""Lab PR lanes: render each lanes/<service>/ with the ApplicationSet's own
patches and image override for a sample PR, then check it against the
baseline Deployment in k8s/<service>.yaml."""
import copy, os, shutil, subprocess, sys, tempfile
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.path.normpath(os.path.join(HERE, ".."))
REPO = os.path.normpath(os.path.join(LAB, "../../.."))
APPSET = os.path.join(REPO, "k3s/argocd/apps/lab-lanes-appset.yaml")
PR, SHA = "42", "0123456789abcdef0123456789abcdef01234567"
fails = []

def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok:
        fails.append(msg)

def fill(text, service):
    return (text.replace("{{.service}}", service).replace("{{.number}}", PR)
                .replace("{{.head_sha}}", SHA))

def render(service, template):
    src = template["spec"]["source"]
    tmp = tempfile.mkdtemp()
    try:
        base = os.path.join(tmp, "base")
        shutil.copytree(os.path.join(LAB, "lanes", service), base)
        kust = {"apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization",
                "resources": ["base"],
                "images": [], "patches": []}
        for img in src["kustomize"]["images"]:
            ref = fill(img, service)
            name, tag = ref.rsplit(":", 1)
            kust["images"].append({"name": name, "newTag": tag})
        for p in src["kustomize"]["patches"]:
            kust["patches"].append({"target": {k: fill(v, service) for k, v in p["target"].items()},
                                    "patch": fill(p["patch"], service)})
        with open(os.path.join(tmp, "kustomization.yaml"), "w") as f:
            yaml.safe_dump(kust, f)
        out = subprocess.run(["kubectl", "kustomize", tmp], check=True, capture_output=True, text=True).stdout
        return {(d["kind"], d["metadata"]["name"]): d for d in yaml.safe_load_all(out) if d}
    finally:
        shutil.rmtree(tmp)

def baseline(service):
    with open(os.path.join(LAB, "k8s", f"{service}.yaml")) as f:
        docs = [d for d in yaml.safe_load_all(f) if d]
    return next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == service)

with open(APPSET) as f:
    appset = yaml.safe_load(f)
gens = appset["spec"]["generators"][0]["matrix"]["generators"]
services = [e["service"] for e in gens[0]["list"]["elements"]]
check(sorted(services) == ["api-gateway", "customers-service", "vets-service", "visits-service"],
      f"appset lists the four services ({services})")
check(gens[1]["pullRequest"]["github"]["repo"] == "spring-petclinic-microservices",
      "PR generator reads the fork")
check(gens[1]["pullRequest"]["github"]["labels"] == ["lane:{{.service}}"], "PR generator filters on lane:<service>")
template = appset["spec"]["template"]
check(template["spec"]["destination"]["namespace"] == "lab-environment", "lanes deploy into lab-environment")

for s in services:
    name, lane = f"{s}-pr-{PR}", f"pr-{PR}"
    docs = render(s, template)
    dep, svc, rt = docs.get(("Deployment", name)), docs.get(("Service", name)), docs.get(("HTTPRoute", name))
    check(dep is not None and svc is not None and rt is not None, f"{s}: renders Deployment, Service, HTTPRoute named {name}")
    if not (dep and svc and rt):
        continue
    labels = dep["spec"]["template"]["metadata"]["labels"]
    check(labels.get("app") == f"{s}-lane", f"{s}: pod app label is {s}-lane, never {s}")
    check(labels.get("lab.jerome/lane") == lane, f"{s}: pod carries lab.jerome/lane={lane}")
    check(labels.get("lab.jerome/lane-pod") == "true", f"{s}: pod carries lab.jerome/lane-pod=true (lane-direct selects it)")
    check(dep["spec"]["selector"]["matchLabels"] == {"app": f"{s}-lane", "lab.jerome/lane": lane},
          f"{s}: Deployment selector is per-lane")
    check(svc["spec"]["selector"] == {"app": f"{s}-lane", "lab.jerome/lane": lane}, f"{s}: Service selects only this lane")
    check(dep["spec"]["replicas"] == 1, f"{s}: one replica")
    c = dep["spec"]["template"]["spec"]["containers"][0]
    check(c["image"] == f"ghcr.io/jeromefromcn/petclinic-{s}:{SHA}", f"{s}: image is the PR head SHA ({c['image']})")
    b = baseline(s)
    bc = b["spec"]["template"]["spec"]["containers"][0]
    check(dep["spec"]["template"]["spec"]["serviceAccountName"] == b["spec"]["template"]["spec"]["serviceAccountName"],
          f"{s}: same ServiceAccount as the baseline")
    for field in ("env", "ports", "resources", "startupProbe", "readinessProbe", "lifecycle"):
        check(c.get(field) == bc.get(field), f"{s}: container {field} equals the baseline's")
    rule = rt["spec"]["rules"][0]
    check(rt["spec"]["parentRefs"] == [{"group": "", "kind": "Service", "name": s}], f"{s}: HTTPRoute parented on the baseline Service")
    check(rule["matches"] == [{"headers": [{"name": "x-pr-lane", "value": PR}]}], f"{s}: matches only x-pr-lane: {PR}")
    check([r["name"] for r in rule["backendRefs"]] == [name], f"{s}: routes to {name}")
    check(rule.get("timeouts", {}).get("request") == "3s", f"{s}: 3s request timeout like the VirtualService")

print("ALL PASS" if not fails else f"{len(fails)} FAILED")
sys.exit(1 if fails else 0)
