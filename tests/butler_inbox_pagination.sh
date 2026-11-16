#!/usr/bin/env bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
REMUDA_BIN=${REMUDA_BIN:-remuda}
source "$REPO/tests/lib/isolated_env.sh"
isolated_env_prepare bip bip
# Preserve the private fixture for inspection; do not remove mailbox data.
trap '"$REMUDA_BIN" -s "$S" stop -f --yes >/dev/null 2>&1 || true; wait "$ISOLATED_DAEMON_PID" || true; printf "preserved test directory: %s\n" "$T"' EXIT
export REMUDA_NO_UPDATE_CHECK=1
mkdir -p "$XDG_DATA_HOME/remuda/mods/butler"
cp "$REPO/extension.toml" "$XDG_DATA_HOME/remuda/mods/butler/extension.toml"
cp -R "$REPO/packages" "$XDG_DATA_HOME/remuda/mods/butler/packages"
"$REMUDA_BIN" -s "$S" daemon >"$T/daemon.log" 2>&1 &
ISOLATED_DAEMON_PID=$!
for _ in $(seq 50); do [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] && break; sleep 0.1; done
[[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] || { cat "$T/daemon.log"; exit 1; }
isolated_env_check_daemon
"$REMUDA_BIN" -s "$S" -e 'remuda._butler_argv={"sh","-c","sleep 60"}; remuda._butler_skip_relay=true; return remuda.exec("butler")' >/dev/null
"$REMUDA_BIN" -s "$S" -e "return dofile('$REPO/tests/butler_inbox_pagination.lua')"
