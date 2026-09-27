#!/bin/sh
# usage: sh tests/session_tree.sh   (EXPECT=red checks that an old renderer fails)
set -eu

BUTLER_TREE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
EXPECT=${EXPECT:-green}
SCRATCH_ROOT=$(mktemp -d /tmp/butler-tree.XXXXXX)
SERVER=$(basename "$SCRATCH_ROOT")
SOCKET="$SCRATCH_ROOT/runtime/remuda/$SERVER.sock"
DAEMON_LOG="$SCRATCH_ROOT/daemon.log"
DAEMON_PID=
export HOME="$SCRATCH_ROOT/home"
export XDG_CONFIG_HOME="$SCRATCH_ROOT/config"
export XDG_DATA_HOME="$SCRATCH_ROOT/data"
export REMUDA_RUNTIME_DIR="$SCRATCH_ROOT/runtime"
export REMUDA_NO_UPDATE_CHECK=1
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/remuda/mods/butler" "$REMUDA_RUNTIME_DIR"
cp "$BUTLER_TREE_ROOT/extension.toml" "$XDG_DATA_HOME/remuda/mods/butler/extension.toml"
cp -R "$BUTLER_TREE_ROOT/packages" "$XDG_DATA_HOME/remuda/mods/butler/packages"

cleanup() {
  EXIT_STATUS=$?
  if [ -n "$DAEMON_PID" ]; then
    "$REMUDA_BIN" -s "$SERVER" -e 'pcall(remuda.close, "butler")' >/dev/null 2>&1 || true
    kill "$DAEMON_PID" >/dev/null 2>&1 || true
    wait "$DAEMON_PID" >/dev/null 2>&1 || true
    DAEMON_PID=
  fi
  if [ "$EXIT_STATUS" -ne 0 ] && [ -f "$DAEMON_LOG" ]; then
    echo "private daemon log:"
    cat "$DAEMON_LOG"
  fi
  rm -rf "$SCRATCH_ROOT"
  exit "$EXIT_STATUS"
}
trap cleanup EXIT INT TERM

start_private_daemon() {
  "$REMUDA_BIN" -s "$SERVER" daemon >>"$DAEMON_LOG" 2>&1 &
  DAEMON_PID=$!
  ATTEMPT=0
  while ! python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(.1); s.connect(sys.argv[1])' "$SOCKET" >/dev/null 2>&1; do
    ATTEMPT=$((ATTEMPT + 1))
    if [ "$ATTEMPT" -ge 100 ] || ! kill -0 "$DAEMON_PID" >/dev/null 2>&1; then
      echo "private daemon did not bind $SOCKET"
      cat "$DAEMON_LOG"
      exit 1
    fi
    sleep 0.1
  done
}

start_private_daemon
"$REMUDA_BIN" -s "$SERVER" -e 'remuda._butler_argv = {"sh", "-c", "while read line; do :; done"}; remuda._butler_skip_relay = true' >/dev/null
"$REMUDA_BIN" -s "$SERVER" exec butler >/dev/null
ATTEMPT=0
while ! "$REMUDA_BIN" -s "$SERVER" -e 'return remuda._butler_bus ~= nil' | grep -qx true; do
  ATTEMPT=$((ATTEMPT + 1))
  if [ "$ATTEMPT" -ge 50 ]; then echo "Butler lifecycle did not start"; exit 1; fi
  sleep 0.1
done

set +e
PREPATCH_OUTPUT=$("$REMUDA_BIN" -s "$SERVER" -e "return dofile('$BUTLER_TREE_ROOT/tests/session_tree.lua')" 2>&1)
PREPATCH_STATUS=$?
set -e
if [ "$EXPECT" = red ]; then
  if [ "$PREPATCH_STATUS" -eq 0 ]; then
    echo "expected the unmodified roster renderer to fail the hierarchy acceptance test"
    echo "$PREPATCH_OUTPUT"
    exit 1
  fi
  echo "EXPECTED RED (exit $PREPATCH_STATUS): $PREPATCH_OUTPUT"
else
  if [ "$PREPATCH_STATUS" -ne 0 ]; then
    echo "$PREPATCH_OUTPUT"
    exit "$PREPATCH_STATUS"
  fi
  echo "$PREPATCH_OUTPUT"
fi

ROSTER=$("$REMUDA_BIN" -s "$SERVER" butler sessions)
echo "$ROSTER"
if printf '%s\n' "$ROSTER" | grep -n '^$' >/dev/null; then
  echo "actual CLI roster contains a blank spacer row"
  exit 1
fi
printf '%s\n' "$ROSTER" | grep -F '  depth-1' >/dev/null
echo PASS
