# 07 — GitOps self-heal and rollback

## Purpose
Show that git is the only way to change the lab: a manual change is undone
within seconds, and rollback is a `git revert`, not a `kubectl` command.

## Preconditions
Scenario 02's `demo:` commit is on `main` and deployed.

## Commands
```bash
# Bring the checkout up to date with origin/main
git pull --ff-only origin main

# Open the evidence window: every evidence query is bounded by it
demo-window start gitops-selfheal-rollback

# 1. Drift: someone scales by hand
kubectl -n lab-environment scale deploy/customers-service --replicas=1

# Watch READY drop and climb back to 5/5 (no Ctrl-C: it would drop the rest of this block)
# Give up after 5 min; low/last track the READY dip and the last value printed
end=$((SECONDS + 300)); low=; last=

# Poll READY every 2 s, print each change, stop once it is back at 5/5 after the dip
while :; do
  r=$(kubectl -n lab-environment get deploy customers-service -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')
  [ "$r" = "$last" ] || { echo "READY $r"; last=$r; }
  if [ "$r" = 5/5 ]; then [ -z "$low" ] || break; else low=1; fi
  [ $SECONDS -lt $end ] || { echo "READY WAIT TIMED OUT - stop here"; break; }
  sleep 2
done

# 2. Rollback: revert 02's commit through git
# Find 02's demo commit
SHA=$(git log -1 --grep='^demo: rolling-restart customers-service$' --format=%H)

# Show what that commit changed
git show --stat $SHA

# Revert it - the rollback is a new commit, deployed like any other
git revert --no-edit $SHA

# Push to main; ArgoCD deploys from git
git push || echo "PUSH FAILED - stop here"

# Make ArgoCD re-read git now instead of waiting for its next poll
argocd app get lab-environment --core --refresh >/dev/null

# Wait (up to 5 min) until ArgoCD has synced this commit successfully
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done

# Wait until the customers-service rollout completes
kubectl -n lab-environment rollout status deploy/customers-service --timeout=6m

# Close the evidence window
demo-window stop gitops-selfheal-rollback

# Run the evidence queries for the window; ends with a Grafana link
demo-evidence gitops-selfheal-rollback
```

## Expected result
ArgoCD sets `replicas` back to 5 within a second of the scale; READY climbs
from 1/5 to 5/5 over ~70 s (JVM startup), with no generator errors — one
pod carries the traffic meanwhile. The revert then rolls the pods again and
restores the previous `rollout-rev`.

## Evidence
- **Kubernetes (kube-state-metrics):** available replicas dipped to 1 in the window.
- **ArgoCD (controller log):** a sync limited to `Deployment/customers-service`
  at the already-deployed revision — that is selfHeal; the app history does
  not record it.
- **ArgoCD:** the revert commit in the app history inside the window.
- **Kubernetes:** live `rollout-rev` and ready count equal git's.

## Talking points
- `selfHeal: true` makes git the source of truth for *runtime* state, not
  just for deploys; drift is a bug, not an emergency lever.
- Rollback = `git revert`: audited, reviewable, and the same pipeline as a
  deploy. There is no out-of-band "undo" path to forget about.
- The manual scale-down briefly violated the PDB's intent (`scale` does not
  consult PDBs — only evictions do); selfHeal is what bounded the damage.

## Reset
`demo-reset gitops-selfheal-rollback` — waits for the rollout, verifies the baseline.
