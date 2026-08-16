#!/usr/bin/env bash
# tests/test-docker-dangling-images.sh — hermetic docker stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
export STUB_DIR="$bin_dir"

old_created="2020-01-01T00:00:00.000000000Z"
recent_created="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%S.000000000Z)"

cat > "$bin_dir/docker" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" info "*) exit 0 ;;
  *" images --filter dangling=true "*)
    printf 'imgold111222\nimgnew333444\n'
    ;;
  *" image inspect "*)
    case "\$*" in
      *imgold111222*) echo "$old_created" ;;
      *imgnew333444*) echo "$recent_created" ;;
      *) exit 1 ;;
    esac
    ;;
  *" rmi "*)
    echo "docker \$*" >> "\$STUB_DIR/calls.log"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/docker-dangling-images.sh"

echo "== dry run: only the old dangling image is proposed =="
out="$(PATH="$bin_dir:$PATH" INSPECTOR_DRY_RUN=1 "$check")"
assert_true "would-delete for imgold111222" \
  "$(grep -q 'would-delete' <<<"$out" && grep -q 'imgold111222' <<<"$out" && echo true || echo false)"
assert_true "recent dangling image is not proposed" \
  "$(grep -q 'imgnew333444' <<<"$out" && echo false || echo true)"
assert_true "dry run issued no docker rmi" \
  "$([ ! -f "$bin_dir/calls.log" ] && echo true || echo false)"

echo "== real run: only the old dangling image is removed =="
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "deleted line for imgold111222" \
  "$(grep -q '"action":"deleted"' <<<"$out" && grep -q 'imgold111222' <<<"$out" && echo true || echo false)"
assert_true "docker rmi called for imgold111222 and nothing else" \
  "$(grep -q 'docker rmi imgold111222' "$bin_dir/calls.log" && [ "$(grep -c 'docker rmi' "$bin_dir/calls.log")" = "1" ] && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
