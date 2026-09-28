#!/usr/bin/env bash
# End-to-end Butler agent identity contract. Run from anywhere with:
#   tests/agent_identity.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
SCRATCH_ROOT=$(mktemp -d /tmp/butler-id.XXXXXX)
DAEMON_PID=
SERVER=
SOCKET=

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

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

use_instance() {
  INSTANCE=$1
  SERVER=$2
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

start_private_daemon() {
  "$REMUDA_BIN" -s "$SERVER" daemon >"$INSTANCE/daemon.log" 2>&1 &
  DAEMON_PID=$!
  ATTEMPT=0
  while ! python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(.1); s.connect(sys.argv[1])' "$SOCKET" >/dev/null 2>&1; do
    ATTEMPT=$((ATTEMPT + 1))
    if [ "$ATTEMPT" -ge 100 ] || ! kill -0 "$DAEMON_PID" >/dev/null 2>&1; then
      cat "$INSTANCE/daemon.log" >&2
      fail "private daemon did not bind $SOCKET"
    fi
    sleep 0.1
  done
}

stop_private_daemon() {
  "$REMUDA_BIN" -s "$SERVER" stop -f >/dev/null 2>&1 || true
  if [ -n "$DAEMON_PID" ]; then
    wait "$DAEMON_PID" >/dev/null 2>&1 || true
    DAEMON_PID=
  fi
}

lua() { "$REMUDA_BIN" -s "$SERVER" -e "$1"; }

load_butler() {
  lua 'remuda._butler_argv = {"sh", "-c", "env | grep ^REMUDA_BUTLER_; sleep 30"}; remuda._butler_skip_relay = true' >/dev/null
  "$REMUDA_BIN" -s "$SERVER" exec butler >/dev/null
  for _ in $(seq 50); do
    if lua 'return remuda._butler_agent_builders ~= nil' | grep -qx true; then break; fi
    sleep 0.1
  done
  lua 'remuda._butler_agent_builders.fake = function() return {"sh", "-c", "env | grep ^REMUDA_BUTLER_; sleep 30"} end' >/dev/null
}

expect_ulid() {
  local label=$1 value=$2
  [[ $value =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]] || fail "$label is not a 26-character Crockford ULID: '$value'"
  echo "ok - $label"
}

INSTANCE="$SCRATCH_ROOT/one"
use_instance "$INSTANCE" identity-one
start_private_daemon
load_butler
ROOT_ID=$(lua 'return remuda._butler_bus.agents.butler.id or ""')
expect_ulid "root Butler id" "$ROOT_ID"

# Freeze the seconds clock so the generator's monotonic mode is exercised
# directly. A run of random values is overwhelmingly unlikely to be sorted.
SAME_SECOND_IDS=$(lua 'local now=os.time; os.time=function() return 42 end; local ids={}; for i=1,32 do ids[i]=remuda._butler_new_ulid() end; os.time=now; return table.concat(ids, "\n")')
PREVIOUS=
while IFS= read -r ID; do
  if [[ -n $PREVIOUS && ! $PREVIOUS < $ID ]]; then fail "same-second ULIDs are not strictly increasing: $PREVIOUS then $ID"; fi
  PREVIOUS=$ID
done <<< "$SAME_SECOND_IDS"
echo "ok - ULIDs increase within the same second"

lua 'remuda._butler_agent_builders.fake = function() return {"sh", "-c", "env | grep ^REMUDA_BUTLER_; sleep 8"} end; remuda._butler_launch("fake", "member")' >/dev/null
MEMBER_ID=$(lua 'return remuda._butler_bus.agents.member.id or ""')
expect_ulid "member id" "$MEMBER_ID"

MEMBER_ENV=$(lua 'return remuda.capture("member")')
[[ $MEMBER_ENV == *"REMUDA_BUTLER_AGENT_ID=$MEMBER_ID"* ]] || fail "member env lacks its ULID: $MEMBER_ENV"
[[ $MEMBER_ENV == *"REMUDA_BUTLER_AGENT_ALIAS=member"* ]] || fail "member env lacks its alias: $MEMBER_ENV"
[[ $MEMBER_ENV == *"REMUDA_BUTLER_LEADER_ID=$ROOT_ID"* ]] || fail "member env lacks its leader ULID: $MEMBER_ENV"
echo "ok - member environment carries its id, alias, and leader id"

[[ $(lua "return remuda._butler_resolve('$MEMBER_ID')") == member ]] || fail "ULID did not resolve to its alias"
[[ $(lua 'return remuda._butler_resolve("member")') == member ]] || fail "alias did not resolve to its live holder"
echo "ok - references resolve by ULID and alias"
lua "remuda._butler_send('operator', '$MEMBER_ID', 'id addressed')" >/dev/null
[[ $(lua "return remuda._butler_inbox('$MEMBER_ID')") == *"id addressed"* ]] || fail "send/inbox did not accept an id reference"
echo "ok - send and inbox accept ULID references"

if "$REMUDA_BIN" -s "$SERVER" -e 'remuda._butler_launch("fake", "member")' >"$INSTANCE/duplicate.out" 2>&1; then
  fail "a live alias was launched twice"
fi
grep -F "alias member is live as $MEMBER_ID; pick another alias" "$INSTANCE/duplicate.out" >/dev/null || \
  fail "live-alias error did not name the id: $(cat "$INSTANCE/duplicate.out")"
echo "ok - a live alias cannot be reused"

ROSTER=$("$REMUDA_BIN" -s "$SERVER" butler sessions)
printf '%s\n' "$ROSTER" | grep -F $'butler\t' >/dev/null || fail "tree omits the root alias: $ROSTER"
# View policy (#25): a root's direct children sit at the margin, not indented.
printf '%s\n' "$ROSTER" | grep -Fx $'member\tfake\tbutler' >/dev/null || \
  fail "tree lost alias display or leader nesting: $ROSTER"
[[ $ROSTER != *"$ROOT_ID"* && $ROSTER != *"$MEMBER_ID"* ]] || fail "tree displayed ULIDs instead of aliases: $ROSTER"
echo "ok - session tree displays aliases with leader nesting"

for _ in $(seq 100); do
  if lua 'return remuda._butler_bus.agents.member == nil' | grep -qx true; then break; fi
  sleep 0.1
done
lua 'return remuda._butler_bus.agents.member == nil' | grep -qx true || fail "exited member remained live"
lua 'remuda._butler_agent_builders.fake = function() return {"sleep", "30"} end' >/dev/null
lua 'remuda._butler_launch("fake", "member")' >/dev/null
MEMBER_ID_2=$(lua 'return remuda._butler_bus.identities.member.id or ""')
expect_ulid "reused alias id" "$MEMBER_ID_2"
[[ $MEMBER_ID_2 != "$MEMBER_ID" ]] || fail "reused alias kept its old id"
echo "ok - an exited alias can be reused with a new id"

REGISTRY="$XDG_DATA_HOME/remuda/butler/agents.jsonl"
grep -F "\"id\":\"$MEMBER_ID\"" "$REGISTRY" >/dev/null || fail "registry omits the first member id"
grep -F "\"ended_at\":" "$REGISTRY" >/dev/null || fail "registry omits the ended member record"

stop_private_daemon
start_private_daemon
load_butler
ROOT_ID_AFTER_RESTART=$(lua 'return remuda._butler_bus.agents.butler.id or ""')
[[ $ROOT_ID_AFTER_RESTART == "$ROOT_ID" ]] || fail "root id changed across daemon restart: $ROOT_ID -> $ROOT_ID_AFTER_RESTART"
echo "ok - root Butler id survives a daemon restart"
stop_private_daemon

INSTANCE="$SCRATCH_ROOT/two"
use_instance "$INSTANCE" identity-two
start_private_daemon
load_butler
lua 'remuda._butler_launch("fake", "member")' >/dev/null
MEMBER_ID_FRESH=$(lua 'return remuda._butler_bus.agents.member.id or ""')
expect_ulid "fresh-daemon member id" "$MEMBER_ID_FRESH"
[[ $MEMBER_ID_FRESH != "$MEMBER_ID" ]] || fail "fresh daemons minted the same first member id"
echo "ok - fresh daemons mint different first member ids"

echo PASS
