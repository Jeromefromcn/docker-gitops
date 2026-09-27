# 08 — capacity baseline: where P99 departs, and what saturated.
evidence_load_test() {
  local range=$(( WINDOW_END - WINDOW_START )) rps p99 pts node thr thrpod ut utn acq svc wait bottleneck='' alert
  # job="envoy-stats": waypoint pods also carry prometheus.io annotations,
  # so the annotation-driven job scrapes them a second time.
  rps=$(curl -sf -G "$PROM/api/v1/query_range" \
    --data-urlencode 'query=sum(rate(istio_requests_total{job="envoy-stats", reporter="waypoint", destination_canonical_service="api-gateway"}[1m]))' \
    --data-urlencode "start=$WINDOW_START" --data-urlencode "end=$WINDOW_END" --data-urlencode step=60 \
    | jq -r '.data.result[0].values[]? | "\(.[0] | todate[11:16]) \(.[1] | tonumber | floor)"')
  p99=$(curl -sf -G "$PROM/api/v1/query_range" \
    --data-urlencode 'query=histogram_quantile(0.99, sum by (le) (rate(istio_request_duration_milliseconds_bucket{job="envoy-stats", reporter="waypoint", destination_canonical_service="api-gateway"}[1m])))' \
    --data-urlencode "start=$WINDOW_START" --data-urlencode "end=$WINDOW_END" --data-urlencode step=60 \
    | jq -r '.data.result[0].values[]? | "\(.[0] | todate[11:16]) \(.[1] | tonumber | floor)"')
  echo "      minute  rps   p99(ms)"
  join <(echo "$rps") <(echo "$p99") | awk '{printf "      %s  %4s  %s\n", $1, $2, $3}'
  pts=$(echo "$p99" | grep -c . || true)
  rec_if envoy "waypoint RPS and P99 per minute over the run: $pts points (want >= 5)" [ "$pts" -ge 5 ]

  ut=$(loki_by upstream_cluster '{service="istio-proxy"} | json | __error__="" | response_flags="UT"' "$WINDOW_START" "$WINDOW_END" | sort -rn)
  echo "$ut" | sed 's/^/      /'
  utn=$(echo "$ut" | awk '{s += $1} END {print s + 0}')
  rec_if envoy "upstream timeouts (UT, 1 s per-try) during the run: $utn — the hop that gave out first is the top line" [ "$utn" -gt 0 ]

  # The two candidate bottlenecks, measured side by side: node CPU vs the
  # per-service DB connection pool (Hikari, max 5 per pod).
  node=$(prom "max_over_time(sum(rate(container_cpu_usage_seconds_total{id=\"/\", node=\"vps-oracle2\"}[1m]))[${range}s:30s])" "$WINDOW_END")
  thr=$(prom_vector pod "topk(1, max by (pod) (max_over_time((rate(container_cpu_cfs_throttled_periods_total{namespace=\"$NS\", container!=\"\"}[1m]) / rate(container_cpu_cfs_periods_total{namespace=\"$NS\", container!=\"\"}[1m]))[${range}s:30s])))" "$WINDOW_END")
  thrpod=${thr#* }; thr=${thr%% *}
  rec_if cadvisor "peak node CPU $node of 2 cores; peak container throttling ${thr:-none} (${thrpod:-none})" [ "$node" != none ]
  if awk "BEGIN { exit !(\"$node\" != \"none\" && $node + 0 >= 1.6) }" || awk "BEGIN { exit !(\"${thr:-0}\" + 0 >= 0.5) }"; then
    bottleneck="node CPU"
  fi
  acq=$(prom_vector service "topk(1, max by (service) (max_over_time(hikaricp_connections_acquire_seconds_max[${range}s])))" "$WINDOW_END")
  wait=${acq%% *}; svc=${acq#* }
  if awk "BEGIN { exit !(\"${wait:-0}\" + 0 >= 0.5) }"; then
    bottleneck="${bottleneck:+$bottleneck + }$svc DB connection pool (waited up to ${wait}s for a connection)"
  fi
  rec_if app "saturated resource: ${bottleneck:-none identified}" [ -n "$bottleneck" ]

  alert=$(curl -sf "$GRAFANA/api/prometheus/grafana/api/v1/alerts" | jq -r '[.data.alerts[] | select(.labels.alertname == "Lab CPU Throttling") | .state] | join(",")')
  note "Lab CPU Throttling alert state: ${alert:-inactive} (needs 10 min sustained)"
}

reset_load_test() {
  docker rm -f lab-k6 >/dev/null 2>&1 || true
}
