#!/bin/sh
# The three test scripts must pin one core (#204): the shell, Rust and golden
# suites otherwise run against different cores without saying so.
#   scripts/check-core-pin.sh [ROOT]
set -eu
ROOT=${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
pins=$(cd "$ROOT" && grep -H '^CORE_REF=' tests/shell_tests.sh tests/rust_tests.sh tests/golden_guidance.sh)
[ "$(printf '%s\n' "$pins" | wc -l)" -eq 3 ] || { printf 'core pin: expected one CORE_REF= line in each of the three scripts, got:\n%s\n' "$pins" >&2; exit 1; }
[ "$(printf '%s\n' "$pins" | cut -d: -f2- | sort -u | wc -l)" -eq 1 ] || {
  printf 'core pin: the test scripts pin different cores:\n%s\nNext: set one CORE_REF in all three\n' "$pins" >&2; exit 1; }
echo "ok - one core pin: $(printf '%s\n' "$pins" | head -1 | cut -d: -f2-)"
