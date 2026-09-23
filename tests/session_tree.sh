#!/bin/sh
# Private run: REMUDA_BIN=/Users/jeongsoopark/projects/session_reallocation/worktrees/remuda-ulid/target/debug/remuda sh tests/session_tree.sh
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
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/remuda/extensions/butler" "$REMUDA_RUNTIME_DIR"
python3 "$BUTLER_TREE_ROOT/tests/check_session_tree_patch.py"
cp "$BUTLER_TREE_ROOT/extension.toml" "$XDG_DATA_HOME/remuda/extensions/butler/extension.toml"
cp -R "$BUTLER_TREE_ROOT/packages" "$XDG_DATA_HOME/remuda/extensions/butler/packages"

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
"$REMUDA_BIN" -s "$SERVER" -e 'remuda._butler_argv = {"sh", "-c", "while read line; do :; done"}; remuda._butler_skip_relay = true; remuda.exec("butler"); return "Butler loaded with a private stub adapter"' >/dev/null
IMAGE_BEFORE=$("$REMUDA_BIN" -s "$SERVER" -e 'remuda._session_tree_image_identity = remuda.ulid(); return remuda._session_tree_image_identity')
PID_BEFORE=$DAEMON_PID

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

# This eval loads the narrow renderer only. The package and daemon are not reloaded.
PATCH_MARKER=$("$REMUDA_BIN" -s "$SERVER" -e "dofile('$BUTLER_TREE_ROOT/tests/session_tree_patch.lua'); remuda._session_tree_hotpatch_marker = remuda.ulid(); return remuda._session_tree_hotpatch_marker")
PATCHED_OUTPUT=$("$REMUDA_BIN" -s "$SERVER" -e "return dofile('$BUTLER_TREE_ROOT/tests/session_tree.lua')")
echo "$PATCHED_OUTPUT"
ROSTER=$("$REMUDA_BIN" -s "$SERVER" butler sessions)
echo "$ROSTER"
if printf '%s\n' "$ROSTER" | grep -n '^$' >/dev/null; then
  echo "actual CLI roster contains a blank spacer row"
  exit 1
fi
printf '%s\n' "$ROSTER" | grep -F '  depth-1' >/dev/null
IMAGE_AFTER=$("$REMUDA_BIN" -s "$SERVER" -e 'return remuda._session_tree_image_identity')
MARKER_AFTER=$("$REMUDA_BIN" -s "$SERVER" -e 'return remuda._session_tree_hotpatch_marker')
if [ "$PID_BEFORE" != "$DAEMON_PID" ] || ! kill -0 "$PID_BEFORE" >/dev/null 2>&1 || [ "$IMAGE_BEFORE" != "$IMAGE_AFTER" ] || [ "$PATCH_MARKER" != "$MARKER_AFTER" ]; then
  echo "daemon process or Lua image identity changed during eval/hot patch/CLI"
  exit 1
fi
echo "PRIVATE_PID_BEFORE=$PID_BEFORE PRIVATE_PID_AFTER=$DAEMON_PID"
echo "PRIVATE_IMAGE_IDENTITY_BEFORE=$IMAGE_BEFORE PRIVATE_IMAGE_IDENTITY_AFTER=$IMAGE_AFTER"
echo "PRIVATE_PATCH_MARKER_BEFORE_RESTART=$PATCH_MARKER PRIVATE_PATCH_MARKER_AFTER_LIST=$MARKER_AFTER"

# The isolated Butler package owns a live terminal. Close only that scratch
# session so the daemon's graceful restart precondition is satisfied.
"$REMUDA_BIN" -s "$SERVER" -e 'remuda.close("butler"); return "closed test session"' >/dev/null
"$REMUDA_BIN" -s "$SERVER" restart
wait "$DAEMON_PID" || true
DAEMON_PID=
start_private_daemon
"$REMUDA_BIN" -s "$SERVER" -e 'remuda._butler_argv = {"sh", "-c", "while read line; do :; done"}; remuda._butler_skip_relay = true; remuda.exec("butler"); return "fresh Butler package loaded"' >/dev/null
FRESH_KIND=$("$REMUDA_BIN" -s "$SERVER" -e 'return tostring(type(remuda._butler_sessions))')
FRESH_MARKER=$("$REMUDA_BIN" -s "$SERVER" -e 'return tostring(remuda._session_tree_hotpatch_marker or "nil")')
FRESH_IMAGE=$("$REMUDA_BIN" -s "$SERVER" -e 'return remuda.ulid()')
FRESH_ACCEPTANCE=$("$REMUDA_BIN" -s "$SERVER" -e "return dofile('$BUTLER_TREE_ROOT/tests/session_tree.lua')")
if [ "$FRESH_KIND" != "function" ] || [ "$FRESH_MARKER" != "nil" ] || [ "$FRESH_IMAGE" = "$IMAGE_BEFORE" ]; then
  echo "fresh Butler package load retained transient hot-patch state"
  exit 1
fi
echo "$FRESH_ACCEPTANCE"
echo "AFTER_RESTART_RENDERER_TYPE=$FRESH_KIND PATCH_MARKER=$FRESH_MARKER FRESH_IMAGE_ID=$FRESH_IMAGE"
