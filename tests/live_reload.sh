#!/usr/bin/env bash
# Replays the live legacy -> lifecycle transition in a throwaway daemon, then
# reloads twice more and rolls back. Never touches the default daemon: every
# call carries a private REMUDA_RUNTIME_DIR and its own -s server name.
#   usage: tests/live_reload.sh [OLD_REF]   (OLD_REF defaults to origin/main)
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
OLD_REF=${1:-origin/main}
T=$(mktemp -d /tmp/brl.XXXXXX)  # short: the socket path must fit sun_path
S=brl
export REMUDA_RUNTIME_DIR=$T/run XDG_DATA_HOME=$T/data XDG_CONFIG_HOME=$T/config
export HOME=$T/home REMUDA_BUTLER_PROJECT_HOME=$T/projects REMUDA_BUTLER_SERVER=$S
unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG
MOD=$XDG_DATA_HOME/remuda/mods/butler
mkdir -p "$MOD" "$HOME" "$XDG_CONFIG_HOME/remuda/butler"
# A dead homeserver keeps the relay helper alive in its retry loop, so live
# relay processes can be counted by the token path unique to this run.
TOKEN=$XDG_CONFIG_HOME/remuda/butler/token
echo fake-token >"$TOKEN"
printf 'http://127.0.0.1:9\n!room:x\n@butler:x\n' >"$XDG_CONFIG_HOME/remuda/butler/config"
echo '{"since": "s0"}' >"$XDG_CONFIG_HOME/remuda/butler/config.since"  # skip the unguarded first sync
trap 'remuda -s $S stop -f >/dev/null 2>&1 || true; pkill -f "$TOKEN" || true; rm -rf "$T"' EXIT

lua() { remuda -s "$S" -e "$1"; }
install_files() { rm -rf "$MOD"; mkdir -p "$MOD"; "$@" | tar -x -C "$MOD"; }
old_files() { install_files git -C "$REPO" archive "$OLD_REF" extension.toml packages; }
new_files() { install_files tar -c -C "$REPO" extension.toml packages; }
fail() { echo "FAIL: $*"; exit 1; }
start_daemon() {
  remuda -s "$S" daemon </dev/null >>"$T/daemon.log" 2>&1 &
  for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$S.sock ]] && return; sleep 0.1; done
  fail "daemon never bound"
}

SNAPSHOT='
local function n(e) return #(remuda.hooks[e] or {}) end
local s = 0 for _ in pairs(remuda.schedules) do s = s + 1 end
local live = {} for _, x in ipairs(remuda.ls()) do if x.alive then live[#live + 1] = x.name end end
table.sort(live)
local bus = remuda._butler_bus
return string.format("boots=%d hooks=%d,%d,%d,%d schedules=%d sessions=%s member=%s mail=%d bus=%s",
  remuda.event_counts()["butler-start"] or 0, n("session_exited"), n("butler-compaction-submit"), n("butler-matrix-line"), n("butler-matrix-submit"),
  s, table.concat(live, ","), tostring(bus.agents.m1 ~= nil), #(bus.inboxes.m1 or {}), tostring(bus))'
relays() { pgrep -f "$TOKEN" | wc -l | tr -d ' '; }
# Session processes by pid: a restarted butler or member would change these.
pids() { pgrep -f 'sleep 10000[12]' | sort | tr '\n' , ; }
# The lifecycle entry boots from a deferred process event; give it a moment.
settle() { sleep 1; }
check() { # label expected-snapshot
  local got; got="$(lua "$SNAPSHOT") relays=$(relays) pids=$(pids)"
  echo "$1: $got"
  [[ "$got" == "$2" ]] || fail "$1: expected '$2'"
}

echo "== legacy install ($OLD_REF), exec'd the old way"
old_files
# Started explicitly: an auto-started daemon currently dies when the relay
# spawns (under investigation in core), unrelated to reload.
start_daemon
lua "remuda._butler_argv = {'sleep', '100001'}; remuda._butler_reconcile_interval = 0.5; remuda.exec('butler')"
lua "remuda._butler_agent_builders.fake = function() return {'sleep', '100002'} end
     remuda._butler_launch('fake', 'm1'); remuda._butler_send('butler', 'm1', 'kept across reload')"
settle
echo "legacy: $(lua "$SNAPSHOT") relays=$(relays)"
BASE=$(lua "$SNAPSHOT" | sed 's/.* bus=//')
EXPECT="hooks=1,1,1,1 schedules=1 sessions=butler,m1 member=true mail=2 bus=$BASE relays=1 pids=$(pids)"

echo "== swap in new files, reload x3"
new_files
for i in 1 2 3; do
  lua "remuda.reload('butler')"; settle
  check "reload $i" "boots=$i $EXPECT"
  relay=$(pgrep -f "$TOKEN"); [[ $i == 1 || $relay == "$last_relay" ]] || fail "relay restarted on reload $i"
  last_relay=$relay
done
remuda -s "$S" butler sessions | grep -q m1 || fail "'remuda butler sessions' lost m1"
remuda -s "$S" butler inbox m1 | grep -q 'kept across reload' || fail "m1 mail lost"

echo "== rollback to $OLD_REF (legacy code spawns its relay unconditionally)"
old_files
lua "remuda.kill(remuda._butler_relay); remuda.exec('butler')"; settle
check "rollback" "boots=3 ${EXPECT/mail=2/mail=0}"

echo "== roll forward again"
new_files
lua "remuda.reload('butler')"; settle
check "roll forward" "boots=4 ${EXPECT/mail=2/mail=0}"

echo "== cold boot through 'remuda butler' on a fresh daemon"
remuda -s "$S" stop -f >/dev/null 2>&1; pkill -f "$TOKEN" || true
start_daemon
lua "remuda._butler_argv = {'sleep', '100001'}"
remuda -s "$S" butler --headless; settle
lua "$SNAPSHOT" | grep -q 'boots=1 hooks=1,1,1,1 schedules=1 sessions=butler ' || fail "cold boot: $(lua "$SNAPSHOT")"
[[ $(relays) == 1 ]] || fail "cold boot relays=$(relays)"
echo PASS
