#!/usr/bin/env bash
# tests/test-docker-oversized-logs.sh — hermetic: sudo and find are
# both stubbed (sudo passes through to same-dir stubs, mirroring the
# real thing running as root).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"

cat > "$bin_dir/sudo" <<'EOF'
#!/usr/bin/env bash
# fake sudo: drop a "-n" if present, execute the rest from PATH (i.e.
# the stub find in this same dir)
[ "${1:-}" = "-n" ] && shift
exec "$@"
EOF
cat > "$bin_dir/find" <<'EOF'
#!/usr/bin/env bash
echo "60000000 /var/lib/docker/containers/aaaa1111bbbb/aaaa1111bbbb-json.log"
echo "2000000 /var/lib/docker/containers/cccc3333dddd/cccc3333dddd-json.log"
EOF
cat > "$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" info "*) exit 0 ;;
  *" ps -a --no-trunc "*)
    printf 'aaaa1111bbbb chatty-app\ncccc3333dddd quiet-app\n'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/sudo" "$bin_dir/find" "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/docker-oversized-logs.sh"

echo "== default 50MiB threshold: only the 60MB log alerts, named by container =="
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "alert names chatty-app, not the hash" \
  "$(grep -q '"target":"docker container chatty-app"' <<<"$out" && echo true || echo false)"
assert_true "alert carries the actual size" \
  "$(grep -q '60000000 bytes' <<<"$out" && echo true || echo false)"
assert_true "quiet-app (2MB) is not flagged" \
  "$(grep -q 'quiet-app' <<<"$out" && echo false || echo true)"
assert_true "exactly one alert line" \
  "$([ "$(grep -c '"tier":"alert"' <<<"$out")" = "1" ] && echo true || echo false)"

echo "== raised threshold suppresses the alert =="
out="$(PATH="$bin_dir:$PATH" INSPECTOR_LOG_ALERT_BYTES=99999999 "$check")"
assert_true "no output when threshold exceeds all logs" \
  "$([ -z "$out" ] && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
