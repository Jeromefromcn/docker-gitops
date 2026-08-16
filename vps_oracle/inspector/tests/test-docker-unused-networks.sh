#!/usr/bin/env bash
# tests/test-docker-unused-networks.sh — hermetic docker stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
export STUB_DIR="$bin_dir"

cat > "$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" info "*) exit 0 ;;
  *" network ls --filter type=custom "*)
    printf 'usednet\norphanet\n'
    ;;
  *" network inspect "*)
    case "$*" in
      *usednet*) echo 1 ;;
      *orphanet*) echo 0 ;;
      *) exit 1 ;;
    esac
    ;;
  *" network rm "*)
    echo "docker $*" >> "$STUB_DIR/calls.log"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/docker-unused-networks.sh"

echo "== dry run: only the unattached network is proposed =="
out="$(PATH="$bin_dir:$PATH" INSPECTOR_DRY_RUN=1 "$check")"
assert_true "would-delete for orphanet" \
  "$(grep -q 'would-delete' <<<"$out" && grep -q 'orphanet' <<<"$out" && echo true || echo false)"
assert_true "usednet is not proposed" \
  "$(grep -q 'usednet' <<<"$out" && echo false || echo true)"
assert_true "dry run issued no docker network rm" \
  "$([ ! -f "$bin_dir/calls.log" ] && echo true || echo false)"

echo "== real run: only the unattached network is removed =="
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "deleted line for orphanet" \
  "$(grep -q '"action":"deleted"' <<<"$out" && grep -q 'orphanet' <<<"$out" && echo true || echo false)"
assert_true "docker network rm called for orphanet and nothing else" \
  "$(grep -q 'docker network rm orphanet' "$bin_dir/calls.log" && [ "$(grep -c 'network rm' "$bin_dir/calls.log")" = "1" ] && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
