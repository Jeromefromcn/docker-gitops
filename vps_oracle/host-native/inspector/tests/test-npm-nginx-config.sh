#!/usr/bin/env bash
# tests/test-npm-nginx-config.sh — hermetic docker stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"

# One stub driven by env vars, so each scenario below is a different
# STUB_* combination rather than a separate fake docker.
cat > "$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" info "*)
    [ "${STUB_DOCKER_DOWN:-0}" = "1" ] && exit 1
    exit 0
    ;;
  *" inspect "*)
    case "${STUB_NPM_STATE:-running}" in
      running) echo "true" ;;
      stopped) echo "false" ;;
      missing) exit 1 ;;
    esac
    ;;
  *" exec "*)
    if [ "${STUB_NGINX_T_FAIL:-0}" = "1" ]; then
      echo 'nginx: [emerg] host not found in upstream "dify-api" in /data/nginx/proxy_host/24.conf:74'
      echo 'nginx: configuration file /etc/nginx/nginx.conf test failed'
      exit 1
    fi
    echo 'nginx: the configuration file /etc/nginx/nginx.conf syntax is ok'
    echo 'nginx: configuration file /etc/nginx/nginx.conf test is successful'
    exit 0
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/npm-nginx-config.sh"
run_check() { env PATH="$bin_dir:$PATH" "$@" "$check"; }

echo "== a valid config emits nothing =="
out="$(run_check)"
assert_true "no result line when nginx -t succeeds" \
  "$([ -z "$out" ] && echo true || echo false)"

echo "== a failing nginx -t alerts, quoting the emerg line =="
out="$(run_check STUB_NGINX_T_FAIL=1)"
assert_true "exactly one alert line" \
  "$([ "$(grep -c '"tier":"alert"' <<<"$out")" = "1" ] && echo true || echo false)"
assert_true "detail names the unresolvable upstream" \
  "$(grep -q 'host not found in upstream' <<<"$out" && echo true || echo false)"
assert_true "detail names the offending file" \
  "$(grep -q '24.conf:74' <<<"$out" && echo true || echo false)"
assert_true "detail says traffic is still fine (this is not a live outage)" \
  "$(grep -q 'traffic is unaffected' <<<"$out" && echo true || echo false)"

echo "== a stopped npm container alerts, without pretending to have tested =="
out="$(run_check STUB_NPM_STATE=stopped)"
assert_true "alert line for the stopped container" \
  "$(grep -q '"tier":"alert"' <<<"$out" && grep -q 'not running' <<<"$out" && echo true || echo false)"
assert_true "does not claim nginx -t failed" \
  "$(grep -q 'nginx -t failed' <<<"$out" && echo false || echo true)"

echo "== no npm container at all is a silent skip, not an alert =="
out="$(run_check STUB_NPM_STATE=missing)"
assert_true "no result line when the container does not exist" \
  "$([ -z "$out" ] && echo true || echo false)"

echo "== an unreachable docker daemon reports itself as skipped =="
out="$(run_check STUB_DOCKER_DOWN=1)"
assert_true "alert line naming the check itself" \
  "$(grep -q 'check:npm-nginx-config.sh' <<<"$out" && echo true || echo false)"

echo "== report text stays English (Telegram reports carry no CJK) =="
out="$(run_check STUB_NGINX_T_FAIL=1; run_check STUB_NPM_STATE=stopped; run_check STUB_DOCKER_DOWN=1)"
assert_true "no CJK characters in any emitted detail" \
  "$(grep -qP '[\x{4e00}-\x{9fff}]' <<<"$out" && echo false || echo true)"

rm -rf "$work_dir"
finish_tests
