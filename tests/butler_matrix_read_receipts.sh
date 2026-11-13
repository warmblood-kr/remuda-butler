#!/usr/bin/env bash
# Run the Matrix read-receipt L3 suite inside the pinned core, in a fresh
# disposable daemon and owned 0700 envelope. No live daemon or homeserver.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
REMUDA_BIN=${REMUDA_BIN:-remuda}
source "$REPO/tests/core_ref.sh"
core_ref_check
source "$REPO/tests/lib/isolated_env.sh"
isolated_env_prepare bmrr bmrr

export REMUDA_NO_UPDATE_CHECK=1
export HOSTNAME=matrix-test-host

BUTLER_LUA_FILES=$(cd "$REPO" && ls packages/butler/*.lua packages/butler/*/*.lua)
export BUTLER_LUA_FILES

cd "$REPO"
"$REMUDA_BIN" -s "$S" daemon >"$T/daemon.log" 2>&1 &
ISOLATED_DAEMON_PID=$!
for _ in $(seq 50); do [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] && break; sleep 0.1; done
[[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] || { cat "$T/daemon.log" >&2; exit 1; }
isolated_env_check_daemon || { cat "$T/daemon.log" >&2; exit 1; }

"$REMUDA_BIN" -s "$S" -e 'dofile("tests/butler_matrix_read_receipts.lua")'
