# 00 — Preflight

## Purpose
Start from a known-good lab so every later failure belongs to a scenario.

## Preconditions
On vps_oracle, repo root (`~/jerome/docker-gitops`), kubectl context `default`.

## Commands
```bash
# Bring the checkout up to date with origin/main
git pull --ff-only origin main

# Verify the lab baseline; expect "baseline OK"
k3s/apps/lab-environment/demo/demo-baseline

# List lab pods that are not Running or Completed; expect only the header line
kubectl -n lab-environment get pods | grep -v -E 'Running|Completed'

# Check the three apps are Synced and Healthy
argocd app list --core | grep -E 'lab-environment|sealed-secrets|kube-state-metrics'
```

## Expected result
`baseline OK`; only the header line from the pod filter; the three apps
`Synced  Healthy`.

## Open the views
Every scenario is shown in these tools, so log in to each now:
- ArgoCD: <https://argocd.jerome.cloudns.asia>
- Grafana: <https://grafana.lab.jerome.cloudns.asia> (Lab Mesh Overview,
  Lab Business, Explore)
- Jaeger: <https://jaeger.lab.jerome.cloudns.asia>

Each page lists the exact views it needs under "Before you start".

## Talking points
- The lab is production-shaped on purpose: 5 customers / 3 gateway
  replicas, Istio ambient with a waypoint, STRICT mTLS, least-privilege
  authorization, resident timeouts/retries/outlier detection.
- Baseline is checked, not assumed: chaos toggles, replica counts vs git,
  ArgoCD sync, the routing pin, leftover lanes or toxiproxy wiring, the
  rate limiter, and 30 s of generator traffic.

## Reset
Nothing to reset. Run `demo-baseline` again between scenarios whenever a
page's reset is in doubt.
