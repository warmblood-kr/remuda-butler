#!/usr/bin/env bash
# Run the diagnostics relay fixture inside the pinned core for remuda.json.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
source "$REPO/tests/core_ref.sh"
core_ref_check
T=$(mktemp -d /tmp/bdm.XXXXXX)
T=$(cd "$T" && pwd -P)
S=bdm
export HOME=$T/home XDG_CONFIG_HOME=$T/config XDG_DATA_HOME=$T/data
export REMUDA_RUNTIME_DIR=$T/run REMUDA_NO_UPDATE_CHECK=1
export HOSTNAME=diagnostics-matrix-test-host
BUTLER_LUA_FILES=$(cd "$REPO" && ls packages/butler/*.lua packages/butler/*/*.lua)
export BUTLER_LUA_FILES
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$REMUDA_RUNTIME_DIR"
cleanup() {
  "$REMUDA_BIN" -s "$S" stop -f >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT INT TERM

"$REMUDA_BIN" -s "$S" daemon >"$T/daemon.log" 2>&1 &
for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$S.sock ]] && break; sleep 0.1; done
[[ -S $REMUDA_RUNTIME_DIR/remuda/$S.sock ]] || { cat "$T/daemon.log" >&2; exit 1; }
cd "$REPO"
"$REMUDA_BIN" -s "$S" -e 'dofile("tests/butler_diagnostics_matrix.lua")'
