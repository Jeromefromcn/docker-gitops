#!/bin/bash
# check-lab-metrics-defaults.py against fixture trees: a scraped Deployment must
# load the lab-metrics-defaults ConfigMap, and that ConfigMap must exist.
# Needs python3 and PyYAML; no cluster access.
set -uo pipefail
CHECK="$(cd "$(dirname "$0")/../../../.." && pwd)/.github/scripts/check-lab-metrics-defaults.py"
fail=0
check() { # name expected-exit root
  local name=$1 want=$2 root=$3 got
  python3 "$CHECK" --root "$root" >/dev/null 2>&1; got=$?
  if [ "$got" -eq "$want" ]; then echo "PASS $name"; else echo "FAIL $name (exit $got, want $want)"; fail=1; fi
}
mk() { # root: creates the lab dirs with the shared ConfigMap
  mkdir -p "$1/k3s/apps/lab-environment/k8s" "$1/k3s/apps/lab-environment/lanes/svc"
  cat > "$1/k3s/apps/lab-environment/k8s/metrics-defaults.yaml" <<'Y'
apiVersion: v1
kind: ConfigMap
metadata: {name: lab-metrics-defaults}
data: {A: "1"}
Y
}
deploy() { # file scrape(true|false) envfrom(yes|no)
  { echo "apiVersion: apps/v1"; echo "kind: Deployment"; echo "metadata: {name: svc}"
    echo "spec:"; echo "  template:"; echo "    metadata:"; echo "      annotations:"
    echo "        prometheus.io/scrape: \"$2\""
    echo "    spec:"; echo "      containers:"; echo "        - name: c"
    if [ "$3" = yes ]; then echo "          envFrom:"; echo "            - configMapRef: {name: lab-metrics-defaults}"; fi
  } > "$1"
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mk "$T/ok"; deploy "$T/ok/k3s/apps/lab-environment/k8s/svc.yaml" true yes
check "scraped Deployment that loads the ConfigMap passes" 0 "$T/ok"

mk "$T/missing"; deploy "$T/missing/k3s/apps/lab-environment/k8s/svc.yaml" true no
check "scraped Deployment without envFrom fails" 1 "$T/missing"

mk "$T/notscraped"; deploy "$T/notscraped/k3s/apps/lab-environment/k8s/svc.yaml" false no
check "Deployment Prometheus does not scrape is ignored" 0 "$T/notscraped"

mk "$T/lane"; deploy "$T/lane/k3s/apps/lab-environment/lanes/svc/deployment.yaml" true no
check "a lane template without envFrom fails too" 1 "$T/lane"

mk "$T/nocm"; deploy "$T/nocm/k3s/apps/lab-environment/k8s/svc.yaml" true yes
rm "$T/nocm/k3s/apps/lab-environment/k8s/metrics-defaults.yaml"
check "a missing ConfigMap fails" 1 "$T/nocm"

check "the real repository passes" 0 "$(cd "$(dirname "$0")/../../../.." && pwd)"
exit $fail
