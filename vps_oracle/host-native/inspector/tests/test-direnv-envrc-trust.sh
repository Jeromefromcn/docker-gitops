#!/usr/bin/env bash
# tests/test-direnv-envrc-trust.sh — hermetic direnv stub.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

work_dir="$(mktemp -d)"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"

# Stub direnv driven by the current dir's fixture state. The check runs
# `cd $d && direnv export bash` for each group dir; the stub prints the
# same "is blocked" line real direnv prints to stderr when trust is
# revoked, and a benign export blob otherwise.
cat > "$bin_dir/direnv" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" export "*) ;;
  *) echo "unexpected argv: $*" >&2; exit 127 ;;
esac
if [ -f "$PWD/.envrc-blocked" ]; then
  echo "direnv: error $PWD/.envrc is blocked. Run \`direnv allow\` to approve its content" >&2
  exit 1
fi
echo "direnv: export +FOO"
echo "export FOO=bar"
exit 0
EOF
chmod +x "$bin_dir/direnv"

# For the "direnv not installed" case, build a PATH that mirrors the real
# one minus direnv: the check's own shebang (`#!/usr/bin/env bash`) and its
# helpers (`grep`, `timeout`, `cd`, `jq`) all still have to resolve. Symlink
# every executable on the real PATH except direnv into one dir.
mkdir -p "$work_dir/no_direnv"
while IFS=: read -r -d ':' p; do
  [ -d "$p" ] || continue
  for b in "$p"/*; do
    [ -x "$b" ] || continue
    base="$(basename "$b")"
    [ "$base" = "direnv" ] && continue
    [ -e "$work_dir/no_direnv/$base" ] || ln -s "$b" "$work_dir/no_direnv/$base" 2>/dev/null
  done
done < <(printf '%s:' "$PATH")

# Fake HOME so the check never touches the real ~/jerome|bridget|evidence.
stub_home="$work_dir/home"
mkdir -p "$stub_home/jerome" "$stub_home/bridget"

# jerome/.envrc is present but blocked; bridget/.envrc is present and
# allowed; evidence has no .envrc at all.
touch "$stub_home/jerome/.envrc" "$stub_home/jerome/.envrc-blocked"
touch "$stub_home/bridget/.envrc"

check="$SCRIPT_DIR/../checks/direnv-envrc-trust.sh"
# -u BASH_ENV: this host's settings.json sets BASH_ENV to direnv-load.sh,
# which sources `direnv` and would print "command not found" noise into
# the test's own non-interactive bash children.
run_check() { env -u BASH_ENV PATH="$bin_dir:$PATH" HOME="$stub_home" "$check"; }

echo "== a blocked .envrc alerts, naming the dir and the fix =="
out="$(run_check)"
assert_true "exactly one alert line" \
  "$([ "$(grep -c '"tier":"alert"' <<<"$out")" = "1" ] && echo true || echo false)"
assert_true "target names the blocked group dir" \
  "$(grep -q 'direnv .*jerome/.envrc' <<<"$out" && echo true || echo false)"
assert_true "detail is actionable (names 'direnv allow')" \
  "$(grep -q 'direnv allow' <<<"$out" && echo true || echo false)"
assert_true "does not alert on the allowed .envrc or the missing one" \
  "$(grep -q 'bridget' <<<"$out" && echo false || echo true)"

echo "== an allowed .envrc emits nothing =="
rm "$stub_home/jerome/.envrc-blocked"
out="$(run_check)"
assert_true "no result line when every present .envrc is allowed" \
  "$([ -z "$out" ] && echo true || echo false)"

echo "== missing direnv raises an alert naming the check =="
out="$(env -u BASH_ENV PATH="$work_dir/no_direnv" HOME="$stub_home" "$check" 2>/dev/null)"
assert_true "alert line naming the check when direnv is absent" \
  "$(grep -q 'check:direnv-envrc-trust.sh' <<<"$out" && echo true || echo false)"

echo "== report text stays English (Telegram reports carry no CJK) =="
touch "$stub_home/jerome/.envrc-blocked"
out="$(run_check)"
assert_true "no CJK characters in any emitted detail" \
  "$(grep -qP '[\x{4e00}-\x{9fff}]' <<<"$out" && echo false || echo true)"

rm -rf "$work_dir"
finish_tests