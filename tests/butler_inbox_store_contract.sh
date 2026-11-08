#!/usr/bin/env bash
# Native SQL is mandatory: this gate must never turn unavailable into SKIP.
set -euo pipefail
if [[ -z ${REMUDA_SQL_CASE:-} ]]; then
  failed=0
  for case in migration_seal_v8_upgrade migration_seal_legacy_schema migration_seal_identity migration_seal_missing_capture migration_seal_short_read migration_seal_zero_done_shrink migration_seal_captured_absence migration_seal_zero_budget migration_seal_done_shrink migration_seal_default_aggregate migration_seal_total_budget migration_seal_recipient_budget migration_staging_fairness migration_seal_default_linear migration_seal_exact_fit migration_seal_resume migration_store_fairness migration_sealed_offsets migration_seal_read_budget migration_tracking_gate sql_tail_match sql_authority_match snapshot_ack_fences refused_lease_cleanup sql_guard_required owner_registry close_replacement alias_owner new_marker tracked_db_down external_idempotency external_conflict external_key_scope external_lost_commit sql_metadata_render sql_root_binding; do
    if ! REMUDA_SQL_CASE="$case" bash "$0"; then failed=$((failed + 1)); fi
  done
  (( failed == 0 )) || { echo "Store contract failures: $failed" >&2; exit 1; }
  exit 0
fi
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
REMUDA_BIN=${REMUDA_BIN:-remuda}
CORE_REF=${REMUDA_SQL_CORE_REF:-66138e39db21c8f7d069589c779bf6ac589f777c}
source "$REPO/tests/core_ref.sh"
core_ref_check
source "$REPO/tests/lib/isolated_env.sh"
isolated_env_prepare biauth biauth
export REMUDA_SQL_TEST_FILE=tests/butler_inbox_store_contract.lua
export REMUDA_NO_UPDATE_CHECK=1
mkdir -p "$XDG_DATA_HOME/remuda/mods/butler"
cp "$REPO/extension.toml" "$XDG_DATA_HOME/remuda/mods/butler/extension.toml"
cp -R "$REPO/packages" "$XDG_DATA_HOME/remuda/mods/butler/packages"
cp "$REPO/tests/lib/qa_inbox_sql_owner.lua" "$XDG_DATA_HOME/remuda/mods/butler/packages/butler/init.lua"
if [[ ${REMUDA_SQL_CASE} == migration_seal_v8_upgrade ]]; then
  rm "$XDG_DATA_HOME/remuda/mods/butler/packages/butler/migrations/inbox/0009_inbox_seal_cursor_v1."*.sql
fi
cd "$REPO"
"$REMUDA_BIN" -s "$S" daemon >"$T/daemon.log" 2>&1 &
ISOLATED_DAEMON_PID=$!
for _ in $(seq 50); do [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] && break; sleep 0.1; done
[[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] || { cat "$T/daemon.log" >&2; exit 1; }
isolated_env_check_daemon || { cat "$T/daemon.log" >&2; exit 1; }
if [[ ${REMUDA_SQL_CASE} == migration_seal_default_linear ]]; then
  ( sleep 2; kill -KILL "$ISOLATED_DAEMON_PID" 2>/dev/null ) &
  QA_WATCHDOG_PID=$!
  set +e
  "$REMUDA_BIN" -s "$S" exec butler
  QA_RESULT=$?
  kill "$QA_WATCHDOG_PID" 2>/dev/null
  wait "$QA_WATCHDOG_PID" 2>/dev/null
  exit "$QA_RESULT"
fi
"$REMUDA_BIN" -s "$S" exec butler
