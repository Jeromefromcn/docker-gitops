#!/usr/bin/env bash
# tests/test-docker-unused-volumes.sh — hermetic docker stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"

cat > "$bin_dir/docker" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" info "*) exit 0 ;;
  *" volume ls --filter dangling=true "*)
    printf '%s\n%s\n%s\n%s\n' \\
      "$(printf 'a%.0s' {1..64})" \\
      "$(printf 'b%.0s' {1..64})" \\
      "$(printf 'c%.0s' {1..64})" \\
      "old-project-data"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/docker-unused-volumes.sh"

echo "== anonymous volumes aggregate, named volumes list individually =="
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "one aggregate line for 3 anonymous volumes" \
  "$(grep -q 'anonymous volumes x3' <<<"$out" && echo true || echo false)"
assert_true "individual line for named volume old-project-data" \
  "$(grep -q '"target":"docker volume old-project-data"' <<<"$out" && echo true || echo false)"
assert_true "exactly two alert lines" \
  "$([ "$(grep -c '"tier":"alert"' <<<"$out")" = "2" ] && echo true || echo false)"
assert_true "no raw anonymous hash appears in the report" \
  "$(grep -q 'aaaaaaaa' <<<"$out" && echo false || echo true)"

rm -rf "$work_dir"
finish_tests
