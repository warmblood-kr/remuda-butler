#!/usr/bin/env bash
# A lead whose process ends hands its live members to the root, and the root
# can then close them (exit-path hook of _butler_adopt_members). Private daemon.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
SCRATCH=$(mktemp -d /tmp/badopt.XXXXXX)
SCRATCH=$(cd "$SCRATCH" && pwd -P)
SERVER=badopt
export HOME=$SCRATCH/home XDG_CONFIG_HOME=$SCRATCH/config XDG_DATA_HOME=$SCRATCH/data
export REMUDA_RUNTIME_DIR=$SCRATCH/run REMUDA_NO_UPDATE_CHECK=1 REMUDA_BUTLER_PROJECT_HOME=$SCRATCH/projects
unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG REMUDA_BUTLER_AGENT_ID REMUDA_BUTLER_LEADER_ID REMUDA_BUTLER_SESSION_NAME
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/remuda/mods/butler" "$REMUDA_RUNTIME_DIR"
tar -c -C "$REPO" extension.toml packages | tar -x -C "$XDG_DATA_HOME/remuda/mods/butler"

cleanup() {
  "$REMUDA_BIN" -s "$SERVER" stop -f >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
lua() { "$REMUDA_BIN" -s "$SERVER" -e "$1"; }
parent_of() { lua "local a = remuda._butler_bus.agents['$1']; return a and a.parent or 'gone'"; }

"$REMUDA_BIN" -s "$SERVER" daemon >"$SCRATCH/daemon.log" 2>&1 &
for _ in $(seq 50); do
  [[ -S $REMUDA_RUNTIME_DIR/remuda/$SERVER.sock ]] && break
  sleep 0.1
done
[[ -S $REMUDA_RUNTIME_DIR/remuda/$SERVER.sock ]] || { cat "$SCRATCH/daemon.log" >&2; fail "private daemon did not bind"; }

lua 'remuda._butler_argv = {"sleep", "60"}; remuda._butler_skip_relay = true; remuda.exec("butler")' >/dev/null
for _ in $(seq 50); do
  lua 'return remuda._butler_agent_builders ~= nil' | grep -qx true && break
  sleep 0.1
done
lua 'remuda._butler_agent_builders.fake = function() return {"sleep", "60"} end
  remuda._butler_launch("fake", "lead")
  remuda._butler_launch("fake", "m1", nil, "lead")
  remuda._butler_launch("fake", "m2", nil, "lead")' >/dev/null
[[ $(parent_of m1) == lead && $(parent_of m2) == lead ]] || fail "members not under lead before the exit"

lua 'remuda.close("lead")' >/dev/null
for _ in $(seq 100); do
  [[ $(parent_of lead) == gone ]] && break
  sleep 0.1
done
[[ $(parent_of lead) == gone ]] || fail "lead did not exit"
for _ in $(seq 50); do
  [[ $(parent_of m1) == butler && $(parent_of m2) == butler ]] && break
  sleep 0.1
done
[[ $(parent_of m1) == butler && $(parent_of m2) == butler ]] ||
  fail "members not adopted by butler: m1=$(parent_of m1) m2=$(parent_of m2)"
"$REMUDA_BIN" -s "$SERVER" butler sessions | grep -Fx $'m1\tfake\tbutler' >/dev/null ||
  fail "butler sessions does not show m1 under butler"

# root closes an adopted member; --force only when the unread guard blocks.
"$REMUDA_BIN" -s "$SERVER" butler close m1 >"$SCRATCH/close.out" 2>&1 ||
  "$REMUDA_BIN" -s "$SERVER" butler close m1 --force >>"$SCRATCH/close.out" 2>&1 ||
  fail "root could not close adopted m1: $(cat "$SCRATCH/close.out")"
for _ in $(seq 100); do
  [[ $(parent_of m1) == gone ]] && break
  sleep 0.1
done
[[ $(parent_of m1) == gone ]] || fail "m1 still live after close"
echo PASS
