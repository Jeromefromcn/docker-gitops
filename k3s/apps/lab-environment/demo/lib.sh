# Shared by demo-window, demo-evidence and demo-reset. Sourced, not run.
# shellcheck disable=SC2034  # variables here are consumed by the sourcing scripts
# Runs on vps_oracle: its kubectl context plus the lab NodePorts.
set -euo pipefail

DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=${DEMO_REPO_ROOT:-$(cd "$DEMO_DIR/../../../.." && pwd)}
LAB_K8S=$DEMO_DIR/../k8s
STATE_DIR=${DEMO_STATE_DIR:-$HOME/.local/state/lab-demo}
SCENARIO_DIR=${DEMO_SCENARIO_DIR:-$DEMO_DIR/scenarios}
NODE=${LAB_NODE_IP:-10.0.0.95}
PROM=http://$NODE:30093
GRAFANA=http://$NODE:30094
JAEGER=http://$NODE:30095
CONSUL=http://$NODE:30092
INGRESS=http://$NODE:30097
NS=lab-environment
BUSINESS="api-gateway customers-service vets-service visits-service"
CANARY=customers-service-canary
# Evidence from these layers is the platform's own record, not the app's.
INFRA_LAYERS=" envoy ztunnel argocd kyverno sealed-secrets cadvisor kubernetes "
mkdir -p "$STATE_DIR"

die() { echo "demo: $*" >&2; exit 2; }
now() { echo "${DEMO_NOW:-$(date +%s)}"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
fn_name() { echo "${1//-/_}"; }

# Where the presenter's browser reaches Grafana (NPM host behind an access list); the API calls
# above use the NodePort. Override with DEMO_GRAFANA_URL.
GRAFANA_PUBLIC=${DEMO_GRAFANA_URL:-https://grafana.lab.jerome.cloudns.asia}
# grafana_link <start> <end> — Lab Business over a demo window, absolute time so no timezone
# arithmetic. The list tables evaluate at the END of the range and look back one Window, so the
# range ends 20 s after the demo (the scrape lag settle() also waits out) and the Window is the
# smallest one (60, 300 or 600 seconds) that still reaches back to the demo's start. The range starts 2 min early so the
# time-series panels show the lead-in.
grafana_link() {
  local start=$1 end=$2 to dur w
  to=$(( end + 20 )); dur=$(( to - start ))
  if [ "$dur" -le 60 ]; then w=60; elif [ "$dur" -le 300 ]; then w=300; else w=600; fi
  echo "$GRAFANA_PUBLIC/d/lab-business/lab-business?from=$(( (start - 120) * 1000 ))&to=$(( to * 1000 ))&var-window=$w"
}

# The traffic generator idles while this Consul KV deadline (unix time) is in the future.
# A scenario that counts its own requests opts in with prepare_<name> (pause) and reset_<name> (resume).
# demo-window stop deliberately leaves it paused: the evidence queries read up to 20 s past the
# window, and the presenter usually talks over the dashboards afterwards.
PAUSE_KEY=lab/traffic-generator/pause-until
# Pauses the generator, then waits out DEMO_PAUSE_DRAIN seconds: Prometheus scrapes every 15 s
# and the dashboards' smallest window is 1m, so 80 s is what it takes for a 1m window to hold
# only the demo's own traffic. The deadline expires on its own after DEMO_PAUSE_TTL seconds.
pause_generator() {
  local ttl=${DEMO_PAUSE_TTL:-900} drain=${DEMO_PAUSE_DRAIN:-80}
  curl -sf -X PUT -d "$(( $(now) + ttl ))" "$CONSUL/v1/kv/$PAUSE_KEY" >/dev/null \
    || die "could not pause the traffic generator (Consul KV at $CONSUL)"
  echo "traffic generator paused; waiting ${drain}s so a 1m dashboard window holds only this demo's traffic" >&2
  if [ "$drain" -gt 0 ]; then sleep "$drain"; fi
}
# A failed resume is only a warning: the deadline expires by itself.
resume_generator() {
  curl -sf -X DELETE "$CONSUL/v1/kv/$PAUSE_KEY" >/dev/null \
    || echo "demo: could not resume the traffic generator; it resumes by itself when the pause deadline passes" >&2
}

scenario_file() {
  local f="$SCENARIO_DIR/$1.sh"
  [ -f "$f" ] || die "unknown scenario '$1' (known: $(cd "$SCENARIO_DIR" && ls ./*.sh | sed 's|^\./||; s|\.sh$||' | tr '\n' ' '))"
  echo "$f"
}
window_file() { echo "$STATE_DIR/$1.window"; }

# Sources <name>'s window file; refuses a missing or still-open window.
load_window() {
  local f; f=$(window_file "$1")
  [ -f "$f" ] || die "no window for '$1' — run: demo-window start $1"
  WINDOW_START='' WINDOW_END=''
  # shellcheck disable=SC1090
  . "$f"
  [ -n "$WINDOW_END" ] || die "window for '$1' is still open — run: demo-window stop $1"
}

# --- evidence tally (a file, so evidence functions may run in a subshell) --
record() {
  local layer=$1 status=$2; shift 2
  printf '  [%-14s] %s  %s\n' "$layer" "$([ "$status" = ok ] && echo PASS || echo FAIL)" "$*"
  echo "$status $layer" >> "$TALLY"
}
rec_if() {
  local layer=$1 text=$2; shift 2
  if "$@"; then record "$layer" ok "$text"; else record "$layer" fail "$text"; fi
}
note() { printf '  [note          ]       %s\n' "$*"; }

# --- queries (curl -f: an unreachable endpoint aborts the evidence run) ----
prom() {
  curl -sf -G "$PROM/api/v1/query" --data-urlencode "query=$1" ${2:+--data-urlencode "time=$2"} \
    | jq -r '.data.result[0].value[1] // "none"'
}
prom_vector() {
  curl -sf -G "$PROM/api/v1/query" --data-urlencode "query=$2" ${3:+--data-urlencode "time=$3"} \
    | jq -r --arg l "$1" '.data.result[] | "\(.value[1]) \(.metric[$l])"'
}
# Prometheus scrapes every 15 s and promtail ships with a lag, so a window
# of a few seconds has no samples of its own. Waits until 20 s past the
# window's end and sets SETTLED_AT / SETTLED_RANGE (>= 60 s) for queries.
settle() {
  SETTLED_AT=$(( WINDOW_END + 20 ))
  while [ "$(date +%s)" -lt "$SETTLED_AT" ]; do sleep 2; done
  SETTLED_RANGE=$(( SETTLED_AT - WINDOW_START ))
  [ "$SETTLED_RANGE" -ge 60 ] || SETTLED_RANGE=60
}
loki_instant() {
  curl -sf -G "$GRAFANA/api/datasources/proxy/uid/loki/loki/api/v1/query" \
    --data-urlencode "query=$1" --data-urlencode "time=${2}000000000"
}
loki_count() {
  loki_instant "sum(count_over_time($1 [$(( $3 - $2 ))s]))" "$3" | jq -r '.data.result[0].value[1] // "0"'
}
loki_by() {
  loki_instant "sum by ($1) (count_over_time($2 [$(( $4 - $3 ))s]))" "$4" \
    | jq -r --arg l "$1" '.data.result[] | "\(.value[1]) \(.metric[$l])"'
}
# Jaeger fills a trace in over ~20 s; wait until the span count stops moving.
jaeger_spans() {
  local id=$1 last=-1 n same=0 i
  for i in $(seq 1 12); do
    n=$(curl -sf "$JAEGER/api/traces/$id" | jq '.data[0].spans | length' 2>/dev/null || echo 0)
    if [ "$n" = "$last" ] && [ "$n" -gt 0 ]; then same=$((same + 1)); [ $same -ge 2 ] && break; else same=0; fi
    last=$n; sleep "${JAEGER_POLL_SECONDS:-5}"
  done
  curl -sf "$JAEGER/api/traces/$id" | jq -r '"\(.data[0].spans | length) spans: \([.data[0].processes[].serviceName] | unique | join(", "))"'
}
# Local socket inside the postgres pod (pg_hba trust) — for reading data only.
pg() { kubectl -n "$NS" exec deploy/postgres -- psql -U petclinic -d "$1" -tAc "$2"; }
git_replicas() { grep -m1 -E '^\s+replicas:' "$LAB_K8S/$1.yaml" | awk '{print $2}'; }
git_image() { grep -m1 -oP 'image: \K\S+' "$LAB_K8S/$1.yaml"; }

# --- routing (2b) -----------------------------------------------------------
# The waypoint logs upstream_cluster as "inbound-vip|8081|http/<subset>|<host>;"
# (no "/<subset>" when the route names none).
CUST_SEL='{service="istio-proxy"} | json | __error__="" | authority=~"customers-service.*"'
by_subset() {
  awk '{ split($2, f, "|"); n = split(f[3], a, "/"); s = (n > 1 ? a[2] : "none"); c[s] += $1 }
       END { for (k in c) print c[k], k }'
}
count_of() { awk -v k="$1" '$2 == k { s += $1 } END { print s + 0 }'; }
pct() { if [ "$2" -gt 0 ]; then echo $(( 100 * $1 / $2 )); else echo 0; fi; }
in_band() { [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
subsets_between() { loki_by upstream_cluster "$CUST_SEL${3:-}" "$1" "$2" | by_subset; }
# A counter's exact growth over the window: increase() extrapolates, and a
# series born inside the window loses its first increments.
prom_delta() {
  local a b
  a=$(prom "sum($1)" "$WINDOW_START"); b=$(prom "sum($1)" "$SETTLED_AT")
  [ "$a" = none ] && a=0; [ "$b" = none ] && b=0
  awk -v a="$a" -v b="$b" 'BEGIN { printf "%d", b - a }'
}
argocd_sync_times() {
  argocd app get lab-environment --core -o json | jq -r --arg s "$1" \
    '[.status.history[] | select(.revision == $s)] | first // empty | "\(.deployStartedAt) \(.deployedAt)"' \
    | while read -r a b; do echo "$(date -u -d "$a" +%s) $(date -u -d "$b" +%s)"; done
}
# Every routing demo returns here: slot empty and on git's image, no PR lane
# pod, every VirtualService route pinned to stable - no weights, mirror or
# header rule.
routing_baseline() {
  local bad=0 got want pods off
  got=$(kubectl -n "$NS" get deploy "$CANARY" -o jsonpath='{.spec.replicas}')
  [ "$got" = 0 ] || { echo "$CANARY spec.replicas '$got', want 0"; bad=1; }
  pods=$(kubectl -n "$NS" get pods -l app=customers-service,track=canary -o name)
  [ -z "$pods" ] || { echo "canary pods still present: $(tr "\n" " " <<< "$pods")"; bad=1; }
  # PR lanes (page 18) live in the headroom page 12's green needs: none may
  # be left behind. Closing the PR or dropping its lane: label removes it.
  # Deployments too: one stuck in FailedCreate has no pod yet, but gets one
  # as soon as its image is signed - possibly in the middle of page 12.
  pods=$(kubectl -n "$NS" get deploy,pods -l lab.jerome/lane -o name)
  [ -z "$pods" ] || { echo "lane objects still present: $(tr "\n" " " <<< "$pods")"; bad=1; }
  got=$(kubectl -n "$NS" get deploy "$CANARY" -o jsonpath='{.spec.template.spec.containers[0].image}')
  want=$(git_image "$CANARY")
  [ "$got" = "$want" ] || { echo "$CANARY image '$got', git wants $want"; bad=1; }
  if ! off=$(kubectl -n "$NS" get virtualservice customers-service -o json | jq -r '
      [.spec.http[] | [ (if .mirror or .mirrors then "mirror" else empty end),
                        (if (.route | length) != 1 then "weights" else empty end),
                        (if (.route | length) == 1 and .route[0].destination.subset != "stable"
                           then "subset \(.route[0].destination.subset // "none")" else empty end),
                        (if any(.match[]?; .headers) then "header match" else empty end),
                        (if .fault then "fault" else empty end) ]
                      | select(length > 0) | join("+")] | join(", ")'); then
    echo "customers-service VirtualService not read"; bad=1
  elif [ -n "$off" ]; then
    echo "customers-service VirtualService routes off the stable pin: $off"; bad=1
  fi
  return $bad
}
# Reset step shared by the routing scenarios: waits for the canary pods to go,
# but refuses at once while the slot is still scaled - that means the page's
# git revert was not pushed, and waiting would only burn the timeout.
wait_canary_gone() {
  local r
  r=$(kubectl -n "$NS" get deploy "$CANARY" -o jsonpath='{.spec.replicas}')
  [ "$r" = 0 ] || { echo "$CANARY is still scaled to '$r' - was the page's git revert pushed?"; return 1; }
  kubectl -n "$NS" wait --for=delete pod -l app=customers-service,track=canary --timeout="${1:-3m}"
}

# --- dependency chaos (2c) ---------------------------------------------------
# 17 routes visits' postgres/redis through toxiproxy and lets postgres/redis
# admit toxiproxy's identity - both must be gone after the page's revert.
toxiproxy_baseline() {
  local bad=0 envs n
  envs=$(kubectl -n "$NS" get deploy visits-service -o jsonpath='{.spec.template.spec.containers[0].env[*].name}')
  case " $envs " in *" DATA_DB_HOST "*|*" DATA_REDIS_HOST "*)
    echo "visits-service still points at toxiproxy (env: $envs)"; bad=1 ;; esac
  if ! n=$(kubectl -n "$NS" get authorizationpolicy postgres-clients redis-clients -o json \
      | jq '[.items[].spec.rules[].from[].source.principals[]? | select(endswith("/sa/toxiproxy"))] | length'); then
    echo "postgres/redis authorization policies not read"; bad=1
  elif [ "$n" != 0 ]; then
    echo "postgres/redis still admit sa/toxiproxy"; bad=1
  fi
  return $bad
}

# --- baseline ---------------------------------------------------------------
baseline_check() {
  local bad=0 on d got want st lines total non200
  # Called as an if-condition, so set -e is off here: every read checks its
  # own exit status, or an unreachable Consul would read as "no toggles on".
  if ! on=$(curl -sf "$CONSUL/v1/kv/chaos/?recurse" | jq -r '.[] | select((.Value // "" | @base64d) != "false") | .Key'); then
    echo "Consul unreachable — chaos toggles not read"; bad=1
  elif [ -n "$on" ]; then
    echo "chaos toggles still on: $on"; bad=1
  fi
  for d in $BUSINESS; do
    want=$(git_replicas "$d")
    got=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.status.readyReplicas} {.spec.replicas}')
    [ "$got" = "$want $want" ] || { echo "$d ready/spec '$got', git wants $want"; bad=1; }
  done
  st=$(argocd app get lab-environment --core -o json | jq -r '.status.sync.status + "/" + .status.health.status')
  [ "$st" = "Synced/Healthy" ] || { echo "lab-environment is $st"; bad=1; }
  lines=$(kubectl -n "$NS" logs deploy/traffic-generator --since=30s)
  total=$(echo "$lines" | grep -c . || true)
  non200=$(echo "$lines" | awk 'NF && $2 != "200"' | grep -c . || true)
  { [ "$total" -gt 0 ] && [ "$non200" -eq 0 ]; } || { echo "generator last 30s: $total requests, $non200 non-200"; bad=1; }
  routing_baseline || bad=1
  toxiproxy_baseline || bad=1
  kubectl -n "$NS" get trafficextension vets-service-ratelimit -o name 2>/dev/null | grep -q . \
    || { echo "vets-service-ratelimit TrafficExtension missing"; bad=1; }
  return $bad
}
wait_baseline() {
  local deadline=$(( $(date +%s) + ${DEMO_RESET_TIMEOUT:-180} ))
  while :; do
    if baseline_check > "$STATE_DIR/.baseline" 2>&1; then echo "baseline OK"; return 0; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then sed 's/^/  /' "$STATE_DIR/.baseline"; echo "baseline NOT restored"; return 1; fi
    sleep 10
  done
}
