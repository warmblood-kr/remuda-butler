#!/usr/bin/env bash
# Real relay migration 0003 check: old 0002 upgrade, unresolved-work downgrade
# gate, archive preservation, and atomic refusal when an archive name already
# exists.
#
# It starts from a populated 0001/0002 database (not a fresh DB that applies
# 0003 first), upgrades it, and proves the migration-runner version/history.
# The down path refuses while unresolved inbound/outbox/dedupe work exists; only
# completed history is archived. A second down cannot overwrite the archive and
# must roll back atomically.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
REMUDA_BIN=${REMUDA_BIN:-remuda}
CORE_REF=${REMUDA_SQL_CORE_REF:-b713e3e31a5f04e9812d19742984fe4c4c05fe1f}
source "$REPO/tests/core_ref.sh"
core_ref_check
source "$REPO/tests/lib/isolated_env.sh"
isolated_env_prepare relaythree relaythree
export REMUDA_NO_UPDATE_CHECK=1
MOD="$XDG_DATA_HOME/remuda/mods/butler"
mkdir -p "$MOD"
cp -R "$REPO/packages" "$MOD/packages"
cp "$REPO/tests/lib/qa_relay_0003_owner.lua" "$MOD/packages/butler/init.lua"
db="$HOME/.local/state/remuda/db/butler/relay.db"

install_old_only() {
  cp "$REPO/tests/fixtures/relay-0002-extension.toml" "$MOD/extension.toml"
  rm -f "$MOD/packages/butler/migrations/relay/0003_relay_bounded."*
}
install_full() {
  cp "$REPO/extension.toml" "$MOD/extension.toml"
  cp "$REPO/packages/butler/migrations/relay/0003_relay_bounded."* \
    "$MOD/packages/butler/migrations/relay/"
}

start_daemon() {
  RELAY3_PHASE=$1 "$REMUDA_BIN" -s "$S" daemon >"$T/daemon.log" 2>&1 &
  ISOLATED_DAEMON_PID=$!
  for _ in $(seq 50); do
    [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] && break
    sleep 0.1
  done
  [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] || { cat "$T/daemon.log" >&2; exit 1; }
  isolated_env_check_daemon
}
stop_daemon() {
  "$REMUDA_BIN" -s "$S" stop -f --yes >/dev/null 2>&1 || true
  wait "$ISOLATED_DAEMON_PID" 2>/dev/null || true
  ISOLATED_DAEMON_PID=
}
run_phase() {
  "$REMUDA_BIN" -s "$S" exec butler
}
q() {
  sqlite3 -readonly "$db" "$1"
}
cleanup() {
  stop_daemon
  isolated_env_cleanup
}
trap cleanup EXIT

# Start from a real populated 0001/0002 database.
install_old_only
start_daemon old
run_phase
stop_daemon
[[ $(sqlite3 "$db" "PRAGMA user_version") == 2 ]] || { echo "old fixture is not at 0002" >&2; exit 1; }
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM _remuda_migrations") == 2 ]] \
  || { echo "old fixture history is not 2 steps" >&2; exit 1; }
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM reply_receipts WHERE reply_id='r-old'") == 1 ]] \
  || { echo "old receipt missing" >&2; exit 1; }

# Install 0003 and upgrade the populated database through the real runner.
install_full
start_daemon upgrade
run_phase
stop_daemon
[[ $(sqlite3 "$db" "PRAGMA user_version") == 3 ]] || { echo "upgrade did not reach 0003" >&2; exit 1; }
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM _remuda_migrations") == 3 ]] \
  || { echo "upgrade history is not 3 steps" >&2; exit 1; }
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM reply_receipts WHERE reply_id='r-old'") == 1 ]] \
  || { echo "upgrade lost the old receipt" >&2; exit 1; }
[[ $(sqlite3 "$db" "SELECT value FROM relay_meta WHERE key='authority'") == shadow ]] \
  || { echo "authority is not shadow" >&2; exit 1; }
echo "relay 0003 old->upgrade: populated 0002 preserved"

# Resolved-only downgrade must be reachable; unresolved work must block it.
start_daemon unresolved
run_phase
if "$REMUDA_BIN" -s "$S" db downgrade butler relay 2 --yes >/dev/null 2>&1; then
  echo "downgrade with unresolved work must fail" >&2
  exit 1
fi
[[ $(q "PRAGMA user_version") == 3 ]] || { echo "failed unresolved down changed version" >&2; exit 1; }
[[ $(q "SELECT COUNT(*) FROM _remuda_migrations") == 3 ]] \
  || { echo "failed unresolved down changed history" >&2; exit 1; }
[[ $(q "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='relay_inbound_v3_archive'") == 0 ]] \
  || { echo "failed unresolved down left an archive" >&2; exit 1; }
[[ $(q "SELECT COUNT(*) FROM relay_inbound WHERE event_id='e-unresolved' AND state='unhanded'") == 1 ]] \
  || { echo "failed unresolved down changed inbound" >&2; exit 1; }
[[ $(q "SELECT COUNT(*) FROM relay_outbox WHERE reply_id='r-unresolved' AND state='in_flight'") == 1 ]] \
  || { echo "failed unresolved down changed outbox" >&2; exit 1; }
[[ $(q "SELECT COUNT(*) FROM relay_dedupe WHERE key='t-unresolved' AND state='open'") == 1 ]] \
  || { echo "failed unresolved down changed dedupe" >&2; exit 1; }
[[ $(q "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN ('relay_inbound_work','relay_inbound_expiry','relay_outbox_work','relay_outbox_expiry','relay_dedupe_expiry')") == 5 ]] \
  || { echo "failed unresolved down lost an index" >&2; exit 1; }
echo "relay 0003 unresolved down: refused atomically"
stop_daemon

# Resolve the work, then the downgrade may archive completed history.
start_daemon resolve
run_phase
# The failed down already wrote a v3 backup in this second; the runner refuses a
# duplicate backup name, so step to the next second for the successful down.
sleep 1
"$REMUDA_BIN" -s "$S" db downgrade butler relay 2 --yes >/dev/null
stop_daemon
[[ $(sqlite3 "$db" "PRAGMA user_version") == 2 ]] || { echo "down did not reach 0002" >&2; exit 1; }
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='relay_inbound'") == 0 ]] \
  || { echo "down left the live 0003 table" >&2; exit 1; }
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM relay_inbound_v3_archive WHERE event_id='e-unresolved' AND state='handed'") == 1 ]] \
  || { echo "completed inbound was not archived" >&2; exit 1; }
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM relay_outbox_v3_archive WHERE reply_id='r-unresolved' AND state='sent'") == 1 ]] \
  || { echo "completed outbox was not archived" >&2; exit 1; }
[[ $(sqlite3 "$db" "SELECT COUNT(*) FROM reply_receipts WHERE reply_id='r-old'") == 1 ]] \
  || { echo "0001 receipt was not preserved" >&2; exit 1; }
backup=$(ls "$db".v3-*.bak 2>/dev/null | head -1)
[[ -n "$backup" && -f "$backup" ]] || { echo "pre-down backup is missing" >&2; exit 1; }
[[ $(sqlite3 "$backup" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='relay_inbound'") == 1 ]] \
  || { echo "backup does not contain the live schema" >&2; exit 1; }
echo "relay 0003 down: completed archive preserved, backup present"

# Re-up and seed fresh live rows in all five tables. A second down cannot
# overwrite the archive; it must roll back atomically with all rows/history.
start_daemon reup
run_phase
# Step past the successful-down backup timestamp so the failure below is the
# archive-name collision, not a duplicate backup name.
sleep 1
if collision=$("$REMUDA_BIN" -s "$S" db downgrade butler relay 2 --yes 2>&1 >/dev/null); then
  echo "second downgrade must fail when the archive name exists" >&2
  exit 1
fi
[[ $collision == *"relay_inbound_v3_archive"* ]] \
  || { echo "second downgrade did not reach the archive collision: $collision" >&2; exit 1; }
grep -Eq 'already exists|already another table' <<<"$collision" \
  || { echo "second downgrade failed for the wrong reason: $collision" >&2; exit 1; }
[[ $(q "PRAGMA user_version") == 3 ]] || { echo "failed collision down changed version" >&2; exit 1; }
[[ $(q "SELECT COUNT(*) FROM _remuda_migrations") == 3 ]] \
  || { echo "failed collision down changed history" >&2; exit 1; }
[[ $(q "SELECT COUNT(*) FROM relay_inbound WHERE event_id='e-live'") == 1 ]] \
  || { echo "failed collision down lost live inbound" >&2; exit 1; }
[[ $(q "SELECT COUNT(*) FROM relay_outbox WHERE reply_id='r-live'") == 1 ]] \
  || { echo "failed collision down lost live outbox" >&2; exit 1; }
[[ $(q "SELECT COUNT(*) FROM relay_dedupe WHERE key='t-live'") == 1 ]] \
  || { echo "failed collision down lost live dedupe" >&2; exit 1; }
[[ $(q "SELECT COUNT(*) FROM relay_cursor WHERE id=1 AND since='s-live'") == 1 ]] \
  || { echo "failed collision down lost the cursor" >&2; exit 1; }
[[ $(q "SELECT COUNT(*) FROM relay_meta WHERE key='live-check'") == 1 ]] \
  || { echo "failed collision down lost live meta" >&2; exit 1; }
[[ $(q "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN ('relay_inbound_work','relay_inbound_expiry','relay_outbox_work','relay_outbox_expiry','relay_dedupe_expiry')") == 5 ]] \
  || { echo "failed collision down lost an index" >&2; exit 1; }
[[ $(q "SELECT COUNT(*) FROM relay_inbound_v3_archive") == 1 ]] \
  || { echo "failed collision down changed the archive" >&2; exit 1; }
echo "relay 0003 archive collision: refused atomically"

echo "relay migration 0003: PASS"
