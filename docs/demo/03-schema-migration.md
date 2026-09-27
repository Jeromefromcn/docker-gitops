# 03 — Schema migration as a PreSync hook

## Purpose
Show that the schema job runs *before* the new pods, on every sync, and is
idempotent — using 02's sync, without inventing a schema change.

## Preconditions
Scenario 02 just finished. Run this before scenario 07 pushes anything:
the ArgoCD check reads the app's last operation.

## Commands
```bash
argocd app get lab-environment --core -o json | jq -r '.status.operationState.syncResult.resources[] | select(.hookPhase) | select(.syncPhase=="PreSync") | "\(.syncPhase) \(.kind)/\(.name) \(.hookPhase)"'
kubectl -n lab-environment logs job/db-init
demo-evidence schema-migration
```

## Expected result
PreSync lists `ServiceAccount/db-init`, `ConfigMap/db-init-sql`,
`Job/db-init`, all `Succeeded`; the job log shows `applying customers.sql`,
`vets.sql`, `visits.sql`; owners count unchanged.

## Evidence
- **ArgoCD:** `db-init` ran as `PreSync/Succeeded` in the sync of 02's commit.
- **Kubernetes:** job completion time precedes the first new customers pod.
- **Postgres:** owners count identical before and after (idempotent SQL).

## Talking points
- Apps run with `SPRING_SQL_INIT_MODE=never`; schema is owned by one Job,
  not raced by five replicas.
- Idempotent by construction: `CREATE TABLE IF NOT EXISTS`, `ON CONFLICT DO
  NOTHING`, `setval(...)` so sequences never rewind over app rows —
  covered by `tests/test-db-init.sh` against a throwaway postgres.
- Pitfall hit: hook pods run before the same sync applies normal resources,
  so the Job's ServiceAccount and SQL ConfigMap are themselves PreSync hooks
  at wave -1. Tidying the Job to -1 too would remove the ordering.
- Honest limit: this is idempotent SQL, not versioned migrations (no
  Flyway/Liquibase) — an accepted gap.

## Reset
`demo-reset schema-migration` — verifies the baseline.
