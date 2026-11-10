#!/usr/bin/env bash
# Native SQL is mandatory: this gate must never turn unavailable into SKIP.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
REMUDA_BIN=${REMUDA_BIN:-remuda}
CORE_REF=${REMUDA_SQL_CORE_REF:-66138e39db21c8f7d069589c779bf6ac589f777c}
source "$REPO/tests/core_ref.sh"
core_ref_check
source "$REPO/tests/lib/isolated_env.sh"
isolated_env_prepare bip bip
export REMUDA_NO_UPDATE_CHECK=1
mkdir -p "$XDG_DATA_HOME/remuda/mods/butler"
cp "$REPO/extension.toml" "$XDG_DATA_HOME/remuda/mods/butler/extension.toml"
cp -R "$REPO/packages" "$XDG_DATA_HOME/remuda/mods/butler/packages"
cp "$REPO/tests/lib/qa_inbox_sql_owner.lua" "$XDG_DATA_HOME/remuda/mods/butler/packages/butler/init.lua"
cd "$REPO"
"$REMUDA_BIN" -s "$S" daemon >"$T/daemon.log" 2>&1 &
ISOLATED_DAEMON_PID=$!
for _ in $(seq 50); do [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] && break; sleep 0.1; done
[[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] || { cat "$T/daemon.log" >&2; exit 1; }
isolated_env_check_daemon || { cat "$T/daemon.log" >&2; exit 1; }
"$REMUDA_BIN" -s "$S" exec butler
