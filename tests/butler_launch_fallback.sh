#!/usr/bin/env bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
REMUDA_BIN=$(command -v "$REMUDA_BIN")
SCRATCH=$(mktemp -d /tmp/butler-fallback.XXXXXX)
SERVER=butler-fallback
export HOME=$SCRATCH/home XDG_CONFIG_HOME=$SCRATCH/config XDG_DATA_HOME=$SCRATCH/data
export REMUDA_RUNTIME_DIR=$SCRATCH/run REMUDA_NO_UPDATE_CHECK=1 REMUDA_BUTLER_PROJECT_HOME=$SCRATCH/projects
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/remuda/mods/butler" "$REMUDA_RUNTIME_DIR" "$SCRATCH/bin"
tar -c -C "$REPO" extension.toml packages | tar -x -C "$XDG_DATA_HOME/remuda/mods/butler"
cleanup() {
  REMUDA_RUNTIME_DIR="$SCRATCH/run" "$REMUDA_BIN" -s butler-fallback stop -f >/dev/null 2>&1 || true
  REMUDA_RUNTIME_DIR="$SCRATCH/empty-run" "$REMUDA_BIN" -s butler-fallback-empty stop -f >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
cat > "$SCRATCH/bin/stub-login" <<'STUB'
#!/bin/sh
printf 'Please log in to continue\n'
sleep 30
STUB
cat > "$SCRATCH/bin/stub-hang" <<'STUB'
#!/bin/sh
printf 'Loading agent...\n'
sleep 30
STUB
cat > "$SCRATCH/bin/stub-ready" <<'STUB'
#!/bin/sh
printf 'IDLE PROMPT\n'
sleep 30
STUB
cat > "$SCRATCH/bin/claude" <<'STUB'
#!/bin/sh
printf '─\n❯\n'
sleep 30
STUB
chmod +x "$SCRATCH/bin"/*
export PATH="$SCRATCH/bin:/usr/bin:/bin"
"$REMUDA_BIN" -s "$SERVER" daemon >"$SCRATCH/daemon.log" 2>&1 &
for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$SERVER.sock ]] && break; sleep 0.1; done
lua() { "$REMUDA_BIN" -s "$SERVER" -e "$1"; }
"$REMUDA_BIN" -s "$SERVER" exec butler >/dev/null
loaded=false
for _ in $(seq 50); do if lua 'return remuda._butler_choose ~= nil' 2>/dev/null | grep -qx true; then loaded=true; break; fi; sleep 0.1; done
$loaded || { cat "$SCRATCH/daemon.log" >&2; fail "Butler implementation did not load"; }
for _ in $(seq 50); do lua 'return remuda._butler_choose ~= nil' 2>/dev/null | grep -qx true && break; sleep 0.1; done
# Registering these kinds exercises the chooser without adding branches to it.
lua 'local function add(id, exe, ready, login)
  remuda._butler_contribute("butler.agent", id, {
    executable=exe, argv=function() return {exe} end,
    ready=function(_, screen) return screen:find(ready, 1, true) ~= nil end,
    login=login or {}, dialogs={}, working=function() return false end,
  })
end
add("missing", "absent-agent", "IDLE")
add("loggedout", "stub-login", "IDLE", {"Please log in"})
add("hang", "stub-hang", "IDLE")
add("ready", "stub-ready", "IDLE")' >/dev/null
# Full failure matrix before the ready kind: not_found, login, timeout, ready.
lua 'remuda._butler_readiness_timeout=5
local name, kind, attempts=remuda._butler_choose({"missing","loggedout","hang","ready"}, {
  name="chooser", spec=function() return {} end, env=function() return {} end,
})
assert(name and kind=="ready", tostring(kind))
assert(attempts[1].reason=="not_found", attempts[1].reason)
assert(attempts[2].reason=="login", attempts[2].reason)
assert(attempts[3].reason=="timeout", tostring(attempts[3].kind)..":"..tostring(attempts[3].reason).." count="..#attempts)
remuda.close(name)' >/dev/null
# Exercise the same chooser through the Butler bootstrap and verify its report.
lua 'remuda.close(remuda._butler_name); remuda._butler_candidate_order={"loggedout","ready"}; remuda._butler_readiness_timeout=5; remuda._butler_reconcile()' >/dev/null
ROSTER=$("$REMUDA_BIN" -s "$SERVER" butler sessions)
[[ "$ROSTER" == *$'butler\tready'* ]] || fail "registered ready kind was not selected: $ROSTER"
[[ "$ROSTER" == *"loggedout: login"* ]] || fail "skipped login reason was not shown: $ROSTER"
# Exhaustion returns the classified attempts to callers and closes failed panes.
lua 'remuda.close(remuda._butler_name); remuda._butler_candidate_order={"missing","loggedout","hang"}; remuda._butler_readiness_timeout=5' >/dev/null
if lua 'local _,err=remuda._butler_reconcile(); assert(err, "all-fail unexpectedly succeeded"); error(err)' >"$SCRATCH/all.out" 2>"$SCRATCH/all.err"; then
  fail "all candidate failures must be nonzero"
fi
for reason in 'missing' 'not_found' 'loggedout' 'login' 'hang' 'timeout'; do
  grep -F "$reason" "$SCRATCH/all.err" >/dev/null || fail "stderr omitted $reason: $(cat "$SCRATCH/all.err")"
done
ALL_ROSTER=$(lua 'return remuda._butler_sessions()')
for reason in 'missing: not_found' 'loggedout: login' 'hang: timeout'; do
  [[ "$ALL_ROSTER" == *"$reason"* ]] || fail "sessions omitted $reason: $ALL_ROSTER"
done
# A completely fresh install with neither built-in executable must make the
# initial lifecycle start fail through the CLI as well.
SERVER=butler-fallback-empty
export HOME=$SCRATCH/empty-home XDG_CONFIG_HOME=$SCRATCH/empty-config
export XDG_DATA_HOME=$SCRATCH/empty-data REMUDA_RUNTIME_DIR=$SCRATCH/empty-run
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/remuda/mods/butler" "$REMUDA_RUNTIME_DIR"
tar -c -C "$REPO" extension.toml packages | tar -x -C "$XDG_DATA_HOME/remuda/mods/butler"
export PATH="$SCRATCH/empty-bin:/usr/bin:/bin"
mkdir -p "$SCRATCH/empty-bin"
"$REMUDA_BIN" -s "$SERVER" daemon >"$SCRATCH/empty-daemon.log" 2>&1 &
for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$SERVER.sock ]] && break; sleep 0.1; done
if "$REMUDA_BIN" -s "$SERVER" exec butler >"$SCRATCH/exec.out" 2>"$SCRATCH/exec.err"; then
  fail "fresh-install exec butler must fail when Claude and Codex are missing"
fi
for reason in 'claude: not_found' 'codex: not_found'; do
  grep -F "$reason" "$SCRATCH/exec.err" >/dev/null || grep -F "$reason" "$SCRATCH/empty-daemon.log" >/dev/null ||
    fail "fresh-install error omitted $reason"
done
echo PASS
