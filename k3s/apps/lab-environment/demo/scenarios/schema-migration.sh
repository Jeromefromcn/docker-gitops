# 03 — no action of its own: reads the PreSync hook out of 02's sync.
WINDOW_FROM=rolling-update

evidence_schema_migration() {
  local sha op hook oprev ok done_at first_pod owners
  sha=$(git -C "$REPO_ROOT" log -1 --grep='^demo: rolling-restart customers-service$' --format=%H)
  op=$(argocd app get lab-environment --core -o json | jq -c '.status.operationState')
  hook=$(echo "$op" | jq -r '[.syncResult.resources[] | select(.kind == "Job" and .name == "db-init")][0] | "\(.syncPhase)/\(.hookPhase)"')
  oprev=$(echo "$op" | jq -r '.syncResult.revision')
  ok=0; [ "$hook" = "PreSync/Succeeded" ] && [ "$oprev" = "$sha" ] && ok=1
  rec_if argocd "sync of ${sha:0:7} ran db-init as $hook (want PreSync/Succeeded; last op revision ${oprev:0:7})" [ $ok = 1 ]
  done_at=$(kubectl -n "$NS" get job db-init -o jsonpath='{.status.completionTime}')
  first_pod=$(kubectl -n "$NS" get pods -l app=customers-service -o json | jq -r '[.items[].metadata.creationTimestamp] | min')
  ok=0; [[ "$done_at" > "$(iso "$WINDOW_START")" ]] && ! [[ "$done_at" > "$first_pod" ]] && ok=1
  rec_if kubernetes "db-init completed $done_at, first new customers pod $first_pod (hook first)" [ $ok = 1 ]
  owners=$(pg customers 'select count(*) from owners')
  ok=0; [ -n "${OWNERS_BEFORE:-}" ] && [ "$owners" = "$OWNERS_BEFORE" ] && ok=1
  rec_if postgres "owners before/after the re-run: ${OWNERS_BEFORE:-?}/$owners (idempotent)" [ $ok = 1 ]
  kubectl -n "$NS" logs job/db-init | grep applying | sed 's/^/      /'
}
