# 13 — mirroring a bad build: the shadow fails on every mirrored call to a
# 2-pet owner, and no user sees it. The waypoint does not access-log shadow
# requests (measured 2026-09-28), so they are read from its per-cluster
# response-class counters instead.
evidence_mirror() {
  local shadow5 all canary stable k5 gtotal gbad
  settle
  shadow5=$(prom_delta 'envoy_cluster_upstream_rq{job="envoy-stats", cluster_name=~".*http/canary.*customers-service.*", response_code_class="5xx"}')
  # User-facing lines only; an authority ending in -shadow would be a copy.
  all=$(subsets_between "$WINDOW_START" "$WINDOW_END" ' | authority!~".*-shadow"')
  canary=$(echo "$all" | count_of canary); stable=$(echo "$all" | count_of stable)
  rec_if envoy "waypoint canary cluster answered $shadow5 mirrored requests with 5xx (want > 0); users were served by stable $stable, canary $canary (want > 0 and 0)" \
    [ "$shadow5" -gt 0 -a "$canary" -eq 0 -a "$stable" -gt 0 ]
  k5=$(prom_delta 'http_server_requests_seconds_count{pod=~"customers-service-canary-.*", status="500"}')
  gtotal=$(loki_count '{service="traffic-generator"}' "$WINDOW_START" "$WINDOW_END")
  gbad=$(loki_count '{service="traffic-generator"} !~ " 200 "' "$WINDOW_START" "$WINDOW_END")
  rec_if app "canary pod's own 500s: $k5 (want > 0); generator: $gbad non-200 of $gtotal (want 0 of > 0)" \
    [ "$k5" -gt 0 -a "$gbad" -eq 0 -a "$gtotal" -gt 0 ]
}

reset_mirror() {
  kubectl -n "$NS" wait --for=delete pod -l app=customers-service,track=canary --timeout=3m
}
