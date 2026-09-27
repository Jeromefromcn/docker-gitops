# 02 — zero-downtime rolling update triggered through git.
DEMO_COMMIT_SUBJECT='demo: rolling-restart customers-service'

start_rolling_update() {
  echo "OWNERS_BEFORE=$(pg customers 'select count(*) from owners')" >> "$WINDOW_FILE"
}

evidence_rolling_update() {
  local sha deployed ok want created non2xx total bad
  sha=$(git -C "$REPO_ROOT" log -1 --grep="^$DEMO_COMMIT_SUBJECT\$" --format=%H)
  # History, not the live revision: a later commit may already have landed.
  deployed=$(argocd app get lab-environment --core -o json \
    | jq -r --arg s "$(iso "$WINDOW_START")" '[.status.history[] | select(.deployedAt >= $s) | .revision] | join(" ")')
  ok=0; [ -n "$sha" ] && [[ " $deployed " == *" $sha "* ]] && ok=1
  rec_if argocd "ArgoCD deployed the demo commit ${sha:0:7} inside the window" [ $ok = 1 ]
  want=$(git_replicas customers-service)
  created=$(kubectl -n "$NS" get pods -l app=customers-service -o json | jq --arg s "$(iso "$WINDOW_START")" \
    '[.items[] | select(.metadata.creationTimestamp >= $s) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length')
  rec_if kubernetes "customers-service pods replaced in the window and Ready: $created (want $want)" [ "$created" -eq "$want" ]
  non2xx=$(loki_count '{service="istio-proxy"} | json | response_code!~"2.."' "$WINDOW_START" "$WINDOW_END")
  rec_if envoy "non-2xx responses at ingress + waypoint during the rollout: $non2xx (want 0)" [ "$non2xx" -eq 0 ]
  total=$(loki_count '{service="traffic-generator"}' "$WINDOW_START" "$WINDOW_END")
  bad=$(loki_count '{service="traffic-generator"} !~ " 200 "' "$WINDOW_START" "$WINDOW_END")
  ok=0; [ "$total" -gt 0 ] && [ "$bad" -eq 0 ] && ok=1
  rec_if app "generator requests during the rollout: $total, non-200: $bad (want 0)" [ $ok = 1 ]
}

reset_rolling_update() {
  kubectl -n "$NS" rollout status deploy/customers-service --timeout=6m
}
