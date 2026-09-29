#!/usr/bin/env bash
# Closing a member must fire session_exited so Butler drops it from its
# roster.  Needs a Remuda core with warmblood-kr/remuda#109; older cores never
# emit on close and this fails.  All work is in a private daemon.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
SCRATCH=$(cd "$(mktemp -d /tmp/bcee.XXXXXX)" && pwd -P)
SERVER=bcee
export HOME=$SCRATCH/home XDG_CONFIG_HOME=$SCRATCH/config XDG_DATA_HOME=$SCRATCH/data
export REMUDA_RUNTIME_DIR=$SCRATCH/run REMUDA_NO_UPDATE_CHECK=1 REMUDA_BUTLER_PROJECT_HOME=$SCRATCH/projects
unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG REMUDA_BUTLER_AGENT_ID REMUDA_BUTLER_LEADER_ID REMUDA_BUTLER_SESSION_NAME
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/remuda/mods/butler" "$REMUDA_RUNTIME_DIR"
tar -c -C "$REPO" extension.toml packages | tar -x -C "$XDG_DATA_HOME/remuda/mods/butler"

cleanup() {
  "$REMUDA_BIN" -s "$SERVER" stop -f >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
lua() { "$REMUDA_BIN" -s "$SERVER" -e "$1"; }

"$REMUDA_BIN" -s "$SERVER" daemon >"$SCRATCH/daemon.log" 2>&1 &
for _ in $(seq 50); do
  [[ -S $REMUDA_RUNTIME_DIR/remuda/$SERVER.sock ]] && break
  sleep 0.1
done
[[ -S $REMUDA_RUNTIME_DIR/remuda/$SERVER.sock ]] || { cat "$SCRATCH/daemon.log" >&2; fail "private daemon did not bind"; }

lua "remuda._butler_argv = {'sleep', '60'}; remuda._butler_skip_relay = true; remuda._butler_session_trace_path = '$SCRATCH/butler.trace'; remuda.exec('butler')" >/dev/null
for _ in $(seq 50); do
  lua 'return remuda._butler_agent_builders ~= nil' | grep -qx true && break
  sleep 0.1
done
lua "remuda._butler_agent_builders.fake = function() return {'sleep', '60'} end
  remuda._close_exit_seen = {}
  remuda.on('session_exited', function(name) table.insert(remuda._close_exit_seen, name) end, { group = 'close-emits-exit' })
  remuda._butler_launch('fake', 'close-one')
  remuda._butler_launch('fake', 'close-two')
  remuda._butler_launch('fake', 'close-three')" >/dev/null

lua "remuda.close('close-one'); remuda.close('close-two'); remuda.close('close-three')" >/dev/null
for _ in $(seq 100); do
  SEEN=$(lua "return table.concat(remuda._close_exit_seen, ',')")
  [[ $SEEN == *close-one* && $SEEN == *close-two* && $SEEN == *close-three* ]] && break
  sleep 0.1
done

SEEN=$(lua "return table.concat(remuda._close_exit_seen, ',')")
BUTLER_SEEN=
if [[ -f $SCRATCH/butler.trace ]]; then
  BUTLER_SEEN=$(awk -F '\t' '$2 == "session_exited" { print $3 }' "$SCRATCH/butler.trace" | paste -sd, -)
fi
echo "generic session_exited: ${SEEN:-<none>}"
echo "butler session_exited: ${BUTLER_SEEN:-<none>}"
[[ $SEEN == *close-one* && $SEEN == *close-two* && $SEEN == *close-three* ]] ||
  fail "core did not emit session_exited for every closed session (needs remuda#109)"
echo PASS
