#!/usr/bin/env bash
# tests/test-k3s-containerd-images.sh — hermetic: sudo passes through to
# a stubbed crictl.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
export STUB_DIR="$bin_dir"

cat > "$bin_dir/sudo" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-n" ] && shift
exec "$@"
EOF
cat > "$bin_dir/crictl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" ps -a -o json "*)
    echo '{"containers":[{"imageRef":"sha256:aaa"},{"imageRef":"sha256:bbb"}]}'
    ;;
  *" images -o json "*)
    echo '{"images":[{"id":"sha256:aaa","size":100},{"id":"sha256:bbb","size":50},{"id":"sha256:ccc","size":200}]}'
    ;;
  *" rmi --prune "*)
    echo "crictl $*" >> "$STUB_DIR/calls.log"
    echo "Deleted: sha256:ccc"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/sudo" "$bin_dir/crictl"

check="$SCRIPT_DIR/../checks/k3s-containerd-images.sh"

echo "== dry run: only the unreferenced image counts =="
out="$(PATH="$bin_dir:$PATH" INSPECTOR_DRY_RUN=1 "$check")"
assert_true "would-delete summary says x1" \
  "$(grep -q '"target":"containerd unused images x1"' <<<"$out" && echo true || echo false)"
assert_true "detail carries the summed size of only the unreferenced image" \
  "$(grep -q 'total 200 bytes' <<<"$out" && echo true || echo false)"
assert_true "dry run issued no crictl rmi" \
  "$([ ! -f "$bin_dir/calls.log" ] && echo true || echo false)"

echo "== real run: prune invoked once =="
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "deleted summary line" \
  "$(grep -q '"action":"deleted"' <<<"$out" && echo true || echo false)"
assert_true "crictl rmi --prune called exactly once" \
  "$([ "$(grep -c 'rmi --prune' "$bin_dir/calls.log")" = "1" ] && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
