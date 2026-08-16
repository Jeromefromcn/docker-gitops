#!/usr/bin/env bash
# tests/lib.sh — shared helpers for phase-2 check tests. Sourced, never
# executed. Phase-1 test files keep their inline copies (untouched);
# phase-2 tests source this instead of duplicating the assert helper 12
# more times. The CLI-stub pattern: write fake docker/kubectl/crictl
# scripts into a temp dir, export STUB_DIR pointing at it, prepend the
# dir to PATH when invoking the check under test — same technique as
# phase 1's curl stub in test-inspect.sh. Destructive stub commands
# (rm/rmi/prune/delete) append their argv to $STUB_DIR/calls.log so
# tests can assert exactly what would have run.

failures=0

assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "true" ]; then
    echo "ok - $desc"
  else
    echo "FAIL - $desc"
    failures=$((failures + 1))
  fi
}

# Prints PASS/FAIL footer and exits 0/1 accordingly. Always the last
# line of a test script.
finish_tests() {
  echo "---"
  if [ "$failures" -eq 0 ]; then
    echo "PASS"
    exit 0
  else
    echo "FAIL: $failures check(s) failed"
    exit 1
  fi
}
