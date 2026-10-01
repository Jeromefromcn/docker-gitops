#!/bin/bash
# The traffic generator's pause switch, against the real run.sh from
# k8s/traffic-generator.yaml with stubbed curl and sleep. Needs python3 and
# PyYAML; no cluster access.
#
# The switch is a Consul KV deadline (lab/traffic-generator/pause-until, a unix
# time). It must fail OPEN: a missing key, a deadline in the past, garbage or an
# unreachable Consul all leave the traffic running, so a crashed demo can never
# leave the lab with a silent generator.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"
python3 - "$HERE/../k8s/traffic-generator.yaml" "$WORK/run.sh" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("kind") == "ConfigMap":
        open(sys.argv[2], "w").write(d["data"]["run.sh"])
PY
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/bash
case "$*" in
  *"/v1/kv/"*)
    case "${KV_MODE:-missing}" in
      down) exit 7 ;;
      missing) exit 0 ;;                        # curl -s on a 404 prints an empty body
      future) echo $(( $(date +%s) + 600 )) ;;
      past) echo $(( $(date +%s) - 600 )) ;;
      garbage) echo '<html>oops</html>' ;;
    esac ;;
  *) echo "$*" >> "$WORK/target.log"; printf 200 ;;
esac
STUB
# Ends the otherwise endless loop: the stub's parent is the shell running run.sh.
cat > "$WORK/bin/sleep" <<'STUB'
#!/bin/bash
n=$(( $(cat "$WORK/sleeps" 2>/dev/null || echo 0) + 1 )); echo $n > "$WORK/sleeps"
[ "$n" -lt 4 ] || kill "$PPID"
STUB
chmod +x "$WORK/bin/"*

fails=0
run() { # run <KV_MODE> -> number of target requests
  : > "$WORK/target.log"; rm -f "$WORK/sleeps"
  { KV_MODE=$1 TARGET_URL=http://t WORK=$WORK PATH=$WORK/bin:$PATH sh "$WORK/run.sh" > "$WORK/out" 2>&1; } 2>/dev/null
  wc -l < "$WORK/target.log"
}
expect() { # expect <name> <mode> <min> <max>
  local n; n=$(run "$2")
  if [ "$n" -ge "$3" ] && [ "$n" -le "$4" ]; then echo "PASS $1 ($n requests)"; else echo "FAIL $1 ($n requests, want $3..$4)"; fails=1; fi
}

expect "no pause key: traffic runs" missing 1 99
expect "deadline in the past: traffic runs" past 1 99
expect "garbage in the key: traffic runs (fails open)" garbage 1 99
expect "Consul unreachable: traffic runs (fails open)" down 1 99
expect "deadline in the future: no requests are sent" future 0 0
run missing >/dev/null 2>&1
if grep -qE ' 200 /api/' "$WORK/out"; then echo "PASS a request still logs 'time code path' for the evidence queries"
else echo "FAIL request log line changed"; sed 's/^/    /' "$WORK/out"; fails=1; fi
exit $fails
