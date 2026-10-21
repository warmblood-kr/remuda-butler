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
export REMUDA_RUNTIME_DIR=$T/run XDG_DATA_HOME=$T/data XDG_CONFIG_HOME=$T/config HOME=$T/home
export XDG_RUNTIME_DIR=$T/runtime REMUDA_NO_UPDATE_CHECK=1 REMUDA_EXPERIMENTAL_SESSION_HOST=1
for n in ${!REMUDA_BUTLER_@}; do unset "$n"; done; unset REMUDA_SERVER
mkdir -p "$HOME" "$XDG_DATA_HOME/remuda/mods/butler" "$XDG_CONFIG_HOME/remuda" "$XDG_RUNTIME_DIR"
mkdir -m700 "$REMUDA_RUNTIME_DIR"
cp -R "$REPO/extension.toml" "$REPO/packages" "$XDG_DATA_HOME/remuda/mods/butler/"
# install-butler.sh's loader, plus the test seams (fake root, no relay).
cat >"$XDG_CONFIG_HOME/remuda/init.lua" <<'LUA'
remuda._butler_argv = {"sh","-c","sleep 300"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1
remuda.exec("butler")
LUA
SV=brr$$
[[ $SV != default ]] || exit 1
r() { "$B" -s "$SV" "$@"; }
# Host-backed sessions outlive `stop`: close every session first, or their
# hosts (and PTYs) leak past this test.
cleanup() {
  r -e 'for _, s in ipairs(remuda.ls()) do pcall(remuda.close, s.name) end' >/dev/null 2>&1
  r stop -f >/dev/null 2>&1
  rm -rf "$T"
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
r -e 1 >/dev/null 2>&1
wait_up || fail "Butler did not start"
r -e "remuda.butler.project_home('$T/projects'); remuda._butler_agent_builders.codex = function() return {'sleep','300'} end; remuda._butler_launch('codex','alice'); remuda._butler_launch('codex','bob',nil,'alice'); remuda._butler_send('butler','alice','queued before reload')" >/dev/null
SNAP='local b=remuda._butler_bus local i={} for _,s in ipairs(remuda.ls()) do if s.alive then i[s.name]=s.instance_id end end local a, c = b.agents.alice or {}, b.agents.bob or {} return table.concat({tostring(i.butler), tostring(i.alice), tostring(i.bob), tostring(a.id), tostring(c.id), tostring(c.parent), tostring(a.id and remuda._butler_mail.unread(a.id))}, "|")'
BEFORE=$(r -e "$SNAP")
[[ $BEFORE != *nil* ]] || fail "setup incomplete: $BEFORE"
r reload >/dev/null 2>&1 || fail "remuda reload failed"
wait_up || fail "Butler not up after the reload: $(r butler status 2>&1 | head -2)"
AFTER=$(r -e "$SNAP")
[[ $AFTER == "$BEFORE" ]] || fail "sessions, identities, leaders or unread mail changed: $BEFORE -> $AFTER"
echo "ok - root, members, leaders and queued mail survive a reload"
ENDED=$(grep -c '"state":"ended"' "$XDG_DATA_HOME/remuda/butler/agents.jsonl")
[[ $ENDED == 0 ]] || fail "$ENDED identities marked ended"
echo "ok - no member is swept as ended"
r butler send alice "after reload" >/dev/null 2>&1 || fail "send to a member after the reload: $(r butler send alice x 2>&1)"
echo "ok - mail reaches a member after the reload"
echo PASS
