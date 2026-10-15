#!/usr/bin/env bash
# Offline workdir fixtures only; no live configuration or agent restart.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
source "$REPO/tests/core_ref.sh"
core_ref_check
# Mode is decided here, once (tests/lib/config_test_mode.sh), never inside Lua:
# full (native Codex answering), or the codexless subset when Codex is not
# installed. A present-but-broken Codex fails; REQUIRE_NATIVE_CODEX=1 makes an
# absent Codex fail too. CI without Codex only exercises the subset; the full
# native gate is a local/QA requirement.
source "$REPO/tests/lib/config_test_mode.sh"
BUTLER_CONFIG_TEST_MODE=$(config_test_mode) || exit 1
export BUTLER_CONFIG_TEST_MODE
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
