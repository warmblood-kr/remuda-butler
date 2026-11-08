#!/usr/bin/env bash
# Run the diagnostics relay fixture inside the pinned core for remuda.json.
# The suite replaces daemon globals, so it runs only in a fresh disposable
# daemon inside an owned 0700 envelope; see tests/lib/isolated_env.sh.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
REMUDA_BIN=${REMUDA_BIN:-remuda}
source "$REPO/tests/core_ref.sh"
core_ref_check
source "$REPO/tests/lib/isolated_env.sh"
isolated_env_prepare bdm bdm

export REMUDA_NO_UPDATE_CHECK=1
export HOSTNAME=diagnostics-matrix-test-host
BUTLER_LUA_FILES=$(cd "$REPO" && ls packages/butler/*.lua packages/butler/*/*.lua)
export BUTLER_LUA_FILES

# The daemon inherits this cwd: the suite and its guard are resolved relatively.
cd "$REPO"
"$REMUDA_BIN" -s "$S" daemon >"$T/daemon.log" 2>&1 &
for _ in $(seq 50); do [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] && break; sleep 0.1; done
[[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] || { cat "$T/daemon.log" >&2; exit 1; }
isolated_env_check_daemon || { cat "$T/daemon.log" >&2; exit 1; }

"$REMUDA_BIN" -s "$S" -e 'dofile("tests/butler_diagnostics_matrix.lua")'
