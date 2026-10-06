# 07 — GitOps self-heal and rollback

## Purpose
Show that git is the only way to change the lab: a manual change is undone
within seconds, and rollback is a `git revert`, not a `kubectl` command.
ArgoCD's own event log and history are the record of both.

## Preconditions
Scenario 02's `demo:` commit is on `main` and deployed.

## Before you start: open the views
1. **ArgoCD — the `lab-environment` app**, tree view, name filter
   `customers-service`:
   <https://argocd.jerome.cloudns.asia/applications/argocd/lab-environment>
2. **Grafana — Lab Mesh Overview**, last 15 minutes, auto-refresh 10 s:
   <https://grafana.lab.jerome.cloudns.asia/d/lab-mesh-overview/lab-mesh-overview?from=now-15m&to=now&refresh=10s>
3. **A second terminal pane**, watching the Deployment:
   ```bash
   # READY / UP-TO-DATE / AVAILABLE for customers-service; leave it running
   kubectl -n lab-environment get deploy customers-service -w
   ```

## Steps

### 1. Drift: someone scales by hand
```bash
# A manual change that bypasses git
kubectl -n lab-environment scale deploy/customers-service --replicas=1
```
Watch the second pane. Within ~2 s the Deployment is back to `5`
replicas. ArgoCD did that, not you. Four pods were already terminated,
though, so READY reads `1/5` and climbs back to `5/5` over ~65 s while
the new JVMs start.

In ArgoCD, open the app's **Events** (the app details panel, **Events**
tab). The newest entries, all within the same two seconds:
- `Updated sync status: Synced -> OutOfSync`. ArgoCD saw the live object
  differ from git.
- `Initiated automated sync to '<SHA>'`. selfHeal synced it back, at the
  commit already deployed.
- `Partial sync operation ... succeeded`. Only the drifted Deployment was
  re-applied, not the whole app.

In Grafana, **customers-service RPS per pod**: four lines stop at the same
moment and one carries all the traffic until the new pods' lines start.
**Mesh requests by service and code** stays at `200`: one pod carried the
load.

### 2. Rollback: revert 02's commit through git
```bash
# Bring the checkout up to date with origin/main
git pull --ff-only origin main

# Find 02's demo commit and show what it changed
git log --oneline --grep='^demo: rolling-restart customers-service$' -1
git show <SHA>

# Revert it: the rollback is a new commit, deployed like any other
git revert --no-edit <SHA>

# Push; ArgoCD deploys the rollback from git
git push
```
In ArgoCD, click **Refresh**. The app syncs the revert commit, and the tree
shows the same one-pod-at-a-time rollout as in 02, back to the previous
`rollout-rev`. The second pane shows UP-TO-DATE climbing to 5 again.

### 3. Both are on record
In ArgoCD, open **History and rollback**. The top two entries are the
`Revert "demo: rolling-restart customers-service"` commit and, under it,
02's commit. The selfHeal in step 1 is not in this list, because it
deployed no new revision. Its record is the Events tab.

ArgoCD's own **Rollback** button is not an option: it is refused while
automated sync is on, because git would win again on the next sync. In
git, the rollback is reviewable, audited and permanent.

## Talking points
- `selfHeal: true` makes git the source of truth for *runtime* state, not
  just for deploys; drift is a bug, not an emergency lever.
- Rollback = `git revert`: audited, reviewable, and the same pipeline as a
  deploy. There is no out-of-band "undo" path to forget about.
- The manual scale-down briefly violated the PDB's intent (`scale` does not
  consult PDBs — only evictions do); selfHeal is what bounded the damage.

## Reset
Nothing to reset once the revert is deployed. Stop the `-w` watch with
Ctrl-C.
