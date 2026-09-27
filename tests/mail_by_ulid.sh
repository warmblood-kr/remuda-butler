#!/usr/bin/env bash
# End-to-end ULID-keyed Butler mail contract. Run from anywhere.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
SCRATCH_ROOT=$(mktemp -d /tmp/butler-mail-id.XXXXXX)
DAEMON_PID=
SERVER=mail-id
INSTANCE="$SCRATCH_ROOT/one"

cleanup() {
  STATUS=$?
  if [ -n "$DAEMON_PID" ]; then
    "$REMUDA_BIN" -s "$SERVER" -e 'pcall(remuda.close, "butler"); pcall(remuda.close, "member")' >/dev/null 2>&1 || true
    kill "$DAEMON_PID" >/dev/null 2>&1 || true
    wait "$DAEMON_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$SCRATCH_ROOT"
  exit "$STATUS"
}
trap cleanup EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
use_instance() {
  HOME="$INSTANCE/home"
  XDG_CONFIG_HOME="$INSTANCE/config"
  XDG_DATA_HOME="$INSTANCE/data"
  REMUDA_RUNTIME_DIR="$INSTANCE/runtime"
  REMUDA_NO_UPDATE_CHECK=1
  REMUDA_BUTLER_SERVER="$SERVER"
  export HOME XDG_CONFIG_HOME XDG_DATA_HOME REMUDA_RUNTIME_DIR REMUDA_NO_UPDATE_CHECK REMUDA_BUTLER_SERVER
  unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/remuda/mods/butler" "$REMUDA_RUNTIME_DIR"
  cp "$REPO/extension.toml" "$XDG_DATA_HOME/remuda/mods/butler/extension.toml"
  cp -R "$REPO/packages" "$XDG_DATA_HOME/remuda/mods/butler/packages"
  SOCKET="$REMUDA_RUNTIME_DIR/remuda/$SERVER.sock"
}
start_daemon() {
  "$REMUDA_BIN" -s "$SERVER" daemon >"$INSTANCE/daemon.log" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 100); do
    if python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(.1); s.connect(sys.argv[1])' "$SOCKET" >/dev/null 2>&1; then return; fi
    if ! kill -0 "$DAEMON_PID" >/dev/null 2>&1; then cat "$INSTANCE/daemon.log" >&2; fail "private daemon exited"; fi
    sleep 0.1
  done
  cat "$INSTANCE/daemon.log" >&2
  fail "private daemon did not bind $SOCKET"
}
lua() { "$REMUDA_BIN" -s "$SERVER" -e "$1"; }
expect_ulid() { [[ $2 =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]] || fail "$1 is not a ULID: '$2'"; }
component() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

use_instance
start_daemon
lua 'remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true' >/dev/null
"$REMUDA_BIN" -s "$SERVER" exec butler >/dev/null
lua 'remuda._butler_agent_builders.fake = function() return {"sh", "-c", "sleep 12"} end' >/dev/null
ROOT_ID=$(lua 'return remuda._butler_bus.agents.butler.id')
expect_ulid "root id" "$ROOT_ID"

# Prepare a pre-ULID inbox: two unread entries (one envelope has no sender id)
# and one entry already present in the legacy read log.
DATA="$XDG_DATA_HOME/remuda/butler/mail"
LEGACY_COMPONENT=$(component member)
mkdir -p "$DATA/inboxes" "$DATA/read" "$DATA/messages" "$DATA/objects"
printf '{"message_id":"legacy-a"}\n{"message_id":"legacy-b"}\n{"message_id":"legacy-read"}\n' >"$DATA/inboxes/$LEGACY_COMPONENT.jsonl"
printf 'legacy-read\n' >"$DATA/read/$LEGACY_COMPONENT.jsonl"
printf '{"id":"legacy-a","from":{"host":"local","session":"old-sender"},"subject":"Unread A","body":{"object_id":"obj-a"}}\n' >"$DATA/messages/legacy-a.json"
printf '{"id":"legacy-b","from":{"host":"local","session":"old-sender"},"subject":"Unread B","body":{"object_id":"obj-b"}}\n' >"$DATA/messages/legacy-b.json"
printf '{"id":"legacy-read","from":{"host":"local","session":"old-sender"},"subject":"Already Read","body":{"object_id":"obj-read"}}\n' >"$DATA/messages/legacy-read.json"
printf 'legacy body A' >"$DATA/objects/obj-a"
printf 'legacy body B' >"$DATA/objects/obj-b"
printf 'legacy read body' >"$DATA/objects/obj-read"

lua 'remuda._butler_launch("fake", "member")' >/dev/null
MEMBER_ID=$(lua 'return remuda._butler_bus.agents.member.id')
expect_ulid "member id" "$MEMBER_ID"
ID_COMPONENT=$(component "$MEMBER_ID")
MEMBER_INBOX="$DATA/inboxes/$ID_COMPONENT.jsonl"
[[ -f $MEMBER_INBOX ]] || fail "member ULID inbox file was not created"

SENT_RESULT=$(lua 'return remuda._butler_send("butler", "member", "new-by-alias")')
SENT_ID=$(printf '%s\n' "$SENT_RESULT" | sed -E 's/^queued ([^ ]+).*/\1/')
grep -F 'new-by-alias' "$DATA/objects/"* >/dev/null || fail "alias-addressed message body was not persisted"
grep -F '"message_id"' "$MEMBER_INBOX" >/dev/null || fail "alias-addressed message did not land in the ULID inbox"
grep -F '"to":[{"host":"local","id":"'"$MEMBER_ID"'","alias":"member"' "$DATA/messages/$SENT_ID.json" >/dev/null || \
  fail "recipient ULID and alias are missing from the envelope"
[[ $(lua "return remuda._butler_bus.inboxes.member == nil and remuda._butler_bus.inboxes['$MEMBER_ID'] ~= nil") == true ]] || \
  fail "in-memory mailboxes are not keyed by ULID"
echo "ok - mail to an alias is stored in the recipient ULID inbox"

lua 'remuda._butler_send("member", "butler", "sender metadata")' >/dev/null
ENVELOPE=$(rg -l '"subject":"Message from member"' "$DATA/messages" 2>/dev/null | head -1 || true)
[[ -n $ENVELOPE ]] || fail "member sender envelope was not written"
grep -F '"id":"'"$MEMBER_ID"'"' "$ENVELOPE" >/dev/null || fail "sender id missing from envelope"
grep -F '"alias":"member"' "$ENVELOPE" >/dev/null || fail "sender alias missing from envelope"
grep -F '"kind":"fake"' "$ENVELOPE" >/dev/null || fail "sender kind missing from envelope"
grep -F '"leader":"'"$ROOT_ID"'"' "$ENVELOPE" >/dev/null || fail "sender leader ULID missing from envelope"
grep -F '"session":"member"' "$ENVELOPE" >/dev/null || fail "legacy sender session missing from envelope"
echo "ok - new envelopes carry sender ULID metadata and legacy session"

MIGRATED=$(lua "return remuda._butler_inbox('$MEMBER_ID')")
[[ $MIGRATED == *"Unread A"* && $MIGRATED == *"Unread B"* ]] || fail "unread legacy mail was not migrated"
[[ $MIGRATED != *"Already Read"* ]] || fail "already-read legacy mail was migrated"
[[ $MIGRATED == *"old-sender"* ]] || fail "legacy envelope without an id did not render its session"
echo "ok - migration copies unread legacy mail and tolerates id-less envelopes"

# Simulate a crash after copying the ULID inbox but before advancing the old
# read log. The retry must see the target IDs and only repair the old log.
printf 'legacy-read\n' >"$DATA/read/$LEGACY_COMPONENT.jsonl"
lua "remuda._butler_bus.mail_read['member'] = nil; remuda._butler_migrate_legacy_mail('member', '$MEMBER_ID')" >/dev/null
COUNT_BEFORE=$(wc -l <"$MEMBER_INBOX" | tr -d ' ')
lua "remuda._butler_migrate_legacy_mail('member', '$MEMBER_ID')" >/dev/null
COUNT_AFTER=$(wc -l <"$MEMBER_INBOX" | tr -d ' ')
[[ $COUNT_BEFORE == "$COUNT_AFTER" ]] || fail "rerunning migration duplicated mail ($COUNT_BEFORE -> $COUNT_AFTER)"
[[ $(grep -c 'legacy-a' "$MEMBER_INBOX" || true) == 1 ]] || fail "legacy-a appears more than once"
[[ $(grep -c 'legacy-b' "$MEMBER_INBOX" || true) == 1 ]] || fail "legacy-b appears more than once"
grep -F 'legacy-a' "$DATA/read/$LEGACY_COMPONENT.jsonl" >/dev/null || fail "legacy read log was not advanced"
grep -F 'legacy-b' "$DATA/read/$LEGACY_COMPONENT.jsonl" >/dev/null || fail "legacy read log was not advanced"
echo "ok - migration is idempotent and advances the legacy read log"

for _ in $(seq 150); do
  if lua 'return remuda._butler_bus.agents.member == nil' | grep -qx true; then break; fi
  sleep 0.1
done
lua 'return remuda._butler_bus.agents.member == nil' | grep -qx true || fail "member did not exit"
[[ $(lua "return remuda._butler_inbox('$MEMBER_ID')") == *"inbox empty"* ]] || fail "ended member inbox by ULID did not remain readable"
if lua "return remuda._butler_send('butler', '$MEMBER_ID', 'too late')" >"$INSTANCE/ended.out" 2>&1; then
  fail "sending to an ended ULID unexpectedly succeeded"
fi
grep -F "agent $MEMBER_ID (alias member) has ended" "$INSTANCE/ended.out" >/dev/null || \
  fail "ended-ULID error was unclear: $(cat "$INSTANCE/ended.out")"
echo "ok - ended member mail remains readable; sends to ended ids fail clearly"

echo PASS
