#!/usr/bin/env bash
# tests/test-docker-stopped-containers.sh — hermetic: docker is a stub
# in a temp PATH dir, so no real container is ever listed or removed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
export STUB_DIR="$bin_dir"

old_finished="2020-01-01T00:00:00.000000000Z"   # always far past any threshold
recent_finished="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%S.000000000Z)"

cat > "$bin_dir/docker" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" info "*) exit 0 ;;
  *" ps -a --filter status=exited "*)
    printf 'oldcid000111\tleftover-app\nrecentcid222\tjust-stopped\n'
    ;;
  *" inspect "*)
    case "\$*" in
      *oldcid000111*) echo "$old_finished" ;;
      *recentcid222*) echo "$recent_finished" ;;
      *) exit 1 ;;
    esac
    ;;
  *" rm "*)
    echo "docker \$*" >> "\$STUB_DIR/calls.log"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/docker-stopped-containers.sh"

echo "== dry run: only the long-exited container is proposed =="
out="$(PATH="$bin_dir:$PATH" INSPECTOR_DRY_RUN=1 "$check")"
assert_true "would-delete for leftover-app" \
  "$(grep -q '"action":"would-delete"' <<<"$out" && grep -q 'leftover-app' <<<"$out" && echo true || echo false)"
assert_true "just-stopped (1h) is not proposed" \
  "$(grep -q 'just-stopped' <<<"$out" && echo false || echo true)"
assert_true "dry run issued no docker rm" \
  "$([ ! -f "$bin_dir/calls.log" ] && echo true || echo false)"

echo "== real run: only the long-exited container is removed =="
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "deleted line for leftover-app" \
  "$(grep -q '"action":"deleted"' <<<"$out" && grep -q 'leftover-app' <<<"$out" && echo true || echo false)"
assert_true "docker rm called for oldcid000111 and nothing else" \
  "$(grep -q 'docker rm oldcid000111' "$bin_dir/calls.log" && [ "$(grep -c 'docker rm' "$bin_dir/calls.log")" = "1" ] && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
