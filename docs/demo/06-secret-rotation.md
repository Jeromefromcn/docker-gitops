# 06 — Secret rotation

## Purpose
Rotate the database password end to end — sealed in git, unsealed in the
cluster, switched in Postgres, rolled into the apps — without the password
ever touching git, a process list or the API audit trail in plaintext.

## Preconditions
Preflight passed; `kubeseal` on the PATH; working tree clean.

## Commands
```bash
git pull --ff-only
demo-window start secret-rotation
# 1. Seal a new password and ship it through git. The Secret changes; nothing restarts.
# The password reaches kubectl through a /dev/fd path, never as an argument (ps would show it).
NEW=$(openssl rand -base64 24 | tr -d '/+=')
U=$(kubectl -n lab-environment get secret lab-db-credentials -o jsonpath='{.data.username}' | base64 -d)
kubectl -n lab-environment create secret generic lab-db-credentials \
  --from-literal=username="$U" --from-file=password=<(printf %s "$NEW") --dry-run=client -o yaml \
  | kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets --format yaml \
  > k3s/sealed-secrets/secrets/lab-db-credentials.sealed.yaml
git diff --stat
git commit -m "demo: rotate lab-db-credentials" -- k3s/sealed-secrets/secrets/lab-db-credentials.sealed.yaml
git push || echo "PUSH FAILED - stop here"
argocd app get sealed-secrets --core --refresh >/dev/null
end=$((SECONDS + 120)); until [ "$(kubectl -n lab-environment get secret lab-db-credentials -o jsonpath='{.data.password}' | base64 -d)" = "$NEW" ]; do [ $SECONDS -lt $end ] || { echo "SECRET WAIT TIMED OUT - stop here"; break; }; sleep 5; done; [ $SECONDS -ge $end ] || echo "Secret updated"
# 2. Switch Postgres to the new password (via stdin, never on a command line).
printf 'ALTER USER "%s" PASSWORD '"'"'%s'"'"';\n' "$U" "$NEW" | kubectl -n lab-environment exec -i deploy/postgres -- psql -U "$U" -d postgres
# 3. Roll the three DB clients onto the new env.
for d in customers-service vets-service visits-service; do
  F=k3s/apps/lab-environment/k8s/$d.yaml
  cur=$(grep -oP 'lab.jerome/rollout-rev: "\K[0-9]+' $F)
  sed -i "s|lab.jerome/rollout-rev: \"$cur\"|lab.jerome/rollout-rev: \"$((cur + 1))\"|" $F
done
git commit -m "demo: roll services onto the rotated DB password" -- k3s/apps/lab-environment/k8s/{customers,vets,visits}-service.yaml
git push || echo "PUSH FAILED - stop here"
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
for d in customers-service vets-service visits-service; do kubectl -n lab-environment rollout status deploy/$d --timeout=8m; done
unset NEW
demo-window stop secret-rotation
demo-evidence secret-rotation
```

## Expected result
`Secret updated` ~10 s after the push, `ALTER ROLE`, three completed
rollouts (~3 minutes). Evidence: old password rejected, new accepted, all
three clients restarted. Measured 2026-09-27, never from authentication:

| Run | Non-200 / requests | Cause (Envoy flags) |
|---|---|---|
| before the preStop drain | 4 / 360 | `503 UC` from terminating customers pods; `504 UT` from cold vets/visits pods |
| after the preStop drain | 2 / 350 | `504 UT` (cold vets pod); `503 UC`+`UF,URX` from the waypoint to a *new*, Ready customers pod |

The drain fixed the terminating-pod case (scenario 02 went from 2/304 to
0/293). The remaining `UF` to freshly started pods is a second, open
failure mode — it outlasted the rollout by ~30 s and is tracked under
sub-project 2c (mesh resilience); it is not hidden by loosening the note.

## Evidence
- **ArgoCD:** a sealed-secrets app deployment inside the window.
- **sealed-secrets:** the SealedSecret's `Synced` condition updated in the window.
- **Postgres (scram path):** old password rejected, new accepted.
- **Kubernetes:** every customers/vets/visits pod restarted in the window.
- Note: generator errors in the window — the measured cost of the rotation.

## Talking points
- Order is forced by the platform, not chosen: the `db-init` PreSync hook
  authenticates with the Secret on **every** sync, so the Secret and the
  database must both be on the new password before `lab-environment` syncs.
- Between step 2 and the end of step 3, old pods keep working on pooled
  connections (Hikari max 5); only a *new* connection with the old password
  would fail — and in rehearsal none did. The errors the note line counts
  came from the rollouts themselves (see Expected result): the honest cost
  of this rotation is restarting three services at once, not the password
  switch.
- Verification pitfall: inside the postgres pod the local socket is `trust`
  and `-h postgres` is now reset by ztunnel — only the pod's own IP reaches
  the scram line. A check that "passes" on the wrong path proves nothing.
- The old plaintext password was rotated out of Consul KV in sub-project 1;
  no KV key contains a password.

## If interrupted
- After step 1 only: the next `lab-environment` sync's `db-init` fails
  authentication and the sync stalls. Finish step 2 (ALTER USER to the value
  now in the Secret: `kubectl -n lab-environment get secret lab-db-credentials
  -o jsonpath='{.data.password}' | base64 -d`), then step 3.
- After step 2: old pods keep running on pooled connections; finish step 3.
- At any point: the old password stays on disk (mode 600) at
  `~/.local/state/lab-demo/secret-rotation.old`, saved by `demo-window
  start` for the evidence's scram check, until `demo-reset secret-rotation`
  deletes it. Run the reset even when abandoning the rotation.

## Reset
`demo-reset secret-rotation` — deletes the saved old password, checks the
sealed-secrets app, waits for the three rollouts, verifies the baseline.
The rotation itself is not undone: the new password is simply current.
