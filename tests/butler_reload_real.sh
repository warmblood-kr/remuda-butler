#!/usr/bin/env bash
# A real `remuda reload` (warmblood-kr/remuda#713) with Butler, a root and two
# live members, on a private daemon. Opt-in: set REMUDA_RELOAD_BIN to a core
# that has `remuda reload` and session hosts (warmblood-kr/remuda#810);
# otherwise this skips. Needs the predecessor-lock fix too (guard.lua).
#   REMUDA_RELOAD_BIN=/path/to/remuda tests/butler_reload_real.sh
set -uo pipefail
B=${REMUDA_RELOAD_BIN:-}
if [[ -z $B ]] || ! "$B" reload --help >/dev/null 2>&1; then
  echo "skip - REMUDA_RELOAD_BIN is not a core with remuda reload"; exit 0
fi
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d /tmp/brr.XXXXXX); T=$(cd "$T" && pwd -P)
# This run's own fake-agent duration, so leftovers are found without
# matching any other run's processes.
DUR=$((300000 + $$ % 100000))
export REMUDA_RUNTIME_DIR=$T/run XDG_DATA_HOME=$T/data XDG_CONFIG_HOME=$T/config HOME=$T/home
export XDG_RUNTIME_DIR=$T/runtime REMUDA_NO_UPDATE_CHECK=1 REMUDA_EXPERIMENTAL_SESSION_HOST=1
for n in ${!REMUDA_BUTLER_@}; do unset "$n"; done; unset REMUDA_SERVER
mkdir -p "$HOME" "$XDG_DATA_HOME/remuda/mods/butler" "$XDG_CONFIG_HOME/remuda" "$XDG_RUNTIME_DIR"
mkdir -m700 "$REMUDA_RUNTIME_DIR"
cp -R "$REPO/extension.toml" "$REPO/packages" "$XDG_DATA_HOME/remuda/mods/butler/"
# install-butler.sh's loader, plus the test seams (fake root, unreachable relay).
# The relay is configured but the homeserver is closed, so it never reaches the
# network while still exercising the real start/stop/owner path.
mkdir -p "$XDG_CONFIG_HOME/remuda/butler"
echo fake-token >"$XDG_CONFIG_HOME/remuda/butler/token"
printf 'http://127.0.0.1:9\n!room:x\n@butler:x\n' >"$XDG_CONFIG_HOME/remuda/butler/config"
echo '{"since":"s0"}' >"$XDG_CONFIG_HOME/remuda/butler/config.since"
cat >"$XDG_CONFIG_HOME/remuda/init.lua" <<'LUA'
remuda._butler_argv = {"sh","-c","sleep DUR"}; remuda._butler_readiness_timeout = 1
remuda.exec("butler")
LUA
sed -i.bak "s/sleep DUR/sleep $DUR/" "$XDG_CONFIG_HOME/remuda/init.lua" && rm -f "$XDG_CONFIG_HOME/remuda/init.lua.bak"
SV=brr$$
[[ $SV != default ]] || exit 1
r() { "$B" -s "$SV" "$@"; }
# Host-backed sessions outlive `stop`: close every session first, or their
# hosts (and PTYs) leak past this test.
cleanup() {
  # Butler relaunches a closed root: stop its reconcile first.
  r -e 'remuda._butler_reconcile = function() end' >/dev/null 2>&1
  # A hosted close stops its host in the background; close until the
  # inventory is empty.
  local i
  for i in $(seq 100); do
    r -e 'for _, s in ipairs(remuda.ls()) do pcall(remuda.close, s.name) end' >/dev/null 2>&1
    [[ -z $(ls -A "$REMUDA_RUNTIME_DIR"/remuda/*.sock.hosts 2>/dev/null) ]] && break
    sleep 0.1
  done
  r stop -f >/dev/null 2>&1
  # Zero leftovers: no host, daemon or fake agent of this run (each holds a PTY).
  local left=""
  for i in $(seq 50); do
    left=$(ps -axo pid=,command= | grep -F -e "$T/" -e "sleep $DUR" | grep -v -e grep -e "ps -axo" || true)
    [[ -z $left ]] && break
    sleep 0.1
  done
  rm -rf "$T"
  if [[ -n $left ]]; then
    echo "FAIL: leftovers after cleanup (pids for a manual kill):"
    echo "$left"
    exit 1
  fi
  echo "ok - no leftover hosts, daemons or agents"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
wait_up() {
  local i
  for i in $(seq 100); do
    [[ $(r -e 'local b = remuda._butler_bus return b ~= nil and b.agents.butler ~= nil and b.agents.butler.instance_id ~= nil and not remuda._butler_launching' 2>/dev/null) == true ]] && return 0
    sleep 0.2
  done
  return 1
}
wait_relay() {
  local i
  for i in $(seq 100); do
    [[ $(r -e 'local m = remuda.butler and remuda.butler.matrix local x = m and m.relay and m.relay.instance return tostring(x ~= nil)' 2>/dev/null) == true ]] && return 0
    sleep 0.1
  done
  return 1
}
r -e 1 >/dev/null 2>&1
wait_up || fail "Butler did not start"
wait_relay || fail "relay did not start before the reload"
r -e "remuda.butler.project_home('$T/projects'); remuda._butler_agent_builders.codex = function() return {'sleep','$DUR'} end; remuda._butler_launch('codex','alice'); remuda._butler_launch('codex','bob',nil,'alice'); remuda._butler_send('butler','alice','queued before reload')" >/dev/null
SNAP='local b=remuda._butler_bus local i={} for _,s in ipairs(remuda.ls()) do if s.alive then i[s.name]=s.instance_id end end local a, c = b.agents.alice or {}, b.agents.bob or {} return table.concat({tostring(i.butler), tostring(i.alice), tostring(i.bob), tostring(a.id), tostring(c.id), tostring(c.parent)}, "|")'
BEFORE=$(r -e "$SNAP")
[[ $BEFORE != *nil* ]] || fail "setup incomplete: $BEFORE"
r reload >/dev/null 2>&1 || fail "remuda reload failed"
wait_up || fail "Butler not up after the reload: $(r butler status 2>&1 | head -2)"
AFTER=$(r -e "$SNAP")
[[ $AFTER == "$BEFORE" ]] || fail "sessions, identities or leaders changed: $BEFORE -> $AFTER"
QUEUED=$(grep -rl "queued before reload" "$XDG_DATA_HOME/remuda/butler/mail" 2>/dev/null | wc -l | tr -d ' ')
[[ $QUEUED == 1 ]] || fail "the queued message must survive exactly once, found $QUEUED copies"
echo "ok - the queued message survives exactly once"
# A warm reload stops the old relay and must restart exactly one owner. Without
# a positive owner proof this stays down and the reply path reports unavailable.
wait_relay || fail "relay did not restart after the reload"
r -e 'local m = remuda.butler.matrix local x = m.relay local o = remuda._butler_relay_owners
  local n = 0
  if type(o) == "table" and type(o.live) == "table" then
    for inst in pairs(o.live) do n = n + 1; assert(inst == x.instance, "stale relay owner registered") end
  end
  assert(x.instance ~= nil, "relay instance missing after reload")
  assert(n == 1, "expected exactly one relay owner, got " .. tostring(n))
  assert(remuda._butler_relay_restart_blocked ~= true, "relay restart was reported blocked")' >/dev/null \
  || fail "relay owner proof after the reload"
echo "ok - exactly one relay owner after a warm reload"
echo "ok - root, members, leaders and queued mail survive a reload"
ENDED=$(grep -c '"state":"ended"' "$XDG_DATA_HOME/remuda/butler/agents.jsonl")
[[ $ENDED == 0 ]] || fail "$ENDED identities marked ended"
echo "ok - no member is swept as ended"
r butler send alice "after reload" >/dev/null 2>&1 || fail "send to a member after the reload: $(r butler send alice x 2>&1)"
echo "ok - mail reaches a member after the reload"
echo PASS
