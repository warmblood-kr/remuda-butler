#!/bin/sh
# The shell, Rust and golden suites must run against one core (#204): the pin
# lives once in tests/core_ref.sh and each script sources it instead of
# assigning its own CORE_REF.
#   scripts/check-core-pin.sh [ROOT]
# Counted per file, never in aggregate: tests/core_ref.sh must hold exactly one
# CORE_REF=, each script zero. Fails with a message (not silently) on 2 or 0
# assignments in core_ref.sh, or any in a script (e.g. 2/0/1 or 0/0/0 spread).
set -eu
ROOT=${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
cd "$ROOT"
fail() { printf 'core pin: %s\nNext: keep one CORE_REF= in tests/core_ref.sh and source it from the three scripts\n' "$1" >&2; exit 1; }
count() { grep -c "$1" "$2" || true; }
n=$(count '^CORE_REF=' tests/core_ref.sh)
[ "$n" -eq 1 ] || fail "tests/core_ref.sh has $n CORE_REF= assignments, want exactly 1"
for f in tests/shell_tests.sh tests/rust_tests.sh tests/golden_guidance.sh; do
  n=$(count '^CORE_REF=' "$f")
  [ "$n" -eq 0 ] || fail "$f assigns CORE_REF= itself ($n times); it must source tests/core_ref.sh"
  [ "$(count 'tests/core_ref.sh' "$f")" -ge 1 ] || fail "$f does not source tests/core_ref.sh"
done
echo "ok - one core pin: $(grep '^CORE_REF=' tests/core_ref.sh)"
