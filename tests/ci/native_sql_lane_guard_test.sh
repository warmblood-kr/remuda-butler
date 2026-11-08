#!/usr/bin/env bash
# Registration/event guard for the native SQL 661 lane. This is a static check:
# it proves the job exists only on push-to-main, pins 661, runs the dedicated
# runner, and that the default ae9 lane keeps its own ownership.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd -P)
WORKFLOW=$REPO/.github/workflows/tests.yml
RUNNER=$REPO/tests/ci/native_sql_tests.sh
SHELL_SUITE=$REPO/tests/shell_tests.sh

fail() {
  echo "native-sql-lane-guard: $*" >&2
  exit 1
}

[[ -f $WORKFLOW ]] || fail "missing $WORKFLOW"
[[ -f $RUNNER ]] || fail "missing $RUNNER"
[[ -f $SHELL_SUITE ]] || fail "missing $SHELL_SUITE"

job=$(awk '
  /^  native-sql-661:/ { inside = 1; next }
  inside && /^  [A-Za-z0-9_-]+:/ { exit }
  inside { print }
' "$WORKFLOW")
[[ -n $job ]] || fail "native-sql-661 job is not registered"

grep -Fq "github.event_name == 'push' && github.ref == 'refs/heads/main'" <<<"$job" ||
  fail "native-sql-661 is not gated to push-to-main"
for forbidden in pull_request workflow_dispatch merge_group; do
  if grep -q "$forbidden" <<<"$job"; then
    fail "native-sql-661 must not run on $forbidden"
  fi
done
grep -q '66138e39db21c8f7d069589c779bf6ac589f777c' <<<"$job" ||
  fail "native-sql-661 does not pin native 661"
grep -q 'tests/ci/native_sql_tests.sh' <<<"$job" ||
  fail "native-sql-661 does not run the dedicated runner"
grep -q 'tests/ci/native_sql_negative_tests.sh' <<<"$job" ||
  fail "native-sql-661 does not run the real-binary negatives"
grep -q 'runner.arch' <<<"$job" ||
  fail "cache key omits the runner architecture"
grep -q 'steps.toolchain.outputs.version' <<<"$job" ||
  fail "cache key omits the toolchain identity"
grep -q "hashFiles('remuda-core/Cargo.lock')" <<<"$job" ||
  fail "cache key omits remuda-core/Cargo.lock"
grep -q -- '-debug' <<<"$job" ||
  fail "cache key omits the build profile"
if grep -q 'restore-keys' <<<"$job"; then
  fail "cache restore fallback crosses the toolchain/lock/profile identity"
fi
grep -q 'upload-artifact@v4' <<<"$job" ||
  fail "native-sql-661 does not retain logs as an artifact"
grep -q 'if: always()' <<<"$job" ||
  fail "native-sql-661 artifact upload is not always"
if grep -q 'needs:' <<<"$job"; then
  fail "native-sql-661 must be independent (no needs:)"
fi

for existing in rust golden shell path-windows contract native-sql-661; do
  grep -Eq "^  ${existing}:" "$WORKFLOW" || fail "job $existing disappeared"
done
grep -q 'ae9ce9513941' "$REPO/tests/core_ref.sh" ||
  fail "CORE_REF is no longer ae9; this lane must not move the common pin"

for wrapper in \
  butler_inbox_progress_contract.sh \
  butler_inbox_source_advance_contract.sh \
  butler_inbox_store_contract.sh; do
  grep -Fq "$wrapper" "$SHELL_SUITE" ||
    fail "shell suite does not classify $wrapper"
  grep -Fq "$wrapper" "$RUNNER" ||
    fail "runner does not own $wrapper"
done
grep -Fq 'native SQL 661 lane' "$SHELL_SUITE" ||
  fail "shell suite lacks the SQL delegation note"
grep -Fq 'native_sql_lane_guard_test.sh' "$SHELL_SUITE" ||
  fail "shell policy lane does not run the registration guard"
grep -Fq 'native_sql_tests_selftest.sh' "$SHELL_SUITE" ||
  fail "shell policy lane does not run the fail-closed self-test"

for wrapper in butler_inbox_source_contract.sh butler_mail_metadata_contract.sh; do
  if grep -Fq "$wrapper" "$RUNNER"; then
    fail "$wrapper belongs to the ae9 shell lane, not the SQL runner"
  fi
done

grep -Fq 'REMUDA_SQL_CORE_REF="$SQL_CORE"' "$RUNNER" ||
  fail "runner does not force the SQL pin per suite"
grep -Fq 'store-expected.txt' "$RUNNER" ||
  fail "runner does not compare the exact Store case set"
grep -Fq 'expected exactly one summary marker' "$RUNNER" ||
  fail "runner does not require singleton progress/advance markers"

if grep -Eq 'run_suite .*\|\||native_sql_tests\.sh.*\|\|' "$RUNNER"; then
  fail "runner contains a silent-success fallback"
fi

echo "native-sql-lane-guard: PASS"
