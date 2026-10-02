#!/usr/bin/env bash
# HANDOFF convention: the root prompt names it, and a HANDOFF mail survives a root relaunch. Run from anywhere.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
SCRATCH_ROOT=$(mktemp -d /tmp/butler-handoff.XXXXXX)
SCRATCH_ROOT=$(cd "$SCRATCH_ROOT" && pwd -P)
DAEMON_PID=
SERVER=handoff
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
    if [ -S "$SOCKET" ] && "$REMUDA_BIN" -s "$SERVER" ls >/dev/null 2>&1; then return; fi
    if ! kill -0 "$DAEMON_PID" >/dev/null 2>&1; then cat "$INSTANCE/daemon.log" >&2; fail "private daemon exited"; fi
    sleep 0.1
  done
  cat "$INSTANCE/daemon.log" >&2
  fail "private daemon did not bind $SOCKET"
}
lua() { "$REMUDA_BIN" -s "$SERVER" -e "$1"; }
expect_ulid() { [[ $2 =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]] || fail "$1 is not a ULID: '$2'"; }
component() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
mkdir -p "$INSTANCE"
use_instance
start_daemon
lua 'remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true' >/dev/null
"$REMUDA_BIN" -s "$SERVER" exec butler >/dev/null
for _ in $(seq 50); do
  if lua 'return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil' | grep -qx true; then break; fi
  sleep 0.1
done
ROOT_ID=$(lua 'return remuda._butler_bus.agents.butler.id')
expect_ulid "root id" "$ROOT_ID"

PROMPT=$(lua 'return remuda._butler_system_prompt')
[[ $PROMPT == *'If the inbox has a mail whose first line is `HANDOFF`, read it before anything else and take over its open items.'* ]] || \
  fail "root prompt lacks the HANDOFF line"
echo "ok - root prompt tells Butler to read a HANDOFF mail first"

lua 'return remuda._butler_send("operator", "butler", "HANDOFF\nopen: PR 12")' >/dev/null
[[ $(lua "return remuda._butler_inbox('$ROOT_ID')") == *"open: PR 12"* ]] || fail "HANDOFF mail is not in the root inbox"
# inbox marks read; resend a fresh one so the relaunch sees it unread.
lua 'return remuda._butler_send("operator", "butler", "HANDOFF\nopen: PR 13")' >/dev/null
"$REMUDA_BIN" -s "$SERVER" exec butler >/dev/null
[[ $(lua 'return remuda._butler_bus.agents.butler.id') == "$ROOT_ID" ]] || fail "relaunch changed the root ULID"
AFTER=$(lua "return remuda._butler_inbox('$ROOT_ID')")
[[ $AFTER == *"open: PR 13"* ]] || fail "HANDOFF mail did not stay unread across the relaunch"
[[ $AFTER != *"open: PR 12"* ]] || fail "an already-read HANDOFF mail came back"
echo "ok - an unread HANDOFF mail survives a relaunch of the same ULID"

echo PASS
