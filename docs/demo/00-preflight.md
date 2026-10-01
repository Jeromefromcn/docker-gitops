# 00 — Preflight

## Purpose
Start from a known-good lab so every later failure belongs to a scenario.

## Preconditions
On vps_oracle, repo root (`~/jerome/docker-gitops`), kubectl context `default`.

## Commands
```bash
git pull --ff-only origin main
export PATH=$PWD/k3s/apps/lab-environment/demo:$PATH
demo-reset preflight
kubectl -n lab-environment get pods | grep -v -E 'Running|Completed'
argocd app list --core | grep -E 'lab-environment|sealed-secrets|kube-state-metrics'
```

## Expected result
`baseline OK`; only the header line from the pod filter; the three apps
`Synced  Healthy`.

## Evidence
None — this is the baseline every scenario is measured against. Open
Grafana (Lab Mesh Overview), Jaeger and the Grafana Alerting page in
browser tabs now.

## Talking points
- The lab is production-shaped on purpose: 5 customers / 3 gateway
  replicas, Istio ambient with a waypoint, STRICT mTLS, least-privilege
  authorization, resident timeouts/retries/outlier detection.
- Baseline is checked, not assumed: chaos toggles, replica counts vs git,
  ArgoCD sync, and 30 s of generator traffic.

## Reset
Nothing to reset.
