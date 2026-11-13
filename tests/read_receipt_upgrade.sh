#!/usr/bin/env bash
# Real existing-install receipt intent upgrade.
#
# Creates an inbox database with existing simple_inbox data under migration
# 0002, steps it back to the v1 schema with the stored down SQL (the same state
# an older install has), then lets Butler reopen it and apply 0002 again.
# Verifies existing mail/read state, no backfill, agent-only intents, and both
# the agent and operator read paths after the upgrade.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
REMUDA_BIN=${REMUDA_BIN:-remuda}
source "$REPO/tests/lib/isolated_env.sh"
isolated_env_prepare receiptup receiptup
export REMUDA_NO_UPDATE_CHECK=1

MOD="$XDG_DATA_HOME/remuda/mods/butler"
MAIL="$XDG_DATA_HOME/remuda/butler/mail"
mkdir -p "$MOD" "$MAIL"/{inboxes,read,messages,objects}
cp "$REPO/extension.toml" "$MOD/extension.toml"
cp -R "$REPO/packages" "$MOD/packages"

# Existing mail: A unread, B already read, C unread for aa; D for bb; E for cc.
for id in A B C D E; do
  case $id in A|B|C) to=aa;; D) to=bb;; E) to=cc;; esac
  printf '{"id":"%s","from":{"host":"local","id":"sender","alias":"sender","session":"sender"},"to":[{"host":"local","id":"%s","alias":"%s","session":"%s"}],"subject":"Task","created_at":"2026-11-13","content_type":"text/plain","body":{"object_id":"object-%s"}}\n' \
    "$id" "$to" "$to" "$to" "$id" >"$MAIL/messages/$id.json"
  printf 'body %s' "$id" >"$MAIL/objects/object-$id"
done
printf '{"message_id":"A"}\n{"message_id":"B"}\n{"message_id":"C"}\n' >"$MAIL/inboxes/6161.jsonl"
printf 'B\n' >"$MAIL/read/6161.jsonl"
printf '{"message_id":"D"}\n' >"$MAIL/inboxes/6262.jsonl"
printf '{"message_id":"E"}\n' >"$MAIL/inboxes/6363.jsonl"

start_daemon() {
  "$REMUDA_BIN" -s "$S" daemon >>"$T/daemon.log" 2>&1 &
  ISOLATED_DAEMON_PID=$!
  for _ in $(seq 100); do [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] && break; sleep 0.1; done
  isolated_env_check_daemon
}
wait_bus() {
  for _ in $(seq 100); do
    local out
    out=$("$REMUDA_BIN" -s "$S" -e 'return remuda._butler_bus ~= nil' 2>/dev/null || true)
    [[ $out == true ]] && return 0
    sleep 0.1
  done
  echo "Butler lifecycle did not start" >&2
  cat "$T/daemon.log" >&2
  return 1
}
boot_butler() {
  "$REMUDA_BIN" -s "$S" -e \
    'remuda._butler_argv={"sh","-c","sleep 60"}; remuda._butler_skip_relay=true; return remuda.exec("butler")' >/dev/null
  wait_bus
}
stop_daemon() {
  "$REMUDA_BIN" -s "$S" stop -f --yes >/dev/null 2>&1 || true
  wait "$ISOLATED_DAEMON_PID" 2>/dev/null || true
  ISOLATED_DAEMON_PID=
}

start_daemon
boot_butler

# The first boot created v2. Step the actual DB back to v1: the intent table is
# gone, but the existing simple_inbox rows and read state remain.
"$REMUDA_BIN" -s "$S" db downgrade butler inbox 1 --yes >/dev/null
"$REMUDA_BIN" -s "$S" -e '
  local simple = assert(remuda._butler_simple_inbox, "simple inbox is not active")
  local db = simple.db
  local version = assert(db:query("PRAGMA user_version"))
  assert(tonumber(version[1].user_version) == 1, "downgrade did not reach schema v1")
  local table = assert(db:query("SELECT name FROM sqlite_master WHERE type=\"table\" AND name=\"read_receipt_intents\""))
  assert(#table == 0, "v1 schema unexpectedly still has the intent table")
  local rows = assert(db:query("SELECT message_id,is_read FROM simple_inbox ORDER BY seq"))
  local seen = {}
  for _, row in ipairs(rows) do seen[row.message_id] = tonumber(row.is_read) end
  assert(#rows == 5, "existing mail was lost on downgrade")
  assert(seen.A == 0 and seen.B == 1 and seen.C == 0 and seen.D == 0 and seen.E == 0,
    "existing read state changed on downgrade")
' >/dev/null

# Restart so the next open applies 0002 to the real existing database.
stop_daemon
start_daemon
boot_butler

"$REMUDA_BIN" -s "$S" -e '
  local simple = assert(remuda._butler_simple_inbox, "simple inbox is not active after upgrade")
  local db = simple.db
  local version = assert(db:query("PRAGMA user_version"))
  assert(tonumber(version[1].user_version) == 3, "0003 did not apply to the existing database")
  local rows = assert(db:query("SELECT message_id,is_read FROM simple_inbox ORDER BY seq"))
  local seen = {}
  for _, row in ipairs(rows) do seen[row.message_id] = tonumber(row.is_read) end
  assert(#rows == 5, "existing mail was lost on upgrade")
  assert(seen.A == 0 and seen.B == 1 and seen.C == 0 and seen.D == 0 and seen.E == 0,
    "existing read state changed on upgrade")
  local intents = assert(db:query("SELECT message_id FROM read_receipt_intents"))
  assert(#intents == 0, "upgrade backfilled receipt intents")

  local mail = assert(remuda._butler_mail)
  local text = assert(mail.inbox("aa", { reader_id = "aa" }))
  assert(text:find("body A", 1, true) and text:find("body C", 1, true), "agent read missed existing mail")
  local aa = assert(db:query("SELECT message_id FROM read_receipt_intents WHERE recipient = ?", { "6161" }))
  assert(#aa == 2, "agent read did not create exactly one intent per new message")
  assert(aa[1].message_id ~= "B" and aa[2].message_id ~= "B", "already-read mail was backfilled")

  -- Real local delivery: the same two intents must produce one receipt each in
  -- the original sender inbox, correlated by the structured receipt_of field.
  local counts = assert(assert(remuda._butler_read_receipts).drain())
  assert(counts.delivered == 2, "real drain did not deliver two receipts")
  local statuses = assert(db:query(
    "SELECT message_id,receipt_id,receipt_body,status FROM read_receipt_intents WHERE recipient = ?", { "6161" }))
  local receipt_ids = {}
  for _, row in ipairs(statuses) do
    assert(row.status == "delivered", "real drain left an intent pending")
    assert(#row.receipt_id == 26 and row.receipt_id:match("^[0-9A-HJKMNP-TV-Z]+$"),
      "stored receipt identity is not a Butler ULID")
    assert(type(row.receipt_body) == "string"
      and row.receipt_body:find("fetched message " .. row.message_id, 1, true),
      "receipt body was not fixed in the intent")
    receipt_ids[row.receipt_id] = true
  end
  local sender_rows = assert(db:query(
    "SELECT message_id,envelope FROM simple_inbox WHERE recipient = ? ORDER BY seq", { "73656e646572" }))
  assert(#sender_rows == 2, "original sender did not receive exactly two receipts")
  local correlated = {}
  for _, row in ipairs(sender_rows) do
    assert(receipt_ids[row.message_id], "receipt mail ID does not match the stored intent ULID")
    local receipt_of = row.envelope:match("\"receipt_of\":\"([^\"]+)\"")
    assert(receipt_of == "A" or receipt_of == "C", "receipt is not correlated to the original")
    correlated[receipt_of] = true
  end
  assert(correlated.A and correlated.C, "a batch receipt is missing")
  -- Reading a receipt must not create another receipt (structured loop guard).
  local sender_text = assert(mail.inbox("sender", { reader_id = "sender" }))
  assert(sender_text:find("Read receipt", 1, true), "sender could not read its receipts")
  local loop = assert(assert(remuda._butler_read_receipts).drain())
  assert(loop.skipped == 2, "receipt messages were not skipped")
  local sender_again = assert(db:query(
    "SELECT message_id FROM simple_inbox WHERE recipient = ?", { "73656e646572" }))
  assert(#sender_again == 2, "receipt loop produced mail")

  local operator = assert(mail.inbox("bb", { reader_id = nil }))
  assert(operator:find("body D", 1, true), "operator read missed the member inbox")
  local bb = assert(db:query("SELECT message_id FROM read_receipt_intents WHERE recipient = ?", { "6262" }))
  assert(#bb == 0, "operator read created an agent receipt intent")

  local cross = assert(mail.inbox("cc", { reader_id = "aa" }))
  assert(cross:find("body E", 1, true), "cross-member read missed the inbox")
  local cc = assert(db:query("SELECT message_id FROM read_receipt_intents WHERE recipient = ?", { "6363" }))
  assert(#cc == 0, "cross-member read created an agent receipt intent")
' >/dev/null

# A second restart must keep exactly the agent intents and skip the already-read
# mail; no re-backfill and no duplicate.
stop_daemon
start_daemon
boot_butler
"$REMUDA_BIN" -s "$S" -e '
  local db = assert(remuda._butler_simple_inbox).db
  local version = assert(db:query("PRAGMA user_version"))
  assert(tonumber(version[1].user_version) == 3, "schema version changed after restart")
  local aa = assert(db:query("SELECT message_id FROM read_receipt_intents WHERE recipient = ?", { "6161" }))
  assert(#aa == 2, "agent intents were lost or duplicated across restart")
  local bb = assert(db:query("SELECT message_id FROM read_receipt_intents WHERE recipient = ?", { "6262" }))
  local cc = assert(db:query("SELECT message_id FROM read_receipt_intents WHERE recipient = ?", { "6363" }))
  assert(#bb == 0 and #cc == 0, "operator/cross-member intents reappeared after restart")
  assert(assert(remuda._butler_mail).inbox("aa", { reader_id = "aa" }) == "inbox empty", "read mail returned")
  aa = assert(db:query("SELECT message_id FROM read_receipt_intents WHERE recipient = ?", { "6161" }))
  assert(#aa == 2, "re-read created a duplicate intent")
' >/dev/null

echo "PASS"
