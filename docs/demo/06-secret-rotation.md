# 06 — Secret rotation

## Purpose
Rotate the database password end to end: sealed in git, unsealed in the
cluster, switched in Postgres, rolled into the apps. The password never
touches git, a process list or the API audit trail in plaintext. Each
stage is visible in the component that performs it.

## Preconditions
Preflight passed; `kubeseal` on the PATH; working tree clean. Run every
step in **one shell**: `OLD` and `NEW` live only in its variables.

## Before you start: open the views
1. **ArgoCD — the `sealed-secrets` app**:
   <https://argocd.jerome.cloudns.asia/applications/argocd/sealed-secrets>
2. **ArgoCD — the `lab-environment` app**, tree view, name filter
   `-service`:
   <https://argocd.jerome.cloudns.asia/applications/argocd/lab-environment>
3. **Grafana — Explore**, data source **Loki**, last 30 minutes. Postgres'
   own log of refused logins:
   ```logql
   {service="postgres"} |= "password authentication failed"
   ```

## Steps

### 1. Seal a new password and ship it through git
```bash
# Bring the checkout up to date with origin/main
git pull --ff-only origin main

# Keep the current password in this shell: step 4 proves it stops working
OLD=$(kubectl -n lab-environment get secret lab-db-credentials -o jsonpath='{.data.password}' | base64 -d)

# Generate the new password; it lives only in this shell
NEW=$(openssl rand -base64 24 | tr -d '/+=')

# Read the current DB username from the live Secret
U=$(kubectl -n lab-environment get secret lab-db-credentials -o jsonpath='{.data.username}' | base64 -d)

# Build the new Secret locally and seal it with the controller's public key.
# The password reaches kubectl through a /dev/fd path, never as an argument
# (ps would show it). Only the sealed file is written.
kubectl -n lab-environment create secret generic lab-db-credentials \
  --from-literal=username="$U" --from-file=password=<(printf %s "$NEW") --dry-run=client -o yaml \
  | kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets --format yaml \
  > k3s/sealed-secrets/secrets/lab-db-credentials.sealed.yaml

# Only the sealed file changed: ciphertext, no plaintext in git
git diff --stat

# Commit to main with the demo: prefix
git commit -m "demo: rotate lab-db-credentials" -- k3s/sealed-secrets/secrets/lab-db-credentials.sealed.yaml

# Push; ArgoCD deploys from git
git push
```
In ArgoCD's `sealed-secrets` app, click **Refresh**. It syncs the new
SealedSecret. The controller decrypts it into the Secret within seconds:
```bash
# The controller's event on the SealedSecret: expect "SealedSecret unsealed successfully"
kubectl -n lab-environment get events --field-selector involvedObject.name=lab-db-credentials --sort-by=.lastTimestamp | tail -2
```
Nothing has restarted. The apps still run on the old password, which
Postgres still accepts.

### 2. Switch Postgres to the new password
```bash
# Through stdin, never on a command line
printf 'ALTER USER "%s" PASSWORD '"'"'%s'"'"';\n' "$U" "$NEW" | kubectl -n lab-environment exec -i deploy/postgres -- psql -U "$U" -d postgres
```
`ALTER ROLE`. From now on, a connection with the old password is
refused. The running pods keep their pooled connections, which are
already authenticated.

### 3. Roll the three DB clients onto the new password
The pods read the password from the Secret at start, so they must restart.
In the editor, in each of `customers-service.yaml`, `vets-service.yaml`
and `visits-service.yaml` under `k3s/apps/lab-environment/k8s/`, add one
to `lab.jerome/rollout-rev` (as in 02).
```bash
# Review: three rollout-rev bumps
git diff

# Commit to main with the demo: prefix
git commit -m "demo: roll services onto the rotated DB password" -- k3s/apps/lab-environment/k8s/{customers,vets,visits}-service.yaml

# Push; ArgoCD deploys from git
git push
```
In ArgoCD's `lab-environment` app, click **Refresh**. The `db-init`
PreSync hook runs first and logs in with the Secret, which is now the new
password. Then the three services roll one pod at a time (~3 minutes).

Watch the Loki tab meanwhile. `password authentication failed` lines
appear in bursts until the last old pod is gone. These are old pods
opening new pool connections with the old password. The 2026-10-06
rehearsal logged ~100 of them, from ~2.5 minutes after step 2 until 7 s
after the rollout ended. Then they stop.

### 4. The old password is dead, the new one works
Postgres' local socket inside its own pod is `trust`, so the check has to
connect over the network to the pod's own IP, where scram applies:
```bash
# Try each password over scram; expect: old refused, new prints 1
for P in "$OLD" "$NEW"; do printf %s "$P" | kubectl -n lab-environment exec -i deploy/postgres -- sh -c 'read -r P; PGPASSWORD="$P" psql -h "$(hostname -i)" -U "$1" -d customers -tAc "select 1" 2>&1' _ "$U"; done

# Drop both passwords from the shell
unset OLD NEW
```
First: `FATAL: password authentication failed`. Second: `1`.

### 5. What users saw
Explore, Loki, last 15 minutes:
```logql
{service="traffic-generator"} !~ " 200 "
```
The rehearsals measured a few errors here, never caused by
authentication:

| Run | Non-200 / requests | Cause (Envoy flags) |
|---|---|---|
| 2026-09-27, before the preStop drain | 4 / 360 | `503 UC` from terminating customers pods; `504 UT` from cold vets/visits pods |
| 2026-09-27, after the preStop drain | 2 / 350 | `504 UT` (cold vets pod); `503 UC`+`UF,URX` from the waypoint to a *new*, Ready customers pod |
| 2026-10-06 | 2 / ~880 | `503 UC` from the waypoint to new customers pods |

The old pods' failed logins did not reach users: the old pods kept
serving on the connections they already had. The
cost of this rotation is restarting three services at once, the same
`503 UC` to freshly started pods seen in 12, not the password switch.

## Talking points
- Order is forced by the platform, not chosen: the `db-init` PreSync hook
  authenticates with the Secret on **every** sync, so the Secret and the
  database must both be on the new password before `lab-environment` syncs.
- Between step 2 and the end of step 3, old pods keep working on pooled
  connections (Hikari max 5), but every *new* connection they open is
  refused. That window is what step 3's failed-login lines show: shorten
  it by pushing step 3 straight after step 2.
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

## Reset
Nothing to undo: the new password is simply current.
