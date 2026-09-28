#!/usr/bin/env bash
# `remuda butler` commands act only on the caller's forwarded env, never on
# the daemon's own. Throwaway daemon only; the handler is called directly with
# an explicit caller table, so this does not depend on the installed core.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d /tmp/bci.XXXXXX); S=bci
export REMUDA_RUNTIME_DIR=$T/run XDG_DATA_HOME=$T/data XDG_CONFIG_HOME=$T/config HOME=$T/home
export REMUDA_BUTLER_PROJECT_HOME=$T/projects
unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG
# The trap this guards against: a daemon born inside an agent session.
export REMUDA_BUTLER_AGENT_ID=butler REMUDA_BUTLER_SESSION_NAME=butler
mkdir -p "$XDG_DATA_HOME/remuda/mods/butler" "$HOME"
tar -c -C "$REPO" extension.toml packages | tar -x -C "$XDG_DATA_HOME/remuda/mods/butler"
trap 'remuda -s $S stop -f >/dev/null 2>&1 || true; rm -rf "$T"' EXIT
remuda -s "$S" daemon </dev/null >/dev/null 2>&1 &
for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$S.sock ]] && break; sleep 0.1; done
lua() { remuda -s "$S" -e "$1" 2>&1; }
lua "remuda._butler_argv = {'sleep', '100'}; remuda.exec('butler')" >/dev/null
for _ in $(seq 50); do
  if lua 'return remuda._butler_agent_builders ~= nil' | grep -qx true; then break; fi
  sleep 0.1
done
lua "
  remuda._butler_agent_builders.fake = function() return {'sleep', '100'} end
  remuda._butler_launch('fake', 'm1')
  function remuda._t(args, env) return remuda._extension_commands.butler(args, { env = env }) end" >/dev/null
fail() { echo "FAIL: $*"; exit 1; }
expect() { # label lua-expression pattern
  local got; got=$(lua "return $2") || true
  [[ $got == *"$3"* ]] || fail "$1: got '$got', want '*$3*'"
  echo "ok - $1"
}

expect "env-less inbox is refused, not read as the daemon's identity" \
  "remuda._t({'inbox'}, {})" "no Butler identity"
expect "env-less send is attributed to the operator" \
  "(remuda._t({'send', 'm1', 'hello'}, {}) and remuda._t({'inbox'}, {REMUDA_BUTLER_AGENT_ID = 'm1'}))" "from local/operator"
expect "env-less send-to-leader names the operator" \
  "remuda._t({'send-to-leader', 'done'}, {})" "operator has no leader"
expect "a member's forwarded env picks its own inbox" \
  "remuda._t({'inbox'}, {REMUDA_BUTLER_AGENT_ID = 'm1'})" "inbox empty"
expect "an empty AGENT_ID falls through to SESSION_NAME" \
  "remuda._t({'inbox'}, {REMUDA_BUTLER_AGENT_ID = '', REMUDA_BUTLER_SESSION_NAME = 'm1'})" "inbox empty"
expect "empty identity vars are the operator" \
  "remuda._t({'inbox'}, {REMUDA_BUTLER_AGENT_ID = '', REMUDA_BUTLER_SESSION_NAME = ''})" "no Butler identity"
echo PASS
