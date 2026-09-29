# 08 — capacity and overload protection: the same stepped load as 2a, now
# against vets-service's resident limiter and tight pool. Excess must fail
# fast, admitted requests must stay fast, and nothing may saturate.
P99_MAX=400   # ms, admitted (200) requests over the whole run - 2a peaked at 842 unprotected

range_minutes() { # range_minutes <query> -> "<epoch> <value floored>" per minute
  curl -sf -G "$PROM/api/v1/query_range" --data-urlencode "query=$1" \
    --data-urlencode "start=$WINDOW_START" --data-urlencode "end=$WINDOW_END" --data-urlencode step=60 \
    | jq -r '.data.result[0].values[]? | "\(.[0]) \(.[1] | tonumber | floor)"'
}

evidence_load_test() {
  local range=$(( WINDOW_END - WINDOW_START )) rps p99 pts shed adm node thr acq wait svc ws alert
  # job="envoy-stats": waypoint pods also carry prometheus.io annotations,
  # so the annotation-driven job scrapes them a second time.
  local API='job="envoy-stats", reporter="waypoint", destination_canonical_service="api-gateway"'
  rps=$(range_minutes "sum(rate(istio_requests_total{$API}[1m]))")
  p99=$(range_minutes "histogram_quantile(0.99, sum by (le) (rate(istio_request_duration_milliseconds_bucket{$API}[1m])))")
  echo "      minute  rps   p99(ms)"
  # Join on the epoch, not on HH:MM, so a run across UTC midnight keeps its rows and order.
  join <(echo "$rps" | sort -k1,1) <(echo "$p99" | sort -k1,1) | sort -n \
    | while read -r t r p; do printf '      %s  %4s  %s\n' "$(date -u -d "@$t" +%H:%M)" "$r" "$p"; done
  pts=$(echo "$p99" | grep -c . || true)
  rec_if envoy "waypoint RPS and P99 per minute over the run: $pts points (want >= 5)" [ "$pts" -ge 5 ]

  shed=$(loki_count '{service="istio-proxy"} | json | __error__="" | authority=~"vets-service.*" | response_code="429" or response_flags=~".*UO.*"' "$WINDOW_START" "$WINDOW_END")
  rec_if envoy "vets-service requests shed fast (429 limiter / UO pool overflow): $shed (want > 0)" [ "$shed" -gt 0 ]
  adm=$(prom "histogram_quantile(0.99, sum by (le) (rate(istio_request_duration_milliseconds_bucket{$API, response_code=\"200\"}[${range}s])))" "$WINDOW_END")
  rec_if envoy "admitted (200) requests' P99 over the whole run: ${adm} ms (want <= $P99_MAX)" \
    awk "BEGIN { exit !(\"$adm\" != \"none\" && $adm + 0 <= $P99_MAX) }"

  node=$(prom "max_over_time(sum(rate(container_cpu_usage_seconds_total{id=\"/\", node=\"vps-oracle2\"}[1m]))[${range}s:30s])" "$WINDOW_END")
  thr=$(prom_vector pod "topk(1, max by (pod) (max_over_time((rate(container_cpu_cfs_throttled_periods_total{namespace=\"$NS\", container!=\"\"}[1m]) / rate(container_cpu_cfs_periods_total{namespace=\"$NS\", container!=\"\"}[1m]))[${range}s:30s])))" "$WINDOW_END")
  rec_if cadvisor "peak node CPU $node of 2 cores (want < 1.6: protection kept the node out of saturation); most throttled: ${thr:-none}" \
    awk "BEGIN { exit !(\"$node\" != \"none\" && $node + 0 < 1.6) }"

  acq=$(prom_vector service "topk(1, max by (service) (max_over_time(hikaricp_connections_acquire_seconds_max[${range}s])))" "$WINDOW_END")
  wait=${acq%% *}; svc=${acq#* }
  rec_if app "longest wait for a DB connection: ${wait:-none}s ($svc) (want < 0.5 - 2a measured 2.99 unprotected)" \
    awk "BEGIN { exit !(\"${wait:-none}\" != \"none\" && ${wait:-0} + 0 < 0.5) }"

  ws=$(prom "max(max_over_time(container_memory_working_set_bytes{namespace=\"$NS\", container=\"vets-service\"}[${range}s]))" "$WINDOW_END")
  note "vets-service peak working set: $(awk "BEGIN { printf \"%d\", $ws / 1048576 }")Mi of its 512Mi limit (ledger D)"
  alert=$(curl -sf "$GRAFANA/api/prometheus/grafana/api/v1/alerts" | jq -r '[.data.alerts[] | select(.labels.alertname == "Lab CPU Throttling") | .state] | join(",")')
  note "Lab CPU Throttling alert state: ${alert:-inactive} (needs 10 min sustained)"
}

reset_load_test() {
  docker rm -f lab-k6 >/dev/null 2>&1 || true
}
