#!/usr/bin/env bash
# Run the Lua relay parity tests inside the pinned core so they use remuda.json.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
T=$(cd "$(mktemp -d /tmp/bmr.XXXXXX)" && pwd -P)
S=bmr
export HOME=$T/home XDG_CONFIG_HOME=$T/config XDG_DATA_HOME=$T/data
export REMUDA_RUNTIME_DIR=$T/run REMUDA_NO_UPDATE_CHECK=1
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
"$REMUDA_BIN" -s "$S" -e 'dofile("tests/butler_matrix_relay.lua")'
