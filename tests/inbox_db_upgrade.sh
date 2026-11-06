#!/bin/sh
# Verifies the inbox SQLite shadow: migration applies, existing files import,
# delivery and read hooks write, and a broken handle never blocks mail.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
SCRATCH=$(mktemp -d /tmp/butler-inbox-db.XXXXXX)
SCRATCH=$(CDPATH= cd -- "$SCRATCH" && pwd -P)
SERVER=$(basename "$SCRATCH")
SOCKET="$SCRATCH/runtime/remuda/$SERVER.sock"
LOG="$SCRATCH/daemon.log"
PID=
export HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/config"
export XDG_DATA_HOME="$SCRATCH/data" REMUDA_RUNTIME_DIR="$SCRATCH/runtime"
export REMUDA_NO_UPDATE_CHECK=1
MAIL="$XDG_DATA_HOME/remuda/butler/mail"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/remuda/mods/butler" \
  "$REMUDA_RUNTIME_DIR" "$MAIL/inboxes" "$MAIL/read"
cp "$ROOT/extension.toml" "$XDG_DATA_HOME/remuda/mods/butler/extension.toml"
cp -R "$ROOT/packages" "$XDG_DATA_HOME/remuda/mods/butler/packages"

cleanup() {
  status=$?
  if [ -n "$PID" ]; then
    "$REMUDA_BIN" -s "$SERVER" -e 'pcall(remuda.close, "butler")' >/dev/null 2>&1 || true
    kill "$PID" >/dev/null 2>&1 || true
    wait "$PID" >/dev/null 2>&1 || true
  fi
  if [ "$status" -ne 0 ] && [ -f "$LOG" ]; then
    echo "private daemon log:"; cat "$LOG"
  fi
  rm -rf "$SCRATCH"
  exit "$status"
}
trap cleanup EXIT INT TERM

# Existing mail on disk must be imported before anything new is written.
printf '{"message_id":"seed-1"}\n' >"$MAIL/inboxes/612f62.jsonl"
printf 'seed-1\n' >"$MAIL/read/612f62.jsonl"

"$REMUDA_BIN" -s "$SERVER" daemon >>"$LOG" 2>&1 &
PID=$!
n=0
while [ ! -S "$SOCKET" ] || ! "$REMUDA_BIN" -s "$SERVER" ls >/dev/null 2>&1; do
  n=$((n + 1))
  if [ "$n" -ge 100 ] || ! kill -0 "$PID" >/dev/null 2>&1; then
    echo "private daemon did not bind $SOCKET"; cat "$LOG"; exit 1
  fi
  sleep 0.1
done
"$REMUDA_BIN" -s "$SERVER" -e 'remuda._butler_argv = {"sh", "-c", "while read line; do :; done"}; remuda._butler_skip_relay = true' >/dev/null
"$REMUDA_BIN" -s "$SERVER" exec butler >/dev/null
n=0
while ! "$REMUDA_BIN" -s "$SERVER" -e 'return remuda._butler_bus ~= nil' | grep -qx true; do
  n=$((n + 1))
  if [ "$n" -ge 50 ]; then echo "Butler lifecycle did not start"; exit 1; fi
  sleep 0.1
done

count() {
  "$REMUDA_BIN" -s "$SERVER" -e "return tostring(remuda._butler_inbox_db.count(\"$1\", \"$2\"))"
}

# The pinned core for older PRs may not have remuda.db (#778). Butler must
# keep working on the file path; only the shadow-specific checks are skipped.
if [ "$("$REMUDA_BIN" -s "$SERVER" -e 'return type(remuda.db) == "table"')" != true ]; then
  "$REMUDA_BIN" -s "$SERVER" -e \
    'assert(remuda._butler_mail.queue({alias="sender", id="sender-id"}, {alias="member", id="member-id"}, "hello"))' >/dev/null
  "$REMUDA_BIN" -s "$SERVER" -e 'assert(remuda._butler_mail.inbox("member-id"):find("hello", 1, true))' >/dev/null
  echo "SKIP inbox db unavailable on this core; file mail path passed"
  exit 0
fi

[ "$(count 'a/b' inbox)" = 1 ] || { echo "seed delivery was not imported"; exit 1; }
[ "$(count 'a/b' read)" = 1 ] || { echo "seed read was not imported"; exit 1; }

# A normal queue writes the file first and then the shadow delivery row.
"$REMUDA_BIN" -s "$SERVER" -e \
  'assert(remuda._butler_mail.queue({alias="sender", id="sender-id"}, {alias="member", id="member-id"}, "hello"))' >/dev/null
[ "$(count 'member-id' inbox)" = 1 ] || { echo "new delivery was not indexed"; exit 1; }

# Reading it marks the shadow read row exactly like the file log.
"$REMUDA_BIN" -s "$SERVER" -e 'assert(remuda._butler_mail.inbox("member-id"):find("hello", 1, true))' >/dev/null
[ "$(count 'member-id' read)" = 1 ] || { echo "read state was not indexed"; exit 1; }

# The relay receipt shadow shares the same private database and must apply
# its migration and accept a post-JSON-commit record.
"$REMUDA_BIN" -s "$SERVER" -e '
  local receipts = assert(remuda._butler_relay_receipts, "relay receipts module")
  local recorded, why = receipts.record("r1", "butler_r1", { source_mail_id = "m1",
    event_id = "e1", completed_at = "2026-11-06T00:00:00Z" })
  assert(recorded, "shadow record: " .. tostring(why))
  local row = assert(receipts.get("r1"))
  assert(row.reply_id == "r1" and row.txn_id == "butler_r1", "row")
  assert(row.status == "sent", "status")
' >/dev/null

# The daemon must report the schema version and leave the file path usable.
"$REMUDA_BIN" -s "$SERVER" db status butler >/dev/null
printf 'PASS\n'
