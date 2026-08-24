#!/usr/bin/env bash
# tests/test-docker-restart-storms.sh — hermetic docker stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"

cat > "$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" info "*) exit 0 ;;
  *" ps -aq "*)
    printf 'id1\nid2\nid3\n'
    ;;
  *" inspect "*)
    case "$*" in
      *id1*) echo "/stormy 12 running" ;;
      *id2*) echo "/flappy 0 restarting" ;;
      *id3*) echo "/calm 2 running" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/docker-restart-storms.sh"

echo "== stormy (count 12) and flappy (restarting) alert; calm does not =="
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "alert line for stormy via restart count" \
  "$(grep -q '"tier":"alert"' <<<"$out" && grep -q 'stormy' <<<"$out" && echo true || echo false)"
assert_true "alert line for flappy via restarting state" \
  "$(grep -q 'flappy' <<<"$out" && echo true || echo false)"
assert_true "calm (count 2) is not flagged" \
  "$(grep -q 'calm' <<<"$out" && echo false || echo true)"
assert_true "exactly two alert lines" \
  "$([ "$(grep -c '"tier":"alert"' <<<"$out")" = "2" ] && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
