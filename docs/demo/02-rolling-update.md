# 02 — Zero-downtime rolling update

## Purpose
Roll all five customers-service pods through git while live traffic flows,
with zero failed requests.

## Preconditions
Preflight passed. Working tree clean (`git status`).

## Commands
```bash
git pull --ff-only
demo-window start rolling-update
F=k3s/apps/lab-environment/k8s/customers-service.yaml
cur=$(grep -oP 'lab.jerome/rollout-rev: "\K[0-9]+' $F)
sed -i "s|lab.jerome/rollout-rev: \"$cur\"|lab.jerome/rollout-rev: \"$((cur + 1))\"|" $F
git diff
git commit -m "demo: rolling-restart customers-service" -- $F
git push
argocd app get lab-environment --core --refresh >/dev/null
# Wait until ArgoCD has synced this commit (the PreSync hook runs first) —
# otherwise rollout status reports the *old* rollout as done.
until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do sleep 5; done
kubectl -n lab-environment rollout status deploy/customers-service --timeout=6m
demo-window stop rolling-update
demo-evidence rolling-update
```

## Expected result
The sync, PreSync hook included, lands ~45 s after the push. `rollout
status` then walks 5 → 5 one pod at a time (maxSurge 1, maxUnavailable 0)
in ~2 minutes. Evidence: demo commit deployed, five new Ready pods, zero
non-2xx at the mesh, zero generator errors.

## Evidence
- **ArgoCD:** the demo commit in the app's history inside the window.
- **Kubernetes:** five customers pods created in the window, all Ready.
- **Envoy:** non-2xx count at ingress + waypoint = 0.
- **App:** traffic-generator lines in Loki — all 200.

## Talking points
- `maxSurge: 1 / maxUnavailable: 0` + readiness on the actuator readiness
  group + PDB `minAvailable: 3`: capacity never drops below five.
- The annotation bump is how you restart without a new image; ArgoCD would
  revert a `kubectl rollout restart` as drift.
- Measured history: the first rolling update under Consul discovery threw
  `000`/`405` for ~25 s because every replica shared one Consul instance ID;
  the 405 was the gateway forwarding GET to a POST-only `/fallback`.
- A release touching four Deployments at once deadlocked the namespace
  quota on 2026-09-25 (surge pods + the PreSync hook); the quota is now
  derived from the release peak.

## Reset
Leave the commit — scenario 07 reverts it. `demo-reset rolling-update`
waits for the rollout and verifies the baseline.
