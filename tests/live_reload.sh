#!/usr/bin/env bash
# Replays the legacy -> lifecycle transition using only a private daemon.
#   tests/live_reload.sh [OLD_REF]       explicit daemon
#   AUTOSTART=1 tests/live_reload.sh     CLI-auto-started daemon
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
# Default: the last legacy (pre-lifecycle) Butler. origin/main is lifecycle
# since #21, so it no longer replays the transition and its boot is miscounted.
OLD_REF=${1:-8950e51^}
T=$(mktemp -d /tmp/brl.XXXXXX)
S=brl
# This run's own fake-process durations: a global `sleep 10000[12]` pgrep saw
# every concurrent run's sessions and failed the pid check at random.
# A caller that cleans up after this run passes its id (remuda#148).
ID=${LIVE_RELOAD_ID:-$((RANDOM % 90000 + 10000))}
export REMUDA_RUNTIME_DIR=$T/run XDG_DATA_HOME=$T/data XDG_CONFIG_HOME=$T/config
export HOME=$T/home REMUDA_BUTLER_PROJECT_HOME=$T/projects REMUDA_BUTLER_SERVER=$S
unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG
MOD=$XDG_DATA_HOME/remuda/mods/butler
mkdir -p "$MOD" "$HOME" "$XDG_CONFIG_HOME/remuda/butler"
TOKEN=$XDG_CONFIG_HOME/remuda/butler/token
RELAYS=0
if [[ -z ${AUTOSTART:-} ]]; then
  RELAYS=1
  echo fake-token >"$TOKEN"
  printf 'http://127.0.0.1:9\n!room:x\n@butler:x\n' >"$XDG_CONFIG_HOME/remuda/butler/config"
  echo '{"since": "s0"}' >"$XDG_CONFIG_HOME/remuda/butler/config.since"
fi
trap 'remuda -s "$S" stop -f >/dev/null 2>&1 || true; pkill -f "$TOKEN" >/dev/null 2>&1 || true; rm -rf "$T"' EXIT

lua() { remuda -s "$S" -e "$1"; }
install_files() { rm -rf "$MOD"; mkdir -p "$MOD"; "$@" | tar -x -C "$MOD"; }
old_files() { install_files git -C "$REPO" archive "$OLD_REF" extension.toml packages; }
new_files() { install_files tar -c -C "$REPO" extension.toml packages; }
fail() { echo "FAIL: $*" >&2; exit 1; }
start_daemon() {
  [[ -n ${AUTOSTART:-} ]] && return
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
local member = bus.agents.m1
local inbox = member and bus.inboxes[member.id] or {}
return string.format("boots=%d hooks=%d,%d,%d,%d schedules=%d sessions=%s member=%s mail=%d bus=%s",
  remuda.event_counts()["butler-start"] or 0, n("session_exited"), n("butler-compaction-submit"), n("butler-matrix-line"), n("butler-matrix-submit"),
  s, table.concat(live, ","), tostring(member ~= nil), #inbox, tostring(bus))'
relays() { (pgrep -f "$TOKEN" || true) | wc -l | tr -d ' '; }
pids() { (pgrep -f "sleep ${ID}[12]\$" || true) | sort | tr '\n' ','; }
settle() { sleep 1; }
check() {
  local got
  got="$(lua "$SNAPSHOT") relays=$(relays) pids=$(pids)"
  echo "$1: $got"
  [[ "$got" == "$2" ]] || fail "$1: expected '$2'"
}

echo "== legacy install ($OLD_REF)"
old_files
start_daemon
lua "remuda._butler_argv = {'sleep', '${ID}1'}; remuda._butler_reconcile_interval = 0.5"
remuda -s "$S" butler --headless
lua "remuda._butler_agent_builders.fake = function() return {'sleep', '${ID}2'} end
     remuda._butler_launch('fake', 'm1'); remuda._butler_send('butler', 'm1', 'kept across reload')"
settle
echo "legacy: $(lua "$SNAPSHOT") relays=$(relays)"
BASE=$(lua "$SNAPSHOT" | sed 's/.* bus=//')
EXPECT="hooks=1,1,1,1 schedules=2 sessions=butler,m1 member=true mail=2 bus=$BASE relays=$RELAYS pids=$(pids)"

echo "== swap in lifecycle files, reload x3"
new_files
for i in 1 2 3; do
  lua "remuda.reload('butler')"; settle
  check "reload $i" "boots=$i $EXPECT"
  relay=$(pgrep -f "$TOKEN" || true)
  [[ $i == 1 || $relay == "$last_relay" ]] || fail "relay restarted on reload $i"
  last_relay=$relay
done
remuda -s "$S" butler sessions | grep -q m1 || fail "'remuda butler sessions' lost m1"
remuda -s "$S" butler inbox m1 | grep -q 'kept across reload' || fail "m1 mail lost"

echo "== rollback to $OLD_REF"
old_files
lua "if remuda._butler_relay then remuda.kill(remuda._butler_relay) end; remuda.exec('butler')"
settle
check "rollback" "boots=3 ${EXPECT/mail=2/mail=0}"

echo "== roll forward again"
new_files
lua "remuda.reload('butler')"; settle
check "roll forward" "boots=4 ${EXPECT/mail=2/mail=0}"

echo "== tight reload loop: one boot per reload, nothing duplicated"
lua "for _ = 1, 5 do remuda.reload('butler') end"
for _ in 1 2 3 4 5; do lua "remuda.reload('butler')"; done
settle
check "tight x10" "boots=14 ${EXPECT/mail=2/mail=0}"
[[ $(lua 'return #(remuda.hooks["butler-start"] or {})') == 1 ]] || fail "butler-start hook duplicated"

echo "== cold boot through remuda butler"
remuda -s "$S" stop -f >/dev/null 2>&1
pkill -f "$TOKEN" >/dev/null 2>&1 || true
start_daemon
lua "remuda._butler_argv = {'sleep', '${ID}1'}"
remuda -s "$S" butler --headless; settle
lua "$SNAPSHOT" | grep -q 'boots=1 hooks=1,1,1,1 schedules=2 sessions=butler ' || \
  fail "cold boot: $(lua "$SNAPSHOT")"
[[ $(relays) == "$RELAYS" ]] || fail "cold boot relays=$(relays)"
echo PASS
