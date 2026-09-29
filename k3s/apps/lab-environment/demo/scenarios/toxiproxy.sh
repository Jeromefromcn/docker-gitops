# 17 — network faults the app did not opt into: toxiproxy between
# visits-service and its data stores. The mesh's 1 s per-try timeout is the
# backstop while the app's own timeouts are longer (redis 2 s, Hikari 30 s).
evidence_toxiproxy() {
  local ut n slow
  settle
  ut=$(loki_by upstream_cluster '{service="istio-proxy"} | json | __error__="" | response_flags="UT"' "$WINDOW_START" "$WINDOW_END")
  echo "$ut" | sed 's/^/      /'
  n=$(echo "$ut" | awk '/visits-service/ { s += $1 } END { print s + 0 }')
  rec_if envoy "upstream timeouts (UT, 1 s per-try) against visits-service: $n (want > 0)" [ "$n" -gt 0 ]
  slow=$(prom "max(max_over_time(http_server_requests_seconds_max{service=\"visits-service\"}[${SETTLED_RANGE}s]))" "$SETTLED_AT")
  rec_if app "visits-service's slowest request in the window: ${slow}s (want > 1 - it kept waiting after the mesh gave up)" \
    awk "BEGIN { exit !(\"$slow\" != \"none\" && $slow + 0 > 1) }"
}

reset_toxiproxy() {
  kubectl -n "$NS" rollout status deploy/visits-service --timeout=6m
}
