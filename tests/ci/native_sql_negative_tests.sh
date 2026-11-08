#!/usr/bin/env bash
# Real-binary negatives for the native SQL 661 lane. Each case runs the actual
# 661 remuda and the real wrappers inside a disposable copy; only that copy is
# mutated. A failure must be nonzero, emit no PASS marker, and carry the
# expected diagnostic for its own stimulus. These paths can hang, so each
# invocation is bounded.
#
#   REMUDA_BIN=/path/to/native661/remuda tests/ci/native_sql_negative_tests.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd -P)
SQL_CORE=66138e39db21c8f7d069589c779bf6ac589f777c
SQL_CORE_SHORT=${SQL_CORE:0:7}
REMUDA_BIN=${REMUDA_BIN:-}
NEGATIVE_TIMEOUT=${NATIVE_SQL_NEGATIVE_TIMEOUT:-300}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/native-sql-negative.XXXXXX")
ROOT=$(cd "$ROOT" && pwd -P)
LOG_DIR=${NATIVE_SQL_LOG_DIR:-${RUNNER_TEMP:-/tmp}/native-sql-661-logs}
mkdir -p "$LOG_DIR"
trap 'rm -rf "$ROOT"' EXIT

fail() {
  echo "native-sql-negative: $*" >&2
  exit 1
}

[[ -n $REMUDA_BIN ]] || fail "REMUDA_BIN is required (native 661)"
[[ -x $REMUDA_BIN ]] || fail "REMUDA_BIN is not executable: $REMUDA_BIN"
version=$("$REMUDA_BIN" --version 2>/dev/null | tail -1) ||
  fail "cannot run $REMUDA_BIN --version"
case "$version" in
  *"$SQL_CORE"* | *"$SQL_CORE_SHORT"*) ;;
  *) fail "REMUDA_BIN is '$version', not native 661 ($SQL_CORE_SHORT)" ;;
esac
echo "native-sql-negative: provenance core=$version"

disposable() {
  local name=$1
  local copy=$ROOT/$name
  mkdir -p "$copy"
  cp -R "$REPO/extension.toml" "$REPO/tests" "$REPO/packages" "$copy/"
  printf '%s\n' "$copy"
}

run_negative() { # name copy case wrapper marker
  local name=$1 copy=$2 case=$3 wrapper=$4 marker=$5
  local log="$LOG_DIR/negative-$name.log"
  local rc=0
  if command -v timeout >/dev/null 2>&1; then
    (
      unset REMUDA_SQL_CASE REMUDA_SQL_TEST_FILE
      cd "$copy"
      if [[ -n $case ]]; then export REMUDA_SQL_CASE="$case"; fi
      exec env REMUDA_BIN="$REMUDA_BIN" REMUDA_NO_UPDATE_CHECK=1 \
        REMUDA_SQL_CORE_REF="$SQL_CORE" timeout "$NEGATIVE_TIMEOUT" bash "$wrapper"
    ) >"$log" 2>&1 || rc=$?
  else
    (
      unset REMUDA_SQL_CASE REMUDA_SQL_TEST_FILE
      cd "$copy"
      if [[ -n $case ]]; then export REMUDA_SQL_CASE="$case"; fi
      exec env REMUDA_BIN="$REMUDA_BIN" REMUDA_NO_UPDATE_CHECK=1 \
        REMUDA_SQL_CORE_REF="$SQL_CORE" bash "$wrapper"
    ) >"$log" 2>&1 &
    local pid=$!
    (
      sleep "$NEGATIVE_TIMEOUT"
      kill -TERM "$pid" 2>/dev/null || true
      sleep 2
      kill -KILL "$pid" 2>/dev/null || true
    ) &
    local watchdog=$!
    wait "$pid" || rc=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
  fi
  if ((rc == 0)); then
    echo "native-sql-negative: $name unexpectedly passed; log: $log" >&2
    tail -20 "$log" >&2 || true
    fail "$name did not fail"
  fi
  if ((rc == 124 || rc == 137 || rc == 143)); then
    echo "native-sql-negative: $name hit the ${NEGATIVE_TIMEOUT}s bound; log: $log" >&2
    fail "$name timed out instead of proving its diagnostic"
  fi
  if grep -q '^PASS ' "$log"; then
    echo "native-sql-negative: $name emitted a PASS marker; log: $log" >&2
    grep '^PASS ' "$log" >&2 || true
    fail "$name reported PASS while failing"
  fi
  grep -Fq "$marker" "$log" || {
    echo "native-sql-negative: $name missing diagnostic '$marker'; log: $log" >&2
    tail -20 "$log" >&2 || true
    fail "$name failed for the wrong reason"
  }
  echo "native-sql-negative: $name failed as required (rc=$rc, marker '$marker'); log: $log"
}

# The required marker must name the actual SQLite diagnostic, and the
# unexpected-success branch must be rejected by it. Otherwise a successful
# handle (wrong behavior) could satisfy a generic marker.
DB_OPEN_MARKER='EXPECTED_DB_OPEN_REJECTION: sql: near "THIS": syntax error in THIS IS NOT SQL'
MIGRATION_MARKER='native inbox open failed sql: near "THIS": syntax error in THIS IS NOT SQL'
UNEXPECTED_OPEN='UNEXPECTED_DB_OPEN_SUCCESS: invalid migration unexpectedly opened'
case "$UNEXPECTED_OPEN" in
  *"$DB_OPEN_MARKER"*)
    fail "unexpected-success branch can satisfy the db-open rejection marker" ;;
esac
case "$UNEXPECTED_OPEN" in
  *"$MIGRATION_MARKER"*)
    fail "unexpected-success branch can satisfy the migration marker" ;;
esac
echo "native-sql-negative: unexpected-success prefix cannot satisfy either required marker"

# Valid module, but initialize calls the real host.db.open and asserts the
# rejection caused by an invalid SQL migration in this disposable copy.
copy=$(disposable db-open-rejected)
printf 'THIS IS NOT SQL;\n' >"$copy/packages/butler/migrations/inbox/0005_inbox_authority_full.up.sql"
cat >"$copy/tests/lib/qa_inbox_sql_owner.lua" <<'EOF'
local host=getmetatable(_G).__index.remuda
assert(assert(loadfile('tests/lib/isolated_test.lua'))()(host))
return {api='remuda-module-v1',state_version=1,
  initialize=function()
    local handle,err=host.db.open('inbox',{migrations=true})
    if handle then
      pcall(handle.close,handle)
      error('UNEXPECTED_DB_OPEN_SUCCESS: invalid migration unexpectedly opened')
    end
    error('EXPECTED_DB_OPEN_REJECTION: '..tostring(err))
  end,
  start=function() return true end,
  stop=function() end}
EOF
run_negative db-open-rejected "$copy" "" tests/butler_inbox_progress_contract.sh "$DB_OPEN_MARKER"

# Valid module return; the initialize callback itself fails. This proves an
# initialize error inside the real module lifecycle propagates.
copy=$(disposable owner-init-assert)
cat >"$copy/tests/lib/qa_inbox_sql_owner.lua" <<'EOF'
local host=getmetatable(_G).__index.remuda
assert(assert(loadfile('tests/lib/isolated_test.lua'))()(host))
return {api='remuda-module-v1',state_version=1,
  initialize=function() error('EXPECTED_OWNER_INIT: initialize callback failed') end,
  start=function() return true end,
  stop=function() end}
EOF
run_negative owner-init-assert "$copy" "" tests/butler_inbox_progress_contract.sh EXPECTED_OWNER_INIT

# Real owner module; the actual suite entry asserts.
copy=$(disposable suite-assert)
cat >"$copy/tests/butler_inbox_progress_contract.lua" <<'EOF'
assert(false, 'EXPECTED_SUITE_ASSERT: actual entry assertion')
EOF
run_negative suite-assert "$copy" "" tests/butler_inbox_progress_contract.sh EXPECTED_SUITE_ASSERT

# Invalid SQL in migration 0009 must fail in actual native migration execution,
# through the real owner module's db.open assertion.
copy=$(disposable broken-migration)
printf 'THIS IS NOT SQL;\n' >"$copy/packages/butler/migrations/inbox/0009_inbox_seal_cursor_v1.up.sql"
run_negative broken-migration "$copy" "" tests/butler_inbox_progress_contract.sh "$MIGRATION_MARKER"

echo "native-sql-negative: PASS all real-binary failure cases propagated"
