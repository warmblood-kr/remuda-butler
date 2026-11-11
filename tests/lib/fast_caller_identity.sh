#!/usr/bin/env bash
# Exercise caller attribution using a real member PTY and a private daemon.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
remuda_bin=$(command -v "${REMUDA_BIN:-remuda}")
t=$(mktemp -d /tmp/bci.XXXXXX)
t=$(cd "$t" && pwd -P)
server=bci
export REMUDA_RUNTIME_DIR=$t/run XDG_DATA_HOME=$t/data XDG_CONFIG_HOME=$t/config HOME=$t/home
export REMUDA_BUTLER_PROJECT_HOME=$t/projects REMUDA_NO_UPDATE_CHECK=1
unset REMUDA_SERVER REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG REMUDA_BUTLER_AGENT_ID REMUDA_BUTLER_LEADER_ID \
  REMUDA_BUTLER_SESSION_NAME REMUDA_BUTLER_AGENT_ALIAS REMUDA_BUTLER_AGENT_KIND REMUDA_SESSION_CAPABILITY
mkdir -p "$XDG_DATA_HOME/remuda/mods/butler" "$HOME" "$t/bin"
tar -c -C "$repo" extension.toml packages | tar -x -C "$XDG_DATA_HOME/remuda/mods/butler"
ln -s "$remuda_bin" "$t/bin/remuda"
export PATH="$t/bin:/usr/bin:/bin"
cleanup() { remuda -s "$server" stop -f >/dev/null 2>&1 || true; rm -rf "$t"; }
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
cat >"$t/member.sh" <<MEMBER
#!/bin/sh
while [ ! -e "$t/go" ]; do sleep 0.1; done
remuda -s $server butler inbox >"$t/own.out" 2>&1; echo \$? >"$t/own.rc"
remuda -s $server butler inbox butler >"$t/other.out" 2>&1; echo \$? >"$t/other.rc"
touch "$t/done"
sleep 1000
MEMBER
chmod +x "$t/member.sh"
remuda -s "$server" daemon </dev/null >"$t/daemon.log" 2>&1 &
for _ in $(seq 100); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$server.sock ]] && break; sleep 0.1; done
[[ -S $REMUDA_RUNTIME_DIR/remuda/$server.sock ]] || fail 'daemon did not start'
lua() { remuda -s "$server" -e "$1" 2>&1; }
lua "remuda._butler_argv = {'sleep', '1000'}; remuda.exec('butler')" >/dev/null
for _ in $(seq 100); do lua 'return remuda._butler_agent_builders ~= nil' | grep -qx true && break; sleep 0.1; done
lua "remuda._butler_agent_builders.fake = function() return {'$t/member.sh'} end; remuda._butler_launch('fake', 'm1')" >/dev/null
for _ in $(seq 150); do lua 'return remuda._butler_bus.agents.m1 ~= nil' | grep -qx true && break; sleep 0.1; done
lua 'return remuda._butler_bus.agents.m1 ~= nil' | grep -qx true || fail 'member m1 was not registered'
remuda -s "$server" butler send m1 'identity smoke message' >"$t/send.out" 2>&1 || fail "send: $(cat "$t/send.out")"
touch "$t/go"
for _ in $(seq 150); do [[ -e $t/done ]] && break; sleep 0.1; done
[[ -e $t/done ]] || fail 'member did not complete CLI calls'
[[ $(cat "$t/own.rc") == 0 ]] || fail "own inbox failed: $(cat "$t/own.out")"
grep -qF 'identity smoke message' "$t/own.out" || fail "own inbox missed message: $(cat "$t/own.out")"
[[ $(cat "$t/other.rc") != 0 ]] || fail "other inbox allowed: $(cat "$t/other.out")"
grep -qF 'agents may only read their own Butler inbox' "$t/other.out" || fail "wrong denial: $(cat "$t/other.out")"
echo 'real member caller identity: PASS'
