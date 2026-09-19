#!/usr/bin/env bash
# vps_gcp/inspector-checks/tests/test-gcp-docker-restart-storms.sh — hermetic docker stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../vps_oracle/host-native/inspector/tests/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"

# Stub records the DOCKER_HOST it was called with; STUB_DOWN=1 makes info fail.
cat > "$bin_dir/docker" <<'STUB'
#!/usr/bin/env bash
echo "$DOCKER_HOST" >> "$STUB_DIR/hosts.log"
case " $* " in
  *" info "*) [ -n "${STUB_DOWN:-}" ] && exit 1; exit 0 ;;
  *" ps -aq "*) printf 'id1\nid2\n' ;;
  *" inspect "*)
    case "$*" in
      *id1*) echo "/stormy 12 running" ;;
      *id2*) echo "/calm 1 running" ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$bin_dir/docker"

check="$SCRIPT_DIR/../checks/gcp-docker-restart-storms.sh"
export STUB_DIR="$work_dir"

echo "== alerts target the gcp daemon =="
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "stormy flagged" \
  "$(grep -q 'docker container stormy' <<<"$out" && echo true || echo false)"
assert_true "calm not flagged" \
  "$(grep -q 'calm' <<<"$out" && echo false || echo true)"
assert_true "docker called with the gcp DOCKER_HOST" \
  "$(grep -qx 'ssh://ubuntu@vps-gcp' "$work_dir/hosts.log" && echo true || echo false)"
assert_true "never emits deleted/would-delete" \
  "$(grep -qE 'deleted|would-delete' <<<"$out" && echo false || echo true)"

echo "== unreachable daemon alerts =="
out="$(STUB_DOWN=1 PATH="$bin_dir:$PATH" "$check")"
assert_true "unreachable daemon alerts" \
  "$(grep -q '"tier":"alert"' <<<"$out" && grep -q 'check:gcp-docker-restart-storms.sh' <<<"$out" && grep -q unreachable <<<"$out" && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
