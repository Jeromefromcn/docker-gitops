# 10 — canary by weight on a bad build: the waypoint's log shows every 5xx
# came from the canary subset, and the rollback is a git revert.
DEMO_COMMIT_SUBJECT='demo: canary customers-service v2-bad at 10%'

evidence_canary_weight() {
  local all errs canary stable share c5 s5 revert ok a5 k5
  settle
  all=$(subsets_between "$WINDOW_START" "$WINDOW_END")
  errs=$(subsets_between "$WINDOW_START" "$WINDOW_END" ' | response_code=~"5.."')
  canary=$(echo "$all" | count_of canary); stable=$(echo "$all" | count_of stable)
  share=$(pct "$canary" $((canary + stable)))
  c5=$(echo "$errs" | count_of canary); s5=$(echo "$errs" | count_of stable)
  ok=0; [ "$s5" -eq 0 ] && [ "$c5" -gt 0 ] && in_band "$share" 3 20 && ok=1
  rec_if envoy "canary took ${share}% of customers-service requests (want 3-20); 5xx: canary $c5, stable $s5 (want > 0 and 0)" [ $ok = 1 ]
  revert=$(git -C "$REPO_ROOT" log -1 --grep="^Revert \"$DEMO_COMMIT_SUBJECT\"\$" --format=%H)
  ok=0; [ -n "$revert" ] && [ -n "$(argocd_sync_times "$revert")" ] && ok=1
  rec_if argocd "ArgoCD deployed the rollback ${revert:0:7}" [ $ok = 1 ]
  a5=$(prom_delta 'http_server_requests_seconds_count{service="customers-service", status="500"}')
  k5=$(prom_delta 'http_server_requests_seconds_count{pod=~"customers-service-canary-.*", status="500"}')
  ok=0; [ "$k5" -gt 0 ] && [ $((a5 - k5)) -eq 0 ] && ok=1
  rec_if app "Spring 500s by the pods' own count: canary $k5, stable $((a5 - k5)) (want > 0 and 0)" [ $ok = 1 ]
}

reset_canary_weight() {
  wait_canary_gone 3m
}
