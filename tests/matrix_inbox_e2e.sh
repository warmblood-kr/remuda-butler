#!/usr/bin/env bash
# S1 end-to-end characterization: one eligible Matrix event reaches the real
# relay, the real SQLite inbox and the notification policy, is read, then
# survives a daemon restart and a replay of the same event without a second
# membership or unread resurrection.
#
# Substitution: tests/support/fake_http.lua replaces the HTTP transport and
# the scheduler clock (remuda.http, remuda.schedule, remuda.cancel, request
# clock), so relay retry/timer cadence runs on this harness tick. The relay,
# state persistence, SQLite inbox, mail delivery, notice policy and read path
# are the product code. This is a characterization test: it does not enable the
# relay shadow wire, does not make the shadow cursor authoritative, and its
# happy path proves observed storage results only, not cursor atomicity.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
REMUDA_BIN=${REMUDA_BIN:-remuda}
CORE_REF=${REMUDA_SQL_CORE_REF:-8dc35489db53c6aebfdf3f5aa1fbd91614b2c281}
source "$REPO/tests/core_ref.sh"
core_ref_check
source "$REPO/tests/lib/isolated_env.sh"
isolated_env_prepare mxe mxe
export REMUDA_NO_UPDATE_CHECK=1
export XDG_STATE_HOME="$T/state"
mkdir -m 700 "$XDG_STATE_HOME"

MOD="$XDG_DATA_HOME/remuda/mods/butler"
mkdir -p "$MOD"
cp "$REPO/extension.toml" "$MOD/extension.toml"
cp -R "$REPO/packages" "$MOD/packages"
cfg="$XDG_CONFIG_HOME/remuda/butler"
mkdir -p "$cfg"
printf 'test-token\n' > "$cfg/token"
cat > "$cfg/config" <<CFG
https://matrix.invalid
!room:example.org
@bot:example.org
@alice:example.org
false
30000
CFG
export REMUDA_BUTLER_TOKEN="$cfg/token"
export REMUDA_BUTLER_CONFIG="$cfg/config"
cd "$REPO"

start_daemon() {
  "$REMUDA_BIN" -s "$S" daemon >"$T/daemon.log" 2>&1 &
  ISOLATED_DAEMON_PID=$!
  for _ in $(seq 50); do [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] && break; sleep 0.1; done
  [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] || { cat "$T/daemon.log" >&2; exit 1; }
  isolated_env_check_daemon || { cat "$T/daemon.log" >&2; exit 1; }
}
stop_daemon() {
  "$REMUDA_BIN" -s "$S" stop -f --yes >/dev/null 2>&1 || true
  wait "$ISOLATED_DAEMON_PID" 2>/dev/null || true
  ISOLATED_DAEMON_PID=
}
cleanup() {
  stop_daemon
  isolated_env_cleanup
}
trap cleanup EXIT

run_phase() {
  "$REMUDA_BIN" -s "$S" -e "remuda._qa_phase='$1'; return dofile('$REPO/tests/lib/qa_matrix_inbox_e2e.lua')"
}

start_daemon
run_phase drive
echo "phase drive: relay started; observing the sync path"
sleep 20
run_phase check
stop_daemon

start_daemon
run_phase replay
echo "phase replay: same event served again after restart"
sleep 12
run_phase replay-check

echo "matrix inbox end-to-end: PASS"
