#!/usr/bin/env bash
# Offline workdir fixtures only; no live configuration or agent restart.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
source "$REPO/tests/core_ref.sh"
core_ref_check
command -v codex >/dev/null
T=$(mktemp -d /tmp/bcc.XXXXXX)
T=$(cd "$T" && pwd -P)
export HOME=$T/home XDG_CONFIG_HOME=$T/config XDG_DATA_HOME=$T/data
export REMUDA_RUNTIME_DIR=$T/run REMUDA_NO_UPDATE_CHECK=1
export REMUDA_SESSION_CAPABILITY=fixture-session-capability-not-to-save
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$REMUDA_RUNTIME_DIR"
cleanup() {
  "$REMUDA_BIN" -s bcc stop -f >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT INT TERM
"$REMUDA_BIN" -s bcc daemon >"$T/daemon.log" 2>&1 &
for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/bcc.sock ]] && break; sleep 0.1; done
[[ -S $REMUDA_RUNTIME_DIR/remuda/bcc.sock ]] || { cat "$T/daemon.log" >&2; exit 1; }
cd "$REPO"
"$REMUDA_BIN" -s bcc -e 'dofile("tests/butler_coordination_config.lua")'
