#!/usr/bin/env bash
# Replays the step 3 -> lifecycle-owned transition using a private daemon.
#   tests/live_reload.sh [OLD_REF]       explicit daemon
#   AUTOSTART=1 tests/live_reload.sh     CLI-auto-started daemon
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
# Default: step 3 Butler with imperative, manually purged registrations.
OLD_REF=${1:-2535f27}
T=$(mktemp -d /tmp/brl.XXXXXX)
T=$(cd "$T" && pwd -P)
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
RELAY_EXPECT=false
DAEMON_PID=
DAEMON_PIDS=()
OLD_RELAY_ID=
OLD_RELAY_PID=
OWN_RELAY_PID=
FOREIGN_RELAY_PID=
CHILD_PIDS=()
if [[ -z ${AUTOSTART:-} ]]; then
  echo fake-token >"$TOKEN"
  printf 'http://127.0.0.1:9\n!room:x\n@butler:x\n' >"$XDG_CONFIG_HOME/remuda/butler/config"
  echo '{"since": "s0"}' >"$XDG_CONFIG_HOME/remuda/butler/config.since"
fi
cleanup() {
  [[ ${REMUDA_RUNTIME_DIR:-} == "$T/run" ]] || { echo "refusing cleanup outside scratch runtime" >&2; return 1; }
  local pid killed=0 left=0 seen=" "
  local all_pids=("${CHILD_PIDS[@]}" "$OLD_RELAY_PID" "$OWN_RELAY_PID" "$FOREIGN_RELAY_PID" "${DAEMON_PIDS[@]}")
  for pid in "${all_pids[@]}"; do
    [[ -n "$pid" ]] || continue
    [[ "$seen" == *" $pid "* ]] && continue
    seen+="$pid "
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      killed=$((killed + 1))
    fi
  done
  for pid in "${DAEMON_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  sleep 0.1
  seen=" "
  for pid in "${all_pids[@]}"; do
    [[ -n "$pid" ]] || continue
    [[ "$seen" == *" $pid "* ]] && continue
    seen+="$pid "
    if kill -0 "$pid" >/dev/null 2>&1; then left=$((left + 1)); fi
  done
  rm -rf "$T"
  echo "resources cleaned: $killed killed / $left left"
  [[ $left -eq 0 ]] || { echo "FAIL: tracked process PIDs remain after cleanup" >&2; return 1; }
}
trap cleanup EXIT

lua() { remuda -s "$S" -e "$1"; }
install_files() { rm -rf "$MOD"; mkdir -p "$MOD"; "$@" | tar -x -C "$MOD"; }
old_files() { install_files git -C "$REPO" archive "$OLD_REF" extension.toml packages; }
new_files() { install_files tar -c -C "$REPO" extension.toml packages; }
fail() { echo "FAIL: $*" >&2; exit 1; }
start_daemon() {
  [[ -n ${AUTOSTART:-} ]] && return
  remuda -s "$S" daemon </dev/null >>"$T/daemon.log" 2>&1 &
  DAEMON_PID=$!
  DAEMON_PIDS+=("$DAEMON_PID")
  for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$S.sock ]] && return; sleep 0.1; done
  fail "daemon never bound"
}
record_autostart_daemon_pid() {
  [[ -n ${AUTOSTART:-} ]] || return 0
  local socket=$REMUDA_RUNTIME_DIR/remuda/$S.sock pid
  for _ in $(seq 50); do
    # The daemon holds the socket lock for its whole lifetime. lsof on the
    # socket path itself lists every Unix socket; the lock path identifies
    # only the daemon process that owns this endpoint.
    pid=$(lsof -t "$socket.lock" 2>/dev/null | head -n 1 || true)
    if [[ -n $pid ]]; then
      DAEMON_PID=$pid
      DAEMON_PIDS+=("$pid")
      return 0
    fi
    sleep 0.1
  done
  fail "could not identify the AUTOSTART daemon PID for $socket"
}
assert_daemon_pids_gone() {
  local context=$1 pid alive
  for _ in $(seq 50); do
    alive=
    for pid in "${DAEMON_PIDS[@]}"; do
      if [[ -n $pid ]] && kill -0 "$pid" >/dev/null 2>&1; then alive+="$pid "; fi
    done
    [[ -z $alive ]] && return 0
    sleep 0.1
  done
  fail "$context: daemon PIDs still alive: $alive"
}

SNAPSHOT='
local function n(e) return #(remuda.hooks[e] or {}) end
local matrix = remuda.butler and remuda.butler.matrix
local relay_running = matrix and matrix.relay and matrix.relay.instance ~= nil or false
local s = 0 for _, x in pairs(remuda.schedules) do
  if x.name == "butler-notices" or x.name == "butler-reconcile" or x.name == "butler-compaction" then s = s + 1 end
end
local live = {} for _, x in ipairs(remuda.ls()) do if x.alive then live[#live + 1] = x.name end end
table.sort(live)
local bus = remuda._butler_bus
local member = bus.agents.m1
local inbox = member and bus.inboxes[member.id] or {}
return string.format("boots=%d hooks=%d,%d,%d legacy_matrix_hooks=%d,%d schedules=%d sessions=%s member=%s mail=%d relay=%s bus=%s",
  remuda.event_counts()["butler-start"] or 0, n("butler/deliver"), n("session_exited"), n("butler-compaction-submit"), n("butler-matrix-line"), n("butler-matrix-submit"),
  s, table.concat(live, ","), tostring(member ~= nil), #inbox, tostring(relay_running), tostring(bus))'
pid_for() {
  ps -axo pid=,command= | awk -v needle="$1" 'index($0, needle) && $0 !~ /awk -v needle=/ && !found { print $1; found=1 }'
}
pids() {
  ps -axo pid=,command= | awk -v one="sleep ${ID}1" -v two="sleep ${ID}2" \
    '(index($0, one) || index($0, two)) && $0 !~ /awk -v one=/ { print $1 }' | sort | tr '\n' ','
}
pid_count() { pids | tr ',' '\n' | awk 'NF { n++ } END { print n+0 }'; }
record_session_pids() {
  local pid
  while IFS= read -r pid; do [[ -n "$pid" ]] && CHILD_PIDS+=("$pid"); done < <(pids | tr ',' '\n')
  SESSION_PID_COUNT=$(pid_count)
  [[ $SESSION_PID_COUNT -gt 0 ]] || fail "no process PID recorded for the two tracked sessions"
}
settle() { sleep 1; }
check() {
  local got
  got="$(lua "$SNAPSHOT") pids=$(pid_count)"
  echo "$1: $got"
  [[ "$got" == "$2" ]] || fail "$1: expected '$2'"
}

echo "== legacy install ($OLD_REF)"
old_files
start_daemon
if [[ -z ${AUTOSTART:-} ]] && [[ $(lua 'return tostring(type(remuda.http) == "table" and type(remuda.http.request) == "function")') == true ]]; then
  RELAY_EXPECT=true
fi
lua "remuda._butler_argv = {'sleep', '${ID}1'}; remuda._butler_reconcile_interval = 0.5"
record_autostart_daemon_pid
remuda -s "$S" butler --headless
# The old relay starts asynchronously; give it a bounded moment to appear.
for _ in $(seq 1 50); do
  OLD_RELAY_ID=$(lua 'return tostring(remuda._butler_relay or "")')
  OLD_RELAY_PID=$(pid_for "$TOKEN")
  [[ -n "$OLD_RELAY_ID" && -n "$OLD_RELAY_PID" ]] && break
  sleep 0.1
done
# The old Butler starts its legacy relay only when Matrix is configured and
# its interpreter exists; core's contract job has neither, so assert retirement only then.
if [[ -n "$OLD_RELAY_ID" && -n "$OLD_RELAY_PID" ]]; then
  CHILD_PIDS+=("$OLD_RELAY_PID")
else
  OLD_RELAY_ID= OLD_RELAY_PID=
  echo "SKIP: old Butler started no legacy Matrix relay; retirement not asserted"
fi
lua "remuda._butler_agent_builders.fake = function() return {'sleep', '${ID}2'} end
     remuda._butler_launch('fake', 'm1'); remuda._butler_send('butler', 'm1', 'kept across reload')"
record_session_pids
lua "remuda._butler_register_compaction_schedule()"  # active pre-step-4 handle is migrated on reload
settle
echo "legacy: $(lua "$SNAPSHOT")"
BASE=$(lua "$SNAPSHOT" | sed 's/.* bus=//')
BASE_BOOT=$(lua 'return remuda.event_counts()["butler-start"] or 0')
EXPECT_NEW="hooks=1,1,1 legacy_matrix_hooks=0,0 schedules=3 sessions=butler,m1 member=true mail=2 relay=$RELAY_EXPECT bus=$BASE pids=$SESSION_PID_COUNT"
EXPECT_OLD="hooks=1,1,1 legacy_matrix_hooks=1,1 schedules=2 sessions=butler,m1 member=true mail=0 relay=false bus=$BASE pids=$SESSION_PID_COUNT"
EXPECT_NEW_EMPTY="hooks=1,1,1 legacy_matrix_hooks=0,0 schedules=3 sessions=butler,m1 member=true mail=0 relay=$RELAY_EXPECT bus=$BASE pids=$SESSION_PID_COUNT"

echo "== swap in lifecycle files, reload x3"
new_files
mkdir -p "$MOD/packages/butler" "$T/foreign"
OWN_SCRIPT=$MOD/packages/butler/matrix_relay.py
FOREIGN_SCRIPT=$T/foreign/matrix_relay.py
# Only the argv script path matters to relay retirement; sh keeps the fixture
# free of an interpreter dependency.
printf 'trap "exit 0" TERM; while :; do sleep 1; done\n' >"$OWN_SCRIPT"
printf 'trap "exit 0" TERM; while :; do sleep 1; done\n' >"$FOREIGN_SCRIPT"
OWN_RELAY_ID=$(lua "remuda._butler_matrix_relay = remuda.process{argv={'sh', '$OWN_SCRIPT'}}; remuda._butler_matrix_relay_script_path = '$OWN_SCRIPT'; return remuda._butler_matrix_relay")
FOREIGN_RELAY_ID=$(lua "remuda._butler_foreign_matrix_relay = remuda.process{argv={'sh', '$FOREIGN_SCRIPT'}}; return remuda._butler_foreign_matrix_relay")
OWN_RELAY_PID=$(pid_for "$OWN_SCRIPT")
FOREIGN_RELAY_PID=$(pid_for "$FOREIGN_SCRIPT")
[[ -n "$OWN_RELAY_PID" && -n "$FOREIGN_RELAY_PID" ]] || fail "relay fixture process PID was not recorded"
CHILD_PIDS+=("$OWN_RELAY_PID" "$FOREIGN_RELAY_PID")
for i in 1 2 3; do
  if [[ $i == 2 ]]; then
    # A tracked process with the legacy name is still foreign when its exact
    # script path lives outside this Butler module directory.
    lua "remuda._butler_matrix_relay = $FOREIGN_RELAY_ID; remuda._butler_matrix_relay_script_path = '$FOREIGN_SCRIPT'"
  fi
  if [[ $i == 1 ]]; then
    # The legacy root was explicitly made with the test's fake argv and has
    # no readiness probe to migrate. Mark this injected session as the ready
    # root so the current lifecycle reload exercises the normal reuse path.
    lua "remuda._butler_selected_agent='claude'; remuda.reload('butler')"
  else
    lua "remuda.reload('butler')"
  fi
  settle
  check "reload $i" "boots=$((BASE_BOOT + i)) $EXPECT_NEW"
  if [[ $i == 1 ]]; then
    if [[ -n "$OLD_RELAY_PID" ]] && kill -0 "$OLD_RELAY_PID" 2>/dev/null; then
      fail "real old Python relay survived reload 1 as PID $OLD_RELAY_PID detail=$(ps -p "$OLD_RELAY_PID" -o pid=,ppid=,stat=,command=) slot=$(lua 'return tostring(remuda._butler_relay)') processes=$(lua 'return table.concat(remuda.processes(), ",")')"
    fi
    if [[ -n "$OLD_RELAY_ID" ]]; then
      lua "local ids = {}; for _, id in ipairs(remuda.processes()) do ids[id] = true end; assert(not ids['$OLD_RELAY_ID'], 'old relay handle survived reload 1')"
    fi
    lua "local ids = {}; for _, id in ipairs(remuda.processes()) do ids[id] = true end; assert(not ids[$OWN_RELAY_ID], 'legacy Python relay survived reload 1'); assert(ids[$FOREIGN_RELAY_ID], 'foreign same-named relay was killed')"
    lua "local m = remuda._butler_bus.agents.m1; remuda._butler_delivery_count_before = #remuda._butler_mail.mailbox(m.id); remuda._butler_send('butler', 'm1', 'single delivery after transition')"
    lua "local m = remuda._butler_bus.agents.m1; assert(#remuda._butler_mail.mailbox(m.id) - remuda._butler_delivery_count_before == 1, 'one send after transition must queue exactly one inbox message')"
    EXPECT_NEW=${EXPECT_NEW/mail=2/mail=3}
  fi
  if [[ $i == 2 ]]; then
    lua "local ids = {}; for _, id in ipairs(remuda.processes()) do ids[id] = true end; assert(ids[$FOREIGN_RELAY_ID], 'foreign path recorded in legacy slot was killed')"
  fi
done
lua "pcall(remuda.kill, $FOREIGN_RELAY_ID); remuda._butler_foreign_matrix_relay = nil"
# Read the whole answer first: `grep -q` leaves at its first match, the client
# then writes into a closed pipe, and under pipefail the line fails on a match.
sessions=$(remuda -s "$S" butler sessions) || fail "'remuda butler sessions' failed"
grep -q m1 <<<"$sessions" || fail "'remuda butler sessions' lost m1"
inbox=$(remuda -s "$S" butler inbox m1) || fail "'remuda butler inbox m1' failed"
grep -q 'kept across reload' <<<"$inbox" || fail "m1 mail lost"

echo "== rollback to $OLD_REF"
old_files
lua "remuda.reload('butler')"
settle
OLD_RELAY_PID=$(pid_for "$TOKEN")
[[ -n "$OLD_RELAY_PID" ]] && CHILD_PIDS+=("$OLD_RELAY_PID")
check "rollback" "boots=$((BASE_BOOT + 4)) $EXPECT_OLD"

echo "== roll forward again"
new_files
lua "remuda.reload('butler')"; settle
if [[ -n "$OLD_RELAY_PID" ]] && kill -0 "$OLD_RELAY_PID" 2>/dev/null; then fail "rollback Python relay survived roll-forward"; fi
check "roll forward" "boots=$((BASE_BOOT + 5)) $EXPECT_NEW_EMPTY"

echo "== tight reload loop: one boot per reload, nothing duplicated"
lua "for _ = 1, 5 do remuda.reload('butler') end"
for _ in 1 2 3 4 5; do lua "remuda.reload('butler')"; done
settle
check "tight x10" "boots=$((BASE_BOOT + 15)) $EXPECT_NEW_EMPTY"
[[ $(lua 'return #(remuda.hooks["butler-start"] or {})') == 1 ]] || fail "butler-start hook duplicated"

echo "== cold boot through remuda butler"
[[ ${REMUDA_RUNTIME_DIR:-} == "$T/run" ]] || fail "refusing to stop daemon outside scratch runtime"
remuda -s "$S" stop -f >/dev/null 2>&1 || fail "daemon stop command failed"
wait "$DAEMON_PID" 2>/dev/null || true
assert_daemon_pids_gone "mid-run stop"
DAEMON_PID=
DAEMON_PIDS=()
start_daemon
lua "remuda._butler_argv = {'sleep', '${ID}1'}"
record_autostart_daemon_pid
remuda -s "$S" butler --headless; settle
COLD=$(lua "$SNAPSHOT")
[[ "$COLD" == *"boots=1 hooks=1,1,1 legacy_matrix_hooks=0,0 schedules=3 sessions=butler member=false mail=0 relay=$RELAY_EXPECT bus="* ]] || \
  fail "cold boot: $COLD"
remuda -s "$S" stop -f >/dev/null 2>&1 || fail "final daemon stop command failed"
wait "$DAEMON_PID" 2>/dev/null || true
assert_daemon_pids_gone "final stop"
echo PASS
