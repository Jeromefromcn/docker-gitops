#!/usr/bin/env bash
# tests/test-docker-build-cache.sh — hermetic docker stub.
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
  *" builder du "*)
    printf 'ID                 RECLAIMABLE     SIZE\nabc                true            1.2GB\nTotal:\t\t1.2GB\n'
    ;;
  *" builder prune "*)
    echo "docker $*" >> "$STUB_DIR/calls.log"
    echo '3 cache entries deleted'
    echo 'Total reclaimed space: 1.1GB'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/docker-build-cache.sh"

echo "== dry run: reports the would-run prune, runs nothing =="
out="$(PATH="$bin_dir:$PATH" INSPECTOR_DRY_RUN=1 "$check")"
assert_true "would-delete line mentions current total 1.2GB" \
  "$(grep -q 'would-delete' <<<"$out" && grep -q '1.2GB' <<<"$out" && echo true || echo false)"
assert_true "would-run line contains the until filter" \
  "$(grep -q "until=604800s" <<<"$out" && echo true || echo false)"
assert_true "would-run line carries --all" \
  "$(grep -q -- '--all' <<<"$out" && echo true || echo false)"
assert_true "dry run issued no docker builder prune" \
  "$([ ! -f "$bin_dir/calls.log" ] && echo true || echo false)"

echo "== real run: prune invoked once with --all, reclaimed size reported =="
rm -f "$bin_dir/calls.log"
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "deleted line reports reclaimed 1.1GB" \
  "$(grep -q '"action":"deleted"' <<<"$out" && grep -q '1.1GB' <<<"$out" && echo true || echo false)"
assert_true "prune carried --all and the until filter" \
  "$(grep -q -- '--all --filter until=604800s' "$bin_dir/calls.log" && echo true || echo false)"
assert_true "docker builder prune called exactly once" \
  "$([ "$(grep -c 'builder prune' "$bin_dir/calls.log")" = "1" ] && echo true || echo false)"

echo "== nothing reclaimed: prune has no in-use leftovers, check stays silent =="
cat > "$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" info "*) exit 0 ;;
  *" builder du "*)
    printf 'ID                 RECLAIMABLE     SIZE\nabc                true            1.2GB\nTotal:\t\t1.2GB\n'
    ;;
  *" builder prune "*)
    echo "docker $*" >> "$STUB_DIR/calls.log"
    printf 'Total:\t0B\n'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"
rm -f "$bin_dir/calls.log"
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "no output when prune reclaims nothing" \
  "$([ -z "$out" ] && echo true || echo false)"
assert_true "prune still ran once" \
  "$([ "$(grep -c 'builder prune' "$bin_dir/calls.log")" = "1" ] && echo true || echo false)"

echo "== new-CLI format: prune output has no 'reclaimed' line, only trailing Total: =="
cat > "$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" info "*) exit 0 ;;
  *" builder du "*)
    printf 'ID                 RECLAIMABLE     SIZE\nabc                true            1.2GB\nTotal:\t\t1.2GB\n'
    ;;
  *" builder prune "*)
    echo "docker $*" >> "$STUB_DIR/calls.log"
    printf 'ID        RECLAIMABLE   SIZE      LAST ACCESSED\nabc       true          1.2GB     9 days ago\nTotal:\t1.2GB\n'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"
rm -f "$bin_dir/calls.log"
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "deleted line reports reclaimed 1.2GB from the trailing Total: line" \
  "$(grep -q '"action":"deleted"' <<<"$out" && grep -q '1.2GB' <<<"$out" && echo true || echo false)"

echo "== zero cache case: docker builder du reports 0B, check is silent =="
cat > "$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" info "*) exit 0 ;;
  *" builder du "*) printf 'Total:\t0B\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"
out="$(PATH="$bin_dir:$PATH" INSPECTOR_DRY_RUN=1 "$check")"
assert_true "no output when build cache is empty" \
  "$([ -z "$out" ] && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
