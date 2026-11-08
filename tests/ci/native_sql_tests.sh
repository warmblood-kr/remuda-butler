#!/usr/bin/env bash
# Native SQL 661 lane. Real SQLite only: any unavailable product file, wrong
# core, failed suite, or partial manifest is a failure, never a SKIP.
#
#   REMUDA_BIN=/path/to/native661/remuda tests/ci/native_sql_tests.sh
#
# This runner is intentionally outside tests/*.sh so the default shell lane
# cannot pick it up by glob. It owns exactly three real-SQL wrappers. The
# source/metadata disk wrappers stay on the default ae9 shell lane.
set -euo pipefail

REPO=${NATIVE_SQL_REPO:-$(cd "$(dirname "$0")/../.." && pwd -P)}
SQL_CORE=66138e39db21c8f7d069589c779bf6ac589f777c
SQL_CORE_SHORT=${SQL_CORE:0:7}
REMUDA_BIN=${REMUDA_BIN:-}
SUITE_TIMEOUT=${NATIVE_SQL_SUITE_TIMEOUT:-1800}
PROGRESS_CASES=19
ADVANCE_CASES=13
STORE_CASES=36

TMP=$(mktemp -d "${TMPDIR:-/tmp}/native-sql.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
LOG_DIR=${NATIVE_SQL_LOG_DIR:-${RUNNER_TEMP:-/tmp}/native-sql-661-logs}
mkdir -p "$LOG_DIR"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "native-sql-661: $*" >&2
  exit 1
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

[[ -n $REMUDA_BIN ]] || fail "REMUDA_BIN is required (native 661)"
[[ -x $REMUDA_BIN ]] || fail "REMUDA_BIN is not executable: $REMUDA_BIN"
version=$("$REMUDA_BIN" --version 2>/dev/null | tail -1) ||
  fail "cannot run $REMUDA_BIN --version"
case "$version" in
  *"$SQL_CORE"* | *"$SQL_CORE_SHORT"*) ;;
  *) fail "REMUDA_BIN is '$version', not native 661 ($SQL_CORE_SHORT)" ;;
esac

required=(
  extension.toml
  tests/lib/isolated_env.sh
  tests/lib/isolated_test.lua
  tests/lib/qa_inbox_sql_owner.lua
  tests/lib/qa_inbox_witness_oracle.lua
  tests/lib/qa_inbox_source_fixture.lua
  packages/butler/inbox_authority.lua
  packages/butler/inbox_authority_contract.lua
  packages/butler/inbox_progress.lua
  packages/butler/inbox_progress_contract.lua
  packages/butler/inbox_seal_contract.lua
  packages/butler/inbox_source.lua
  packages/butler/inbox_source_contract.lua
  packages/butler/mail.lua
  packages/butler/main.lua
  tests/butler_inbox_progress_contract.lua
  tests/butler_inbox_source_advance_contract.lua
  tests/butler_inbox_store_contract.lua
)
for file in "${required[@]}"; do
  [[ -f $REPO/$file ]] || fail "missing product/test file: $file"
done

migrations=(
  0002_inbox_progress
  0003_inbox_progress_root
  0004_inbox_progress_child_root
  0005_inbox_authority_full
  0006_inbox_auth_matrix_key
  0007_inbox_migration_tracked
  0008_inbox_migration_seal_cursor
  0009_inbox_seal_cursor_v1
)
for migration in "${migrations[@]}"; do
  for direction in up down; do
    file="packages/butler/migrations/inbox/$migration.$direction.sql"
    [[ -f $REPO/$file ]] || fail "missing migration: $file"
  done
done

store_manifest() {
  sed -n 's/^[[:space:]]*for case in \(.*\); do$/\1/p' \
    "$REPO/tests/butler_inbox_store_contract.sh" | head -1 | tr ' ' '\n' | sed '/^$/d'
}
expected_store=$(store_manifest)
expected_store_count=$(printf '%s\n' "$expected_store" | sed '/^$/d' | wc -l | tr -d ' ')
expected_store_unique=$(printf '%s\n' "$expected_store" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')
[[ $expected_store_count == "$STORE_CASES" ]] ||
  fail "wrapper Store manifest has $expected_store_count cases, expected $STORE_CASES"
[[ $expected_store_unique == "$STORE_CASES" ]] ||
  fail "wrapper Store manifest has $expected_store_unique unique cases, expected $STORE_CASES"
printf '%s\n' "$expected_store" | sed '/^$/d' | sort >"$LOG_DIR/store-expected.txt"

butler_commit=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
runner_hash=$(hash_file "${BASH_SOURCE[0]}")
echo "native-sql-661: provenance core=$version butler=$butler_commit runner_sha=$runner_hash"
echo "native-sql-661: log_dir=$LOG_DIR"

SUITE_LOG=
run_suite() {
  local name=$1 wrapper=$2
  local log="$LOG_DIR/$name.log"
  local rc=0
  local started=$SECONDS
  echo "native-sql-661: running $name"
  if command -v timeout >/dev/null 2>&1; then
    (
      unset REMUDA_SQL_CASE REMUDA_SQL_TEST_FILE
      REMUDA_BIN="$REMUDA_BIN" REMUDA_NO_UPDATE_CHECK=1 \
        REMUDA_SQL_CORE_REF="$SQL_CORE" \
        timeout "$SUITE_TIMEOUT" bash "$REPO/$wrapper"
    ) >"$log" 2>&1 || rc=$?
  else
    # No GNU timeout: this watchdog ends the wrapper PID only. It is not a
    # whole-process-tree deadline; the full log is retained either way.
    (
      unset REMUDA_SQL_CASE REMUDA_SQL_TEST_FILE
      exec env REMUDA_BIN="$REMUDA_BIN" REMUDA_NO_UPDATE_CHECK=1 \
        REMUDA_SQL_CORE_REF="$SQL_CORE" bash "$REPO/$wrapper"
    ) >"$log" 2>&1 &
    local pid=$!
    (
      sleep "$SUITE_TIMEOUT"
      kill -TERM "$pid" 2>/dev/null || true
      sleep 2
      kill -KILL "$pid" 2>/dev/null || true
    ) &
    local watchdog=$!
    wait "$pid" || rc=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
  fi
  if ((rc != 0)); then
    echo "native-sql-661: $name FAILED (rc=$rc); full log: $log" >&2
    tail -40 "$log" >&2 || true
    fail "$name failed; no retry and no SKIP"
  fi
  echo "native-sql-661: $name passed in $((SECONDS - started))s"
  SUITE_LOG=$log
}

run_suite progress tests/butler_inbox_progress_contract.sh
progress_markers=$(sed -n 's/^PASS native SQL progress \([0-9][0-9]*\) cases.*/\1/p' "$SUITE_LOG")
progress_count=$(printf '%s\n' "$progress_markers" | sed '/^$/d' | wc -l | tr -d ' ')
[[ $progress_count == 1 ]] ||
  fail "progress manifest: expected exactly one summary marker, saw $progress_count"
progress=$progress_markers
[[ $progress == "$PROGRESS_CASES" ]] ||
  fail "progress manifest: expected $PROGRESS_CASES cases, saw '${progress:-none}'"
echo "native-sql-661: progress manifest: PASS native SQL progress $progress cases" | tee "$LOG_DIR/progress-manifest.txt"

run_suite source-advance tests/butler_inbox_source_advance_contract.sh
advance_markers=$(sed -n 's/^PASS source advance \([0-9][0-9]*\) realSQL cases.*/\1/p' "$SUITE_LOG")
advance_count=$(printf '%s\n' "$advance_markers" | sed '/^$/d' | wc -l | tr -d ' ')
[[ $advance_count == 1 ]] ||
  fail "source advance manifest: expected exactly one summary marker, saw $advance_count"
advance=$advance_markers
[[ $advance == "$ADVANCE_CASES" ]] ||
  fail "source advance manifest: expected $ADVANCE_CASES cases, saw '${advance:-none}'"
echo "native-sql-661: source-advance manifest: PASS source advance $advance realSQL cases" | tee "$LOG_DIR/source-advance-manifest.txt"

run_suite store tests/butler_inbox_store_contract.sh
store_names=$(sed -n 's/^PASS actual SQL Store \(.*\) (not migration\/promotion proof)$/\1/p' "$SUITE_LOG")
printf '%s\n' "$store_names" | sed '/^$/d' | sort >"$LOG_DIR/store-actual.txt"
store_count=$(wc -l <"$LOG_DIR/store-actual.txt" | tr -d ' ')
if ! diff -u "$LOG_DIR/store-expected.txt" "$LOG_DIR/store-actual.txt" >"$LOG_DIR/store-diff.txt"; then
  cat "$LOG_DIR/store-diff.txt" >&2
  fail "Store manifest: PASS names differ from the wrapper's exact $STORE_CASES-case set"
fi
[[ $store_count == "$STORE_CASES" ]] ||
  fail "Store manifest: expected $STORE_CASES PASS lines, saw $store_count"
echo "native-sql-661: store manifest: $store_count exact case names" | tee "$LOG_DIR/store-manifest.txt"

echo "native-sql-661: PASS progress=$progress advance=$advance store=$store_count exact"
