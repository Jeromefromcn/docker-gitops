#!/usr/bin/env bash
# vps_oracle2/inspector-checks/tests/test-oracle2-k3s-containerd-images.sh —
# hermetic: ssh is stubbed and dispatches on the remote crictl command.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../vps_oracle/host-native/inspector/tests/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
export STUB_DIR="$bin_dir"
export IMAGES_FILE="$work_dir/images.json"

# aaa is in use; ccc and ddd are unused; lab1 is unused but is a local-only
# ops-lab build (containerd reports it with a docker.io/ prefix) and must never
# be removed.
cat > "$IMAGES_FILE" <<'EOF'
{"images":[
 {"id":"sha256:aaa","size":100,"repoTags":["docker.io/library/busybox:1.36"]},
 {"id":"sha256:ccc","size":200,"repoTags":["quay.io/old/thing:1"]},
 {"id":"sha256:ddd","size":50,"repoTags":[]},
 {"id":"sha256:lab1","size":500,"repoTags":["docker.io/ops-lab/api-gateway:dev"]}
]}
EOF

cat > "$bin_dir/ssh" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" crictl ps -a -o json "*) echo '{"containers":[{"imageRef":"sha256:aaa"}]}' ;;
  *" crictl images -o json "*) cat "$IMAGES_FILE" ;;
  *" crictl rmi "*) echo "ssh $*" >> "$STUB_DIR/calls.log" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin_dir/ssh"

check="$SCRIPT_DIR/../checks/oracle2-k3s-containerd-images.sh"

echo "== dry run: unused images proposed, ops-lab excluded =="
out="$(PATH="$bin_dir:$PATH" INSPECTOR_DRY_RUN=1 "$check")"
assert_true "would-delete summary counts only the two non-protected unused images" \
  "$(grep -q '"target":"containerd unused images x2"' <<<"$out" && grep -q 'would-delete' <<<"$out" && echo true || echo false)"
assert_true "size total excludes the protected ops-lab image" \
  "$(grep -q 'total 250 B' <<<"$out" && echo true || echo false)"
assert_true "detail says protected images were kept" \
  "$(grep -q '1 protected' <<<"$out" && echo true || echo false)"
assert_true "dry run issued no crictl rmi" \
  "$([ ! -f "$bin_dir/calls.log" ] && echo true || echo false)"

echo "== real run: removes exactly the candidates, never ops-lab =="
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "deleted summary line" \
  "$(grep -q '"action":"deleted"' <<<"$out" && echo true || echo false)"
assert_true "one rmi call naming ccc and ddd" \
  "$([ "$(grep -c 'crictl rmi' "$bin_dir/calls.log")" = "1" ] && grep 'crictl rmi' "$bin_dir/calls.log" | grep -q 'ccc' && grep 'crictl rmi' "$bin_dir/calls.log" | grep -q 'ddd' && echo true || echo false)"
assert_true "ops-lab image id never passed to rmi" \
  "$(grep -q 'lab1' "$bin_dir/calls.log" && echo false || echo true)"
assert_true "in-use image never passed to rmi" \
  "$(grep -q 'aaa' "$bin_dir/calls.log" && echo false || echo true)"

echo "== only protected images unused: nothing to report =="
rm -f "$bin_dir/calls.log"
cat > "$IMAGES_FILE" <<'EOF'
{"images":[
 {"id":"sha256:aaa","size":100,"repoTags":["docker.io/library/busybox:1.36"]},
 {"id":"sha256:lab1","size":500,"repoTags":["docker.io/ops-lab/api-gateway:dev"]}
]}
EOF
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "no output" "$([ -z "$out" ] && echo true || echo false)"
assert_true "no rmi" "$([ ! -f "$bin_dir/calls.log" ] && echo true || echo false)"

echo "== oracle2 unreachable: alert, not silence =="
printf '#!/usr/bin/env bash\nexit 255\n' > "$bin_dir/ssh"
out="$(PATH="$bin_dir:$PATH" "$check")"
assert_true "unreachable raises an alert naming the check" \
  "$(grep -q '"target":"check:oracle2-k3s-containerd-images.sh"' <<<"$out" && grep -q '"tier":"alert"' <<<"$out" && echo true || echo false)"

rm -rf "$work_dir"
finish_tests
