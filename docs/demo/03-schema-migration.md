# 03 — Schema migration as a PreSync hook

## Purpose
Show that the schema job runs *before* the new pods, on every sync, and is
idempotent. This uses 02's sync, so no schema change has to be invented.

## Preconditions
Scenario 02 just finished. Run this before scenario 07 pushes anything:
ArgoCD's last operation must still be 02's sync.

## Steps

### 1. The hook in ArgoCD
In ArgoCD (`lab-environment` app), click the **Last Sync** panel at the
top, the one showing 02's commit. The operation details list
every resource that sync touched. The first four are marked **PreSync**,
all `Succeeded`:
`Namespace/lab-environment`, `ServiceAccount/db-init`,
`ConfigMap/db-init-sql`, `Job/db-init`. Every other resource follows in the
**Sync** phase.

### 2. It ran first
```bash
# When the migration job started and finished
kubectl -n lab-environment get job db-init -o custom-columns=JOB:.metadata.name,STARTED:.status.startTime,COMPLETED:.status.completionTime

# When each new customers-service pod was created, oldest first
kubectl -n lab-environment get pods -l app=customers-service -o custom-columns=POD:.metadata.name,CREATED:.metadata.creationTimestamp --sort-by=.metadata.creationTimestamp
```
The job completed ~10 s before the first new pod existed. ArgoCD does not
start the Sync phase until every PreSync hook has succeeded. A failed
migration would have stopped the release before one pod changed.

### 3. It is idempotent: read its own log
In the ArgoCD tree, click the `db-init` Job, then its pod, then **Logs**.
Or in the terminal:
```bash
# The migration job's own output from this sync
kubectl -n lab-environment logs job/db-init
```
For each of `customers.sql`, `vets.sql`, `visits.sql`:
- `NOTICE: relation "owners" already exists, skipping`. The tables are
  already there and are left alone.
- `INSERT 0 0`. The seed rows are already there and nothing is
  duplicated.
- `setval` returns the current maximum id, so sequences never rewind
  under rows the app has written since.

The same SQL ran on a live database with data in it and changed nothing.
That is what makes it safe to run on every sync.

## Talking points
- Apps run with `SPRING_SQL_INIT_MODE=never`; schema is owned by one Job,
  not raced by five replicas.
- Idempotent by construction: `CREATE TABLE IF NOT EXISTS`, `ON CONFLICT DO
  NOTHING`, `setval(...)` so sequences never rewind over app rows —
  covered by `tests/test-db-init.sh` against a throwaway postgres.
- `hook-delete-policy: BeforeHookCreation`: the finished Job is kept until
  the next sync replaces it, which is why its log can still be read now.
- Pitfall hit: hook pods run before the same sync applies normal resources,
  so the Job's ServiceAccount and SQL ConfigMap are themselves PreSync hooks
  at wave -1. Tidying the Job to -1 too would remove the ordering.
- Honest limit: this is idempotent SQL, not versioned migrations (no
  Flyway/Liquibase) — an accepted gap.

## Reset
Nothing to reset.
