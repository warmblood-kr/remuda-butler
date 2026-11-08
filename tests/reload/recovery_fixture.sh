#!/usr/bin/env bash
# Private reload recovery fixture: A, B, C.
#
# Accident prevention: every daemon and client here runs with `env -i` in a
# private owned scratch runtime. It never uses the default runtime and never
# runs --check/reload/stop/close against a live daemon.
#
# A: a host-backed session survives a same-binary reload; the new image has a
#    different daemon PID, a fresh init serial, and the same host identity.
# B: an in-process session blocks --check and leaves the old daemon, socket,
#    sessions and daemon id unchanged, with no candidate left behind.
# C: an injected relay-style fake schedule is gone after reload; the real
#    one-shot and scheduled timers run; the host survives.
#
# D (request receipt timing) and E (handoff-1 mismatch) are not implemented in
# this first diff and are printed as UNVERIFIED/PENDING, never PASS.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd -P)
BIN=${REMUDA_BIN:-$(command -v remuda || true)}
[[ -n "$BIN" && -x "$BIN" ]] || { echo "reload fixture: REMUDA_BIN is not executable: ${BIN:-<unset>}" >&2; exit 2; }
BIN=$(cd "$(dirname "$BIN")" && pwd -P)/$(basename "$BIN")
command -v pgrep >/dev/null || { echo "reload fixture: pgrep is required" >&2; exit 2; }
if ! "$BIN" reload --help 2>&1 | grep -q -- '--check'; then
  echo "UNVERIFIED: $BIN has no reload --check support; use a reload-capable binary" >&2
  exit 2
fi

OUTER=$(mktemp -d /tmp/reload-recovery.XXXXXX) || exit 2
OUTER=$(cd "$OUTER" && pwd -P)
declare -a PASSED=() FAILED=() UNVERIFIED=()
fail=0

note() { echo "fixture: $*" >&2; }

new_case() {
  local tag=$1
  S="rrf${tag}-$$"
  T=$(mktemp -d "/tmp/rrf-${tag}.XXXXXX") || return 1
  trap 'case_rc=$?; case_cleanup || exit 1; exit "$case_rc"' EXIT
  T=$(cd "$T" && pwd -P) || return 1
  chmod 700 "$T"
  local default_runtime="/tmp/remuda-$(id -un)"
  [[ "$T" != "$default_runtime" && "$T" != "$default_runtime/"* ]] || return 1
  local d
  for d in home config data state cache runtime tmp; do
    mkdir -m 700 "$T/$d" || return 1
    [[ -d "$T/$d" && ! -L "$T/$d" && -O "$T/$d" ]] || return 1
  done
  mkdir -p "$T/config/remuda" || return 1
  cat >"$T/config/remuda/init.lua" <<'LUA'
-- Fresh-image marker: every daemon image runs this once and increments a
-- serial file outside the image. A reload that reuses the image would not
-- increment it; a fresh image would.
local path = os.getenv("RRF_INIT_SERIAL")
local serial = 0
if path then
  local reader = io.open(path, "r")
  if reader then serial = tonumber(reader:read("*a")) or 0; reader:close() end
  serial = serial + 1
  local writer = io.open(path, "w")
  if writer then writer:write(tostring(serial)); writer:close() end
end
remuda._fixture_init_serial = serial
LUA
  SERIAL="$T/init-serial"
  HOST_MARKER="$T/host-$tag"
  : >"$HOST_MARKER" || return 1
  SOCK="$T/runtime/remuda/$S.sock"
  LOG="$T/daemon.log"
  DAEMON_PID=
  PENV=(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME="$T/home" XDG_CONFIG_HOME="$T/config" XDG_DATA_HOME="$T/data" \
    XDG_STATE_HOME="$T/state" XDG_CACHE_HOME="$T/cache" \
    REMUDA_RUNTIME_DIR="$T/runtime" RRF_INIT_SERIAL="$SERIAL" RRF_FAKE_COUNTER="$T/fake-callback" \
    REMUDA_NO_UPDATE_CHECK=1 TMPDIR="$T/tmp")
  return 0
}

runp() { "${PENV[@]}" "$BIN" -s "$S" "$@"; }
runph() { "${PENV[@]}" REMUDA_EXPERIMENTAL_SESSION_HOST=1 "$BIN" -s "$S" "$@"; }

start_o() {
  local hosted=$1
  if [[ "$hosted" == 1 ]]; then
    "${PENV[@]}" REMUDA_EXPERIMENTAL_SESSION_HOST=1 "$BIN" -s "$S" daemon >"$LOG" 2>&1 &
  else
    "${PENV[@]}" "$BIN" -s "$S" daemon >"$LOG" 2>&1 &
  fi
  DAEMON_PID=$!
  local i
  for i in $(seq 50); do [[ -S "$SOCK" ]] && return 0; sleep 0.1; done
  cat "$LOG" >&2
  return 1
}

# --- fail-closed process inspection -----------------------------------------
# kill -0 is authoritative for a process we own. Only an explicit
# "No such process" proves exit; every other failure is unknown and retained.
pid_may_be_alive() {
  local pid=$1 err
  [[ -n "$pid" ]] || return 1
  if kill -0 "$pid" 2>/dev/null; then return 0; fi
  err=$(LC_ALL=C kill -0 "$pid" 2>&1) || true
  case "$err" in
    *"No such process"*) return 1 ;;
    *) return 0 ;;
  esac
}

pid_is_zombie() {
  local state
  state=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  [[ "$state" == Z* ]]
}

# Reap one of our own children with a bounded wait. Never `wait` a live PID:
# only call wait after it is gone or positively a zombie.
reap_old() {
  local pid=$1 limit=${2:-120} i
  for i in $(seq "$limit"); do
    if ! pid_may_be_alive "$pid"; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    if pid_is_zombie "$pid"; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# 0 = completed (the list may be empty), 2 = inspection failed. Callers must
# not read an empty list on 2 as proven absence.
daemon_pids() {
  # The server name is unique to this fixture run. The daemon's argv carries
  # it, so this works even where ps cannot show another process's environment.
  local out rc
  out=$(pgrep -f "$BIN -s $S daemon" 2>/dev/null); rc=$?
  (( rc > 1 )) && return 2
  [[ -z "$out" ]] || printf '%s\n' "$out"
  return 0
}

candidate_pids() {
  # The candidate argv names this case's socket. A re-exec'd candidate that
  # hangs before serving would also appear as a second daemon in daemon_pids,
  # which the exact-one-daemon assertions catch. The environment check is not
  # relied on because macOS ps does not expose another process's environment.
  local out rc
  out=$(pgrep -f "$BIN _reload-candidate $SOCK" 2>/dev/null); rc=$?
  (( rc > 1 )) && return 2
  [[ -z "$out" ]] || printf '%s\n' "$out"
  return 0
}

# Every process whose environment names this case's runtime, including a host
# whose argv does not. Capture ps before awk so the scan cannot match itself.
runtime_env_pids() {
  local raw
  raw=$(ps eww -ax 2>/dev/null) || return 2
  printf '%s\n' "$raw" |
    EXPECT_RUNTIME="$T/runtime" awk 'BEGIN { rt = "REMUDA_RUNTIME_DIR=" ENVIRON["EXPECT_RUNTIME"] } index($0, rt) { print $1 }' |
    sort -u
  return 0
}

# macOS ps does not expose another process's environment, so the host command
# carries a unique argv path under the case scratch. This is the authoritative
# host-orphan check here; the environment scan above is a Linux extra.
host_marker_pids() {
  local out rc
  out=$(pgrep -f "$HOST_MARKER" 2>/dev/null); rc=$?
  (( rc > 1 )) && return 2
  [[ -z "$out" ]] || printf '%s\n' "$out"
  return 0
}

# 0 = proven gone, 1 = still present, 2 = inspection unknown.
private_procs_gone() {
  local out
  if ! out=$(daemon_pids); then return 2; fi
  [[ -z "$out" ]] || return 1
  if ! out=$(candidate_pids); then return 2; fi
  [[ -z "$out" ]] || return 1
  if ! out=$(runtime_env_pids); then return 2; fi
  [[ -z "$out" ]] || return 1
  if ! out=$(host_marker_pids); then return 2; fi
  [[ -z "$out" ]] || return 1
  return 0
}

check_absent() {
  local label=$1 fn=$2 out
  if ! out=$($fn); then
    note "cannot inspect $label (ps/pgrep failed); treating as present"
    return 1
  fi
  [[ -z "$out" ]] || { note "$label still present: $out"; return 1; }
  return 0
}

daemon_id() {
  [[ -f "$SOCK.daemon-id" ]] || return 1
  cat "$SOCK.daemon-id"
}

init_serial() {
  runp -e 'return tostring(remuda._fixture_init_serial)' 2>/dev/null | tail -1
}

create_session() {
  local name=$1
  runph -e "local n,i=remuda.session.new('$name',{'tail','-f','$HOST_MARKER'}); return tostring(n)..'|'..tostring(i)" 2>/dev/null | tail -1
}

close_session() {
  local name=$1
  runp -e "remuda.session.close('$name'); return 'closed'" >/dev/null 2>&1 || true
}

session_info() {
  local name=$1 value
  value=$(runph -e "for _,r in ipairs(remuda.session.list()) do if r.name=='$name' then return tostring(r.instance_id)..'|'..tostring(r.alive) end end; return 'absent'" 2>/dev/null | tail -1)
  printf '%s' "$value"
}

host_line() {
  local name=$1
  runp version --hosts 2>/dev/null | grep -E "^host $name " | tail -1
}

wait_old_gone() {
  reap_old "$1" 120
}

same_socket_path() {
  [[ -S "$SOCK" ]] || return 1
  runp version --hosts >/dev/null 2>&1
}

no_candidates() {
  check_absent candidates candidate_pids
}

case_cleanup() {
  [[ -n ${T:-} && -d "$T" ]] || return 0
  if [[ -n ${DAEMON_PID:-} && ${PENV+x} ]]; then
    runp stop -f >/dev/null 2>&1 || true
    reap_old "$DAEMON_PID" 80 || { note "old daemon not proven exited; keeping $T"; return 1; }
  fi
  local i state
  for i in $(seq 80); do
    if private_procs_gone; then state=0; else state=$?; fi
    if (( state == 0 )); then break; fi
    if (( state == 2 )); then note "cannot inspect private processes; keeping $T"; return 1; fi
    sleep 0.1
  done
  private_procs_gone || { note "private daemon/candidate/host still up or unproven; keeping $T"; return 1; }
  local leftovers
  leftovers=$(ps -axo pid,command 2>/dev/null | grep -F "$T/" | grep -v grep || true)
  if [[ -n "$leftovers" ]]; then
    note "runtime path still referenced by a process; keeping $T: $leftovers"
    return 1
  fi
  rm -rf -- "$T"
  return 0
}

stop_case() {
  close_session hosted >/dev/null 2>&1 || true
  close_session inproc >/dev/null 2>&1 || true
  if [[ -n ${DAEMON_PID:-} ]]; then
    runp stop -f >/dev/null 2>&1 || true
    reap_old "$DAEMON_PID" 80 || { note "old daemon not proven exited"; return 1; }
  fi
  local i state
  for i in $(seq 80); do
    if private_procs_gone; then state=0; else state=$?; fi
    if (( state == 0 )); then break; fi
    if (( state == 2 )); then note "cannot inspect private processes"; return 1; fi
    sleep 0.1
  done
  private_procs_gone || { note "private daemon/candidate/host still up or unproven"; return 1; }
  check_absent daemons daemon_pids || return 1
  check_absent candidates candidate_pids || return 1
  check_absent hosts host_marker_pids || return 1
  check_absent runtime-env runtime_env_pids || return 1
  return 0
}

case_a() {
  set -e
  new_case A
  start_o 1
  local old=$DAEMON_PID old_id first_serial host_before info_before check reload new_pids new_pid after_id after_serial host_after info_after

  old_id=$(daemon_id)
  first_serial=$(init_serial)
  [[ "$first_serial" == 1 ]] || { echo "initial init serial is $first_serial, expected 1"; return 1; }

  local created
  created=$(create_session hosted) || true
  if [[ "$created" != hosted\|* ]]; then
    echo "UNVERIFIED: host-backed session creation unavailable: $created"
    return 2
  fi
  host_before=$(host_line hosted)
  if [[ -z "$host_before" ]]; then
    echo "UNVERIFIED: version --hosts did not report the hosted session"
    return 2
  fi
  info_before=$(session_info hosted)
  [[ "$info_before" == *"|true" ]] || { echo "hosted session is not alive: $info_before"; return 1; }

  if check=$(runp reload --check --binary "$BIN" 2>"$T/check.err"); then
    :
  else
    echo "reload --check failed: $check"; cat "$T/check.err"; return 1
  fi
  grep -q '^ready:' <<<"$check" || { echo "check was not ready: $check"; return 1; }
  grep -q "^host hosted: now .*; candidate sees " <<<"$check" || { echo "check did not report hosted: $check"; return 1; }

  if reload=$(runp reload --binary "$BIN" 2>"$T/reload.err"); then
    :
  else
    echo "reload failed: $reload"; cat "$T/reload.err"; return 1
  fi
  grep -q '^reloaded:' <<<"$reload" || { echo "reload did not report reloaded: $reload"; return 1; }
  grep -q '^daemon now ' <<<"$reload" || { echo "reload did not report daemon: $reload"; return 1; }
  grep -q '^sessions: all 1 host-backed listed' <<<"$reload" || { echo "reload did not list the host: $reload"; return 1; }
  grep -q '^init.lua: loaded' <<<"$reload" || { echo "reload did not load init.lua: $reload"; return 1; }

  wait_old_gone "$old" || { echo "old daemon PID $old is still alive"; return 1; }
  if ! new_pids=$(daemon_pids); then echo "cannot inspect daemon PIDs after reload"; return 1; fi
  [[ "$(wc -l <<<"$new_pids" | tr -d ' ')" == 1 ]] || { echo "expected exactly one daemon after reload, got: $new_pids"; return 1; }
  new_pid=$(head -1 <<<"$new_pids")
  [[ -n "$new_pid" && "$new_pid" != "$old" ]] || { echo "no fresh daemon PID (old=$old, new=$new_pids)"; return 1; }
  same_socket_path || { echo "socket is not connectable after reload"; return 1; }
  after_id=$(daemon_id)
  [[ "$after_id" == "$old_id" ]] || { echo "daemon id changed (expected stable across reload): $old_id -> $after_id"; return 1; }
  after_serial=$(init_serial)
  [[ "$after_serial" == 2 ]] || { echo "init serial after reload is $after_serial, expected 2"; return 1; }
  host_after=$(host_line hosted)
  [[ -n "$host_after" ]] || { echo "host missing after reload"; return 1; }
  info_after=$(session_info hosted)
  [[ "$info_after" == "$info_before" ]] || { echo "host identity changed: $info_before -> $info_after"; return 1; }

  stop_case
  echo "PASS A: hosted session survived same-binary reload; pid $old -> $new_pid; init serial $first_serial -> $after_serial; daemon-id stable"
  echo "  host before: $host_before"
  echo "  host after:  $host_after"
}

case_b() {
  set -e
  new_case B
  start_o 0
  local old=$DAEMON_PID old_id info_before check hosts_before pids_after info_after
  old_id=$(daemon_id)
  local created
  created=$(create_session inproc) || true
  [[ "$created" == inproc\|* ]] || { echo "in-process session creation failed: $created"; return 1; }
  info_before=$(session_info inproc)
  [[ "$info_before" == *"|true" ]] || { echo "in-process session is not alive: $info_before"; return 1; }
  hosts_before=$(runp version --hosts 2>/dev/null || true)
  if grep -q '^host ' <<<"$hosts_before"; then
    echo "expected no host-backed sessions: $hosts_before"; return 1
  fi

  if check=$(runp reload --check --binary "$BIN" 2>"$T/check.err"); then
    echo "blocked check returned success: $check"; return 1
  fi
  grep -q '^blocked:' <<<"$check" || { echo "check was not blocked: $check"; return 1; }
  grep -q '^blocker: in-process sessions would end: inproc ' <<<"$check" || { echo "check did not name the in-process session: $check"; return 1; }

  [[ "$(daemon_id)" == "$old_id" ]] || { echo "daemon id changed after a blocked check"; return 1; }
  if ! pids_after=$(daemon_pids); then echo "cannot inspect daemon PIDs after a blocked check"; return 1; fi
  [[ "$(wc -l <<<"$pids_after" | tr -d ' ')" == 1 && "$pids_after" == "$old" ]] || { echo "daemon PID changed after a blocked check: old=$old now=$pids_after"; return 1; }
  same_socket_path || { echo "socket is not connectable after a blocked check"; return 1; }
  info_after=$(session_info inproc)
  [[ "$info_after" == "$info_before" ]] || { echo "session changed after a blocked check: $info_before -> $info_after"; return 1; }
  no_candidates || { echo "candidate left behind after a blocked check"; return 1; }

  local reload
  if reload=$(runp reload --binary "$BIN" 2>"$T/reload.err"); then
    echo "actual reload returned success despite the in-process session: $reload"; return 1
  fi
  grep -q '^blocked:' <<<"$reload" || { echo "actual reload was not blocked: $reload"; return 1; }
  grep -q '^blocker: in-process sessions would end: inproc ' <<<"$reload" || { echo "actual reload did not name the in-process session: $reload"; return 1; }
  [[ "$(daemon_id)" == "$old_id" ]] || { echo "daemon id changed after an actual refusal"; return 1; }
  if ! pids_after=$(daemon_pids); then echo "cannot inspect daemon PIDs after an actual refusal"; return 1; fi
  [[ "$(wc -l <<<"$pids_after" | tr -d ' ')" == 1 && "$pids_after" == "$old" ]] || { echo "daemon PID changed after an actual refusal: old=$old now=$pids_after"; return 1; }
  same_socket_path || { echo "socket is not connectable after an actual refusal"; return 1; }
  [[ "$(session_info inproc)" == "$info_before" ]] || { echo "session changed after an actual refusal"; return 1; }
  no_candidates || { echo "candidate left behind after an actual refusal"; return 1; }

  stop_case
  echo "PASS B: in-process session blocked both --check and actual reload; pid $old, daemon-id, socket and session unchanged; no candidate"
  echo "  blocker: $(grep '^blocker:' <<<"$check")"
}

case_c() {
  set -e
  new_case C
  start_o 1
  local old=$DAEMON_PID old_id first_serial info_before reload after_fake after_serial info_after
  local after_calls ticks ticks2

  old_id=$(daemon_id)
  first_serial=$(init_serial)
  [[ "$first_serial" == 1 ]] || { echo "initial init serial is $first_serial, expected 1"; return 1; }
  local created
  created=$(create_session hosted) || true
  if [[ "$created" != hosted\|* ]]; then
    echo "UNVERIFIED: host-backed session creation unavailable: $created"
    return 2
  fi
  info_before=$(session_info hosted)
  [[ "$info_before" == *"|true" ]] || { echo "hosted session is not alive: $info_before"; return 1; }

  local injected
  injected=$(runp -e "
    remuda._relay_timers = {}
    remuda._fake_http_timers = {}
    remuda._fixture_fake_calls = 0
    local counter = os.getenv('RRF_FAKE_COUNTER')
    local function fake_run()
      remuda._fixture_fake_calls = (remuda._fixture_fake_calls or 0) + 1
      if counter then
        local f = io.open(counter, 'a')
        if f then f:write('old-fake-callback-invoked\n'); f:close() end
      end
    end
    function remuda.schedule(spec)
      local timer = { spec = spec, cancelled = false }
      remuda._relay_timers[#remuda._relay_timers + 1] = timer
      return timer
    end
    function remuda.cancel(timer) if timer then timer.cancelled = true end end
    -- Register the old fake callback on a fake handle but never invoke it.
    remuda._fixture_fake_handle = { spec = { run = fake_run }, cancelled = false }
    remuda._relay_timers[#remuda._relay_timers + 1] = remuda._fixture_fake_handle
    return 'injected'
  " 2>/dev/null | tail -1)
  [[ "$injected" == injected ]] || { echo "fake injection failed: $injected"; return 1; }
  local before_fake
  before_fake=$(runp -e "return tostring(remuda._relay_timers ~= nil)..','..tostring(remuda._fake_http_timers ~= nil)..','..tostring(remuda._fixture_fake_calls)" 2>/dev/null | tail -1)
  [[ "$before_fake" == "true,true,0" ]] || { echo "fake bindings not installed: $before_fake"; return 1; }
  [[ ! -s "$T/fake-callback" ]] || { echo "old fake callback ran before reload"; return 1; }

  if reload=$(runp reload --binary "$BIN" 2>"$T/reload.err"); then
    :
  else
    echo "reload failed: $reload"; cat "$T/reload.err"; return 1
  fi
  grep -q '^reloaded:' <<<"$reload" || { echo "reload did not report reloaded: $reload"; return 1; }
  grep -q '^sessions: all 1 host-backed listed' <<<"$reload" || { echo "reload did not list the host: $reload"; return 1; }

  wait_old_gone "$old" || { echo "old daemon PID $old is still alive"; return 1; }
  local daemons
  if ! daemons=$(daemon_pids); then echo "cannot inspect daemon PIDs after reload"; return 1; fi
  [[ "$(wc -l <<<"$daemons" | tr -d ' ')" == 1 ]] || { echo "expected exactly one daemon after reload, got: $daemons"; return 1; }
  [[ "$(daemon_id)" == "$old_id" ]] || { echo "daemon id changed across reload"; return 1; }
  after_serial=$(init_serial)
  [[ "$after_serial" == 2 ]] || { echo "init serial after reload is $after_serial, expected 2"; return 1; }

  after_fake=$(runp -e "return tostring(remuda._relay_timers ~= nil)..','..tostring(remuda._fake_http_timers ~= nil)..','..tostring(type(remuda.schedule))..','..tostring(type(remuda.schedules))..','..tostring(type(remuda.clock))" 2>/dev/null | tail -1)
  [[ "$after_fake" == "false,false,function,table,function" ]] || { echo "fresh image did not restore real timer bindings: $after_fake"; return 1; }
  [[ ! -s "$T/fake-callback" ]] || { echo "old fake callback was replayed across reload: $(cat "$T/fake-callback")"; return 1; }

  runp -e "remuda._fixture_after_calls=0; remuda.after(0.2, function() remuda._fixture_after_calls=(remuda._fixture_after_calls or 0)+1 end); return 'after'" >/dev/null 2>&1
  runp -e "remuda._fixture_ticks=0; remuda._fixture_handle=remuda.schedule{every=0.1, after=0.05, name='rrf-probe', run=function() remuda._fixture_ticks=(remuda._fixture_ticks or 0)+1 end}; return 'scheduled'" >/dev/null 2>&1
  sleep 1.5
  after_calls=$(runp -e "return tostring(remuda._fixture_after_calls)" 2>/dev/null | tail -1)
  ticks=$(runp -e "return tostring(remuda._fixture_ticks)" 2>/dev/null | tail -1)
  [[ "$after_calls" == 1 ]] || { echo "one-shot timer fired $after_calls times, expected 1"; return 1; }
  [[ "$ticks" =~ ^[0-9]+$ && "$ticks" -ge 1 ]] || { echo "scheduled timer did not tick: $ticks"; return 1; }
  runp -e "remuda.cancel(remuda._fixture_handle); return 'cancelled'" >/dev/null 2>&1
  local baseline
  baseline=$(runp -e "return tostring(remuda._fixture_ticks)" 2>/dev/null | tail -1)
  sleep 1.2
  ticks2=$(runp -e "return tostring(remuda._fixture_ticks)" 2>/dev/null | tail -1)
  [[ "$ticks2" == "$baseline" ]] || { echo "scheduled timer kept ticking after cancel: $baseline -> $ticks2"; return 1; }

  info_after=$(session_info hosted)
  [[ "$info_after" == "$info_before" ]] || { echo "host identity changed across reload: $info_before -> $info_after"; return 1; }
  [[ -n "$(host_line hosted)" ]] || { echo "host missing after reload"; return 1; }

  stop_case
  echo "PASS C: core fake schedule gone, old fake callback never replayed; real after fired once; real schedule ticked $ticks then stopped after cancel; host survived"
  echo "  fake before: $before_fake; after: $after_fake; old fake callback file: empty"
echo "  C scope: core primitives only; no private Butler install, so real Butler graph recovery is a separate fixture"
}

run_case() {
  local name=$1
  shift
  local log="$OUTER/$name.log"
  ( "$@" ) >"$log" 2>&1
  local rc=$?
  case $rc in
    0) PASSED+=("$name"); echo "PASS $name"; cat "$log";;
    2) UNVERIFIED+=("$name"); echo "UNVERIFIED $name"; cat "$log";;
    *) FAILED+=("$name"); fail=1; echo "FAIL $name"; tail -40 "$log";;
  esac
}

run_case A case_a
run_case B case_b
run_case C case_c

echo
echo "summary: pass ${PASSED[*]:-none}; fail ${FAILED[*]:-none}; unverified ${UNVERIFIED[*]:-none}"
echo "UNVERIFIED: D request-receipt timing not implemented in this diff"
echo "UNVERIFIED: E handoff-1 artifact unavailable"
echo "live default runtime was never addressed; all daemons used $OUTER scratch cases"
if (( fail )); then
  echo "fixture logs: $OUTER" >&2
  exit 1
fi
rm -rf -- "$OUTER"
