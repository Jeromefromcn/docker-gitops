# 07 — GitOps self-heal and rollback

## Purpose
Show that git is the only way to change the lab: a manual change is undone
within seconds, and rollback is a `git revert`, not a `kubectl` command.

## Preconditions
Scenario 02's `demo:` commit is on `main` and deployed.

## Commands
```bash
git pull --ff-only
demo-window start gitops-selfheal-rollback
# 1. Drift: someone scales by hand
kubectl -n lab-environment scale deploy/customers-service --replicas=1
kubectl -n lab-environment get deploy customers-service -w    # Ctrl-C when READY is 5/5 again
# 2. Rollback: revert 02's commit through git
SHA=$(git log -1 --grep='^demo: rolling-restart customers-service$' --format=%H)
git show --stat $SHA
git revert --no-edit $SHA
git push
argocd app get lab-environment --core --refresh >/dev/null
kubectl -n lab-environment rollout status deploy/customers-service --timeout=6m
demo-window stop gitops-selfheal-rollback
demo-evidence gitops-selfheal-rollback
```

## Expected result
The Deployment drops to 1 and ArgoCD scales it back to 5 within seconds.
The revert rolls the pods again and restores the previous `rollout-rev`.

## Evidence
- **Kubernetes:** `ScalingReplicaSet` events — down to 1, then up to 5.
- **ArgoCD:** the revert commit in the app history inside the window.
- **Kubernetes:** live `rollout-rev` equals git's.

## Talking points
- `selfHeal: true` makes git the source of truth for *runtime* state, not
  just for deploys; drift is a bug, not an emergency lever.
- Rollback = `git revert`: audited, reviewable, and the same pipeline as a
  deploy. There is no out-of-band "undo" path to forget about.
- The manual scale-down briefly violated the PDB's intent (`scale` does not
  consult PDBs — only evictions do); selfHeal is what bounded the damage.

## Reset
`demo-reset gitops-selfheal-rollback` — waits for the rollout, verifies the baseline.
