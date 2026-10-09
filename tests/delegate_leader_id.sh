#!/usr/bin/env bash
# A member delegates without --leader: its caller ULID must resolve to its
# alias before Butler looks in its alias-keyed live-agent table.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
SCRATCH=$(mktemp -d /tmp/bdli.XXXXXX)
SCRATCH=$(cd "$SCRATCH" && pwd -P)
SERVER=bdli
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

lua 'remuda._butler_argv = {"sleep", "60"}; remuda._butler_skip_relay = true; remuda.exec("butler")' >/dev/null
for _ in $(seq 50); do
  lua 'return remuda._butler_agent_builders ~= nil' | grep -qx true && break
  sleep 0.1
done
lua 'remuda._butler_agent_builders.fake = function() return {"sleep", "60"} end; remuda._butler_launch("fake", "member")' >/dev/null
lua "return remuda._butler_command_run('topic', {'topic','delegate','child','--agent','fake','delegated task'}, {kind='session',session='member',instance_id=remuda._butler_bus.agents.member.instance_id})" >/dev/null ||
  fail "member delegation without --leader rejected its caller ULID"

PARENT=$(lua 'return remuda._butler_bus.agents.child and remuda._butler_bus.agents.child.parent or "missing"')
[[ $PARENT == member ]] || fail "child parent was '$PARENT', not resolved caller alias 'member'"
echo PASS
