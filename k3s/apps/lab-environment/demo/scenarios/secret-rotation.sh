# 06 — rotate the DB password through SealedSecrets and git.
OLD_PW_FILE_NAME=secret-rotation.old

start_secret_rotation() {
  ( umask 077; kubectl -n "$NS" get secret lab-db-credentials -o jsonpath='{.data.password}' | base64 -d > "$STATE_DIR/$OLD_PW_FILE_NAME" )
}

# Prints accepted / rejected / inconclusive for a password, over scram.
scram_try() {
  local user out
  user=$(kubectl -n "$NS" get secret lab-db-credentials -o jsonpath='{.data.username}' | base64 -d)
  out=$(kubectl -n "$NS" exec -i deploy/postgres -- sh -c \
    'read -r P; PGPASSWORD="$P" psql -h "$(hostname -i)" -U "$1" -d customers -tAc "select 1" 2>&1' _ "$user" <<< "$1" 2>/dev/null || true)
  case $out in
    1) echo accepted ;;
    *"password authentication failed"*) echo rejected ;;
    *) echo inconclusive ;;
  esac
}

evidence_secret_rotation() {
  local hist upd ok old new created d want c total bad
  hist=$(argocd app get sealed-secrets --core -o json \
    | jq -r --arg s "$(iso "$WINDOW_START")" '[.status.history[] | select(.deployedAt >= $s)] | length')
  rec_if argocd "sealed-secrets app deployments inside the window: $hist (want >= 1)" [ "$hist" -ge 1 ]
  upd=$(kubectl -n "$NS" get sealedsecret lab-db-credentials -o json \
    | jq -r '.status.conditions[] | select(.type == "Synced") | "\(.status) \(.lastUpdateTime)"')
  ok=0; [ "${upd%% *}" = True ] && [[ "${upd#* }" > "$(iso "$WINDOW_START")" ]] && ok=1
  rec_if sealed-secrets "controller re-unsealed lab-db-credentials in the window: $upd" [ $ok = 1 ]
  old=$(scram_try "$(cat "$STATE_DIR/$OLD_PW_FILE_NAME")")
  new=$(scram_try "$(kubectl -n "$NS" get secret lab-db-credentials -o jsonpath='{.data.password}' | base64 -d)")
  ok=0; [ "$old" = rejected ] && [ "$new" = accepted ] && ok=1
  rec_if postgres "over scram: old password $old, new password $new" [ $ok = 1 ]
  ok=1
  for d in customers-service vets-service visits-service; do
    want=$(git_replicas "$d")
    c=$(kubectl -n "$NS" get pods -l app="$d" -o json | jq --arg s "$(iso "$WINDOW_START")" \
      '[.items[] | select(.metadata.creationTimestamp >= $s) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length')
    note "$d: $c/$want pods restarted onto the new Secret"
    [ "$c" -eq "$want" ] || ok=0
  done
  rec_if kubernetes "all three DB clients restarted in the window and Ready" [ $ok = 1 ]
  total=$(loki_count '{service="traffic-generator"}' "$WINDOW_START" "$WINDOW_END")
  bad=$(loki_count '{service="traffic-generator"} !~ " 200 "' "$WINDOW_START" "$WINDOW_END")
  note "generator during the rotation: $total requests, $bad non-200 (the measured error window)"
}

reset_secret_rotation() {
  rm -f "$STATE_DIR/$OLD_PW_FILE_NAME"
  local st
  st=$(argocd app get sealed-secrets --core -o json | jq -r '.status.sync.status + "/" + .status.health.status')
  [ "$st" = "Synced/Healthy" ] || { echo "sealed-secrets is $st"; return 1; }
  for d in customers-service vets-service visits-service; do kubectl -n "$NS" rollout status deploy/$d --timeout=8m; done
}
