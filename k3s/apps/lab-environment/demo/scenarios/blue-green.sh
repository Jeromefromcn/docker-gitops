# 12 — blue-green: a full-size green (the canary slot at 5 replicas) takes
# 100 % at the switch's sync and gives it back at the rollback's.
SWITCH_SUBJECT='demo: switch customers-service to green'
# s after a sync finishes before every request must be on the new route. The
# waypoint's routes live in its listener (LDS); an update leaves existing
# keep-alive connections on the old route until Envoy's 45 s drain ends
# (measured 2026-09-28: a canary hit 28 s after the rollback finished).
TRANSITION=50

evidence_blue_green() {
  local sw back t a b c ok s1 e1 s2 e2 gtotal gbad
  settle
  sw=$(git -C "$REPO_ROOT" log -1 --grep="^$SWITCH_SUBJECT\$" --format=%H)
  back=$(git -C "$REPO_ROOT" log -1 --grep="^Revert \"$SWITCH_SUBJECT\"\$" --format=%H)
  t=$(argocd_sync_times "$sw"); s1=${t% *}; e1=${t#* }
  t=$(argocd_sync_times "$back"); s2=${t% *}; e2=${t#* }
  ok=0; [ -n "$s1" ] && [ -n "$s2" ] && [ "$s1" -gt "$WINDOW_START" ] && [ "$s2" -gt $((e1 + TRANSITION)) ] \
    && [ "$WINDOW_END" -gt $((e2 + TRANSITION)) ] && ok=1
  rec_if argocd "ArgoCD deployed the switch ${sw:0:7} and its rollback ${back:0:7} inside the window" [ $ok = 1 ]
  [ $ok = 1 ] || return 0
  # Requests between a sync's start and its end + TRANSITION are in flight
  # between routes and are not judged.
  a=$(subsets_between "$WINDOW_START" "$s1")
  b=$(subsets_between $((e1 + TRANSITION)) "$s2")
  c=$(subsets_between $((e2 + TRANSITION)) "$WINDOW_END")
  echo "      before: $(tr '\n' ' ' <<< "$a")| green: $(tr '\n' ' ' <<< "$b")| after: $(tr '\n' ' ' <<< "$c")"
  ok=0
  [ "$(echo "$a" | count_of canary)" -eq 0 ] && [ "$(echo "$a" | count_of stable)" -gt 0 ] &&
  [ "$(echo "$b" | count_of stable)" -eq 0 ] && [ "$(echo "$b" | count_of canary)" -gt 0 ] &&
  [ "$(echo "$c" | count_of canary)" -eq 0 ] && [ "$(echo "$c" | count_of stable)" -gt 0 ] && ok=1
  rec_if envoy "waypoint subsets: all blue before the switch, all green after it, all blue after the rollback" [ $ok = 1 ]
  gtotal=$(loki_count '{service="traffic-generator"}' "$WINDOW_START" "$WINDOW_END")
  gbad=$(loki_count '{service="traffic-generator"} !~ " 200 "' "$WINDOW_START" "$WINDOW_END")
  rec_if app "generator over the whole window: $gbad non-200 of $gtotal (want 0 of > 0)" [ "$gbad" -eq 0 -a "$gtotal" -gt 0 ]
  note "green P99 over its first 60 s: $(loki_instant "max(quantile_over_time(0.99, $CUST_SEL | unwrap duration_ms [60s]))" $((e1 + 60)) | jq -r '.data.result[0].value[1] // "n/a"') ms (cold JVMs)"
}

reset_blue_green() {
  wait_canary_gone 4m
}
