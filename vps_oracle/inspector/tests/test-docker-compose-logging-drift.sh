#!/usr/bin/env bash
# tests/test-docker-compose-logging-drift.sh — hermetic: fixture repo
# tree with two compose files, docker stub serves canned `compose
# config` JSON per file path.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir" \
  "$work_dir/hosta/compose/good" "$work_dir/hostb/compose/bad"
echo "services:" > "$work_dir/hosta/compose/good/docker-compose.yml"   # content unused; stub serves JSON
echo "services:" > "$work_dir/hostb/compose/bad/docker-compose.yml"

good_json="$work_dir/good.json"
bad_json="$work_dir/bad.json"
cat > "$good_json" <<'EOF'
{"services":{"with-limits":{"image":"x","logging":{"driver":"json-file","options":{"max-size":"10m","max-file":"5"}}}}}
EOF
cat > "$bad_json" <<'EOF'
{"services":{"fine":{"image":"x","logging":{"driver":"json-file","options":{"max-size":"10m"}}},"no-logging":{"image":"x"},"wrong-logging":{"image":"x","logging":{"driver":"json-file"}}}}
EOF

cat > "$bin_dir/docker" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" info "*) exit 0 ;;
  *" compose "*)
    case "\$*" in
      *good/docker-compose.yml*) cat "$good_json" ;;
      *bad/docker-compose.yml*)  cat "$bad_json" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/docker-compose-logging-drift.sh"

out="$(PATH="$bin_dir:$PATH" INSPECTOR_REPO_ROOT="$work_dir" "$check")"
assert_true "flags the service with no logging block" \
  "$(grep -q '"target":"hostb/compose/bad/docker-compose.yml:no-logging"' <<<"$out" && echo true || echo false)"
assert_true "flags the service with logging but no max-size" \
  "$(grep -q 'wrong-logging' <<<"$out" && echo true || echo false)"
assert_true "conformant service in the same file is not flagged" \
  "$(grep -q ':fine"' <<<"$out" && echo false || echo true)"
assert_true "fully conformant stack produces no line" \
  "$(grep -q 'hosta' <<<"$out" && echo false || echo true)"

rm -rf "$work_dir"
finish_tests
