#!/usr/bin/env bash
# Fail-closed self-test for tests/ci/native_sql_tests.sh. Everything runs in
# private temp trees with stub wrappers and a fake binary; no daemon, no DB, no
# real product state is touched. This is not native-SQL proof; the real-binary
# negatives live in tests/ci/native_sql_negative_tests.sh.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd -P)
RUNNER=$REPO/tests/ci/native_sql_tests.sh
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/native-sql-selftest.XXXXXX")
ROOT=$(cd "$ROOT" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

fail() {
  echo "native-sql-selftest: $*" >&2
  exit 1
}

write_file() {
  local path=$1
  mkdir -p "$(dirname "$path")"
  : >"$path"
}

store_names=$(
  sed -n 's/^[[:space:]]*for case in \(.*\); do$/\1/p' \
    "$REPO/tests/butler_inbox_store_contract.sh" | head -1
)
[[ -n $store_names ]] || fail "cannot read the Store case manifest from the wrapper"
store_count=$(printf '%s\n' "$store_names" | tr ' ' '\n' | sed '/^$/d' | wc -l | tr -d ' ')
[[ $store_count == 36 ]] || fail "Store wrapper manifest has $store_count cases, expected 36"

make_repo() {
  local repo=$1
  mkdir -p "$repo/tests/lib" "$repo/tests/ci" "$repo/bin" \
    "$repo/packages/butler/migrations/inbox"
  write_file "$repo/extension.toml"
  for file in isolated_env.sh isolated_test.lua qa_inbox_sql_owner.lua \
    qa_inbox_witness_oracle.lua qa_inbox_source_fixture.lua; do
    write_file "$repo/tests/lib/$file"
  done
  for file in inbox_authority.lua inbox_authority_contract.lua inbox_progress.lua \
    inbox_progress_contract.lua inbox_seal_contract.lua inbox_source.lua \
    inbox_source_contract.lua mail.lua main.lua; do
    write_file "$repo/packages/butler/$file"
  done
  for file in butler_inbox_progress_contract.lua \
    butler_inbox_source_advance_contract.lua butler_inbox_store_contract.lua; do
    write_file "$repo/tests/$file"
  done
  for migration in 0002_inbox_progress 0003_inbox_progress_root \
    0004_inbox_progress_child_root 0005_inbox_authority_full \
    0006_inbox_auth_matrix_key 0007_inbox_migration_tracked \
    0008_inbox_migration_seal_cursor 0009_inbox_seal_cursor_v1; do
    write_file "$repo/packages/butler/migrations/inbox/$migration.up.sql"
    write_file "$repo/packages/butler/migrations/inbox/$migration.down.sql"
  done
  cat >"$repo/bin/remuda" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then
  echo "remuda 0.1.0+git.${STUB_VERSION:-66138e39}0000"
  exit 0
fi
exit 0
EOF
  chmod +x "$repo/bin/remuda"
  cat >"$repo/tests/butler_inbox_progress_contract.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${STUB_PROGRESS:-19}" in
  sleep) exec sleep 30 ;;
  fail) echo "forced progress failure" >&2; exit 1 ;;
  duplicate)
    echo "PASS native SQL progress 19 cases (stub)"
    echo "PASS native SQL progress 19 cases (stub)"
    ;;
  *) echo "PASS native SQL progress ${STUB_PROGRESS:-19} cases (stub)" ;;
esac
EOF
  cat >"$repo/tests/butler_inbox_source_advance_contract.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${STUB_ADVANCE:-13}" in
  fail) echo "forced advance failure" >&2; exit 1 ;;
  *) echo "PASS source advance ${STUB_ADVANCE:-13} realSQL cases; stub" ;;
esac
EOF
  cat >"$repo/tests/butler_inbox_store_contract.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
for case in $store_names; do
  :
done
names=($store_names)
case "\${STUB_STORE:-36}" in
  fail) echo "forced store failure" >&2; exit 1 ;;
  dup)
    for i in \$(seq 0 34); do
      echo "PASS actual SQL Store \${names[\$i]} (not migration/promotion proof)"
    done
    echo "PASS actual SQL Store \${names[0]} (not migration/promotion proof)"
    ;;
  wrong)
    for i in \$(seq 0 34); do
      echo "PASS actual SQL Store \${names[\$i]} (not migration/promotion proof)"
    done
    echo "PASS actual SQL Store invented_unknown_case (not migration/promotion proof)"
    ;;
  missing)
    for i in \$(seq 0 34); do
      echo "PASS actual SQL Store \${names[\$i]} (not migration/promotion proof)"
    done
    ;;
  *)
    for name in "\${names[@]}"; do
      echo "PASS actual SQL Store \$name (not migration/promotion proof)"
    done
    ;;
esac
EOF
  chmod +x "$repo/tests/"*_contract.sh
}

run_runner() { # repo log env...
  local repo=$1 log=$2
  shift 2
  set +e
  env "$@" NATIVE_SQL_REPO="$repo" REMUDA_BIN="$repo/bin/remuda" \
    NATIVE_SQL_LOG_DIR="$ROOT/logs" bash "$RUNNER" >"$log" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

expect_pass() {
  local name=$1
  shift
  local repo=$ROOT/repo-$name
  local log=$ROOT/$name.log
  make_repo "$repo"
  run_runner "$repo" "$log" "$@" || {
    cat "$log" >&2
    fail "$name unexpectedly failed"
  }
  grep -Fq 'PASS progress=19 advance=13 store=36 exact' "$log" ||
    fail "$name did not report the exact manifest"
  echo "PASS $name"
}

expect_fail() {
  local name=$1 pattern=$2
  shift 2
  local repo=$ROOT/repo-$name
  local log=$ROOT/$name.log
  make_repo "$repo"
  case "$name" in
    missing-product) rm "$repo/packages/butler/inbox_progress.lua" ;;
    migration-gap) rm "$repo/packages/butler/migrations/inbox/0005_inbox_authority_full.up.sql" ;;
  esac
  if run_runner "$repo" "$log" "$@"; then
    cat "$log" >&2
    fail "$name unexpectedly passed"
  fi
  grep -Fq "$pattern" "$log" || {
    cat "$log" >&2
    fail "$name missing expected message: $pattern"
  }
  echo "PASS $name"
}

expect_pass positive
expect_pass polluted-selectors \
  REMUDA_SQL_CASE=bogus_case REMUDA_SQL_TEST_FILE=bogus.lua \
  REMUDA_SQL_CORE_REF=ae9ce9513941

expect_fail missing-product "missing product/test file"
expect_fail wrong-pin "not native 661" STUB_VERSION=ae9ce951
expect_fail forced-assert "progress failed" STUB_PROGRESS=fail
expect_fail progress-partial "progress manifest: expected 19" STUB_PROGRESS=18
expect_fail progress-duplicate "expected exactly one summary marker" STUB_PROGRESS=duplicate
expect_fail store-duplicate "Store manifest: PASS names differ" STUB_STORE=dup
expect_fail store-wrong-name "Store manifest: PASS names differ" STUB_STORE=wrong
expect_fail store-missing "Store manifest: PASS names differ" STUB_STORE=missing
expect_fail migration-gap "missing migration"
expect_fail watchdog "progress failed" NATIVE_SQL_SUITE_TIMEOUT=1 STUB_PROGRESS=sleep

echo "native-sql-selftest: PASS"
