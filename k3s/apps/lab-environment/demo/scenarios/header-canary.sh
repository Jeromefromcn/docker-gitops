# 11 — header / cookie gray release: only marked requests reach the canary.
MARKED=40   # the page sends 20 with the x-canary header and 20 with the cookie

evidence_header_canary() {
  local all canary stable c
  settle
  all=$(subsets_between "$WINDOW_START" "$WINDOW_END")
  canary=$(echo "$all" | count_of canary); stable=$(echo "$all" | count_of stable)
  rec_if envoy "waypoint routed $canary requests to the canary (want exactly $MARKED, the marked ones) and $stable to stable (want > 0)" \
    [ "$canary" -eq "$MARKED" -a "$stable" -gt 0 ]
  c=$(prom_delta 'http_server_requests_seconds_count{pod=~"customers-service-canary-.*", uri!~"/actuator.*"}')
  rec_if app "the canary pod counted $c requests itself (want $MARKED)" [ "$c" -eq "$MARKED" ]
}

reset_header_canary() {
  kubectl -n "$NS" wait --for=delete pod -l app=customers-service,track=canary --timeout=3m
}
