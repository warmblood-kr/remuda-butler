#!/usr/bin/env bash
# Throwaway daemon only; direct-handler callers model the daemon's native
# session classification, independently of the installed core version.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d /tmp/bci.XXXXXX)
T=$(cd "$T" && pwd -P); S=bci
export REMUDA_RUNTIME_DIR=$T/run XDG_DATA_HOME=$T/data XDG_CONFIG_HOME=$T/config HOME=$T/home
export REMUDA_BUTLER_PROJECT_HOME=$T/projects
unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG
# The daemon was started with a member-like environment; this must not select
# the CLI principal.
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
  function remuda._t(args, caller) return remuda._extension_commands.butler(args, caller) end" >/dev/null
fail() { echo "FAIL: $*"; exit 1; }
expect() { # label lua-expression pattern
  local got; got=$(lua "return $2") || true
  [[ $got == *"$3"* ]] || fail "$1: got '$got', want '*$3*'"
  echo "ok - $1"
}

expect "outside caller is the transitional operator path" \
  "(remuda._t({'send', 'm1', 'hello'}, {kind = 'outside'}) and remuda._t({'inbox', 'm1'}, {kind = 'outside'}))" "from local/operator"
expect "outside send-to-leader names the operator" \
  "remuda._t({'send-to-leader', 'done'}, {kind = 'outside'})" "operator has no leader"
expect "registered session resolves its own inbox without launch metadata" \
  "remuda._t({'inbox'}, {kind = 'session', session = 'm1'})" "inbox empty"
expect "caller metadata cannot override the registered session" \
  "remuda._t({'inbox'}, {kind = 'session', session = 'm1', env = {REMUDA_BUTLER_AGENT_ID = 'butler'}})" "inbox empty"
expect "unregistered managed session refuses with a next step" \
  "remuda._t({'inbox'}, {kind = 'session', session = 'unregistered'})" "Next:"
expect "old core without caller kind refuses with a next step" \
  "remuda._t({'inbox'}, {env = {REMUDA_BUTLER_AGENT_ID = 'm1'}})" "Next:"
# MCP paths (not the CLI verbs) also resolve a registered capability token to a member;
# an unregistered capability with no native kind is "outside"; a native kind takes precedence.
lua "local a = remuda._butler_bus.agents.m1; remuda._butler_bus.tokens['tok-m1'] = { id = a.id, generation = a.session_start_marker }" >/dev/null
expect "a registered MCP capability names the member" \
  "remuda._butler_identity.caller_name({ capability = 'tok-m1' })" "m1"
expect "an unregistered capability remains outside" \
  "remuda._butler_identity.caller_name({ capability = 'nope' })" "outside"
echo PASS
