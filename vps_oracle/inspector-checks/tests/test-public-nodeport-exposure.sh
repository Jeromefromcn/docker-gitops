#!/usr/bin/env bash
# tests/test-public-nodeport-exposure.sh — hermetic: ssh, getent and kubectl
# are stubbed. The ssh stub plays the external vantage point: it answers each
# probed port with the exit code listed in $RESULTS_FILE ("<port> <rc>"),
# defaulting to 124 (timeout = filtered), and records the ports it was asked
# to probe in $STUB_DIR/probed.log.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../host-native/inspector/tests/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
export STUB_DIR="$bin_dir"
export RESULTS_FILE="$work_dir/results"
export INSPECTOR_KUBECONFIG="$work_dir/kubeconfig"
touch "$INSPECTOR_KUBECONFIG"

cat > "$bin_dir/getent" <<'EOF'
#!/usr/bin/env bash
[ "${GETENT_FAIL:-0}" = "1" ] && exit 2
echo "198.51.100.7    $2"
EOF

cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
[ "${KUBECTL_FAIL:-0}" = "1" ] && exit 1
printf '30114\n30555\n\n'
EOF

# Remote side: everything after "--" is <ip> <port>...; the script body on
# stdin is ignored — the stub stands in for its result.
cat > "$bin_dir/ssh" <<'EOF'
#!/usr/bin/env bash
[ "${SSH_FAIL:-0}" = "1" ] && exit 255
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift; ip="$1"; shift
cat >/dev/null
echo "ip $ip" >> "$STUB_DIR/probed.log"
for p in "$@"; do
  echo "$p" >> "$STUB_DIR/probed.log"
  rc="$(awk -v p="$p" '$1 == p {print $2}' "$RESULTS_FILE" 2>/dev/null)"
  echo "$p ${rc:-124}"
done
[ "${SSH_GARBAGE:-0}" = "1" ] && echo "not a result line"
exit 0
EOF
chmod +x "$bin_dir"/*

check="$SCRIPT_DIR/../checks/public-nodeport-exposure.sh"
run() { PATH="$bin_dir:$PATH" "$check"; }
reset() { rm -f "$bin_dir/probed.log"; : > "$RESULTS_FILE"; }

echo "== everything filtered, 443 reachable: silent =="
reset; echo "443 0" > "$RESULTS_FILE"
out="$(run)"
assert_true "no output" "$([ -z "$out" ] && echo true || echo false)"
assert_true "probes the resolved public IP" \
  "$(grep -qx 'ip 198.51.100.7' "$bin_dir/probed.log" && echo true || echo false)"
assert_true "probes the NodePort range boundaries" \
  "$(grep -qx 30000 "$bin_dir/probed.log" && grep -qx 32767 "$bin_dir/probed.log" && echo true || echo false)"
assert_true "probes the allocated NodePorts kubectl reports" \
  "$(grep -qx 30555 "$bin_dir/probed.log" && echo true || echo false)"
assert_true "probes each port once (kubectl and sample overlap on 30114)" \
  "$([ "$(grep -cx 30114 "$bin_dir/probed.log")" = "1" ] && echo true || echo false)"

echo "== a port connects, another is refused: both are exposure =="
reset; printf '443 0\n30114 0\n31000 1\n' > "$RESULTS_FILE"
out="$(run)"
assert_true "one alert" \
  "$([ "$(grep -c '"tier":"alert"' <<<"$out")" = "1" ] && echo true || echo false)"
assert_true "alert names the public IP" \
  "$(grep -q '198.51.100.7' <<<"$out" && echo true || echo false)"
assert_true "detail lists 30114 as open and 31000 as reaching the host" \
  "$(grep -q '30114 (open)' <<<"$out" && grep -q '31000 (reached host)' <<<"$out" && echo true || echo false)"
assert_true "detail points at the OCI security list" \
  "$(grep -q 'security list' <<<"$out" && echo true || echo false)"
assert_true "alert tier never deletes" \
  "$(grep -qE 'deleted|would-delete' <<<"$out" && echo false || echo true)"

echo "== vantage cannot reach public 443: result untrustworthy, alert =="
reset
out="$(run)"
assert_true "vantage alert raised" \
  "$(grep -q '"target":"check:public-nodeport-exposure.sh"' <<<"$out" && grep -q '443' <<<"$out" && echo true || echo false)"
assert_true "no exposure verdict when the vantage is broken" \
  "$(grep -q 'exposed' <<<"$out" && echo false || echo true)"

echo "== ssh to the vantage fails: alert, not silence =="
reset
out="$(SSH_FAIL=1 run)"
assert_true "ssh failure alert" \
  "$(grep -q '"target":"check:public-nodeport-exposure.sh"' <<<"$out" && grep -q '"tier":"alert"' <<<"$out" && echo true || echo false)"

echo "== public hostname does not resolve: alert =="
reset
out="$(GETENT_FAIL=1 run)"
assert_true "dns failure alert" \
  "$(grep -q 'resolve' <<<"$out" && grep -q '"tier":"alert"' <<<"$out" && echo true || echo false)"

echo "== kubectl unavailable: still probes the fixed sample =="
reset; echo "443 0" > "$RESULTS_FILE"
out="$(KUBECTL_FAIL=1 run)"
assert_true "no output" "$([ -z "$out" ] && echo true || echo false)"
assert_true "sample still probed" \
  "$(grep -qx 30000 "$bin_dir/probed.log" && echo true || echo false)"

echo "== garbage line in remote output: ignored, no crash =="
reset; echo "443 0" > "$RESULTS_FILE"
out="$(SSH_GARBAGE=1 run)"; rc=$?
assert_true "exit 0" "$([ "$rc" = "0" ] && echo true || echo false)"
assert_true "no output" "$([ -z "$out" ] && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
