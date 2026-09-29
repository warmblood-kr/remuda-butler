#!/usr/bin/env bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
REMUDA_BIN=$(command -v "$REMUDA_BIN")
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/bf.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd -P)
SERVER=butler-fallback
export HOME=$SCRATCH/home XDG_CONFIG_HOME=$SCRATCH/config XDG_DATA_HOME=$SCRATCH/data
export REMUDA_RUNTIME_DIR=$SCRATCH/r REMUDA_NO_UPDATE_CHECK=1 REMUDA_BUTLER_PROJECT_HOME=$SCRATCH/projects
unset REMUDA_BUTLER_AGENT_ORDER
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/remuda/mods/butler" "$REMUDA_RUNTIME_DIR" "$SCRATCH/bin"
tar -c -C "$REPO" extension.toml packages | tar -x -C "$XDG_DATA_HOME/remuda/mods/butler"
cleanup() {
  REMUDA_RUNTIME_DIR="$SCRATCH/r" "$REMUDA_BIN" -s butler-fallback stop -f >/dev/null 2>&1 || true
  REMUDA_RUNTIME_DIR="$SCRATCH/p" "$REMUDA_BIN" -s butler-fallback-pending stop -f >/dev/null 2>&1 || true
  REMUDA_RUNTIME_DIR="$SCRATCH/e" "$REMUDA_BIN" -s butler-fallback-empty stop -f >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
cat > "$SCRATCH/bin/stub-login" <<'STUB'
#!/bin/sh
printf 'Please log in to continue\n'
sleep 30
STUB
cat > "$SCRATCH/bin/stub-select-login" <<'STUB'
#!/bin/sh
printf 'Select login method\n'
sleep 30
STUB
cat > "$SCRATCH/bin/stub-expired" <<'STUB'
#!/bin/sh
printf 'Please run /login\n❯\n'
sleep 30
STUB
cat > "$SCRATCH/bin/stub-hang" <<'STUB'
#!/bin/sh
printf 'Loading agent...\n'
sleep 30
STUB
cat > "$SCRATCH/bin/stub-ready" <<'STUB'
#!/bin/sh
printf '\033[2J\033[HIDLE PROMPT\n'
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
HAS_TYPED_FAIL=$(lua 'return type(remuda.fail)')
STATUS_OK=false
for _ in $(seq 50); do
  if "$REMUDA_BIN" -s "$SERVER" butler status >"$SCRATCH/status.out" 2>"$SCRATCH/status.err"; then
    STATUS_OK=true
    grep -F 'butler: up (claude)' "$SCRATCH/status.out" >/dev/null && break
  else
    grep -F 'launching' "$SCRATCH/status.out" "$SCRATCH/status.err" >/dev/null || true
  fi
  sleep 0.1
done
$STATUS_OK || fail "ready Butler status never exited 0: $(cat "$SCRATCH/status.out" "$SCRATCH/status.err")"
grep -F 'butler: up (claude)' "$SCRATCH/status.out" >/dev/null || fail "status omitted selected kind"
# Registering these kinds exercises the chooser without adding branches to it.
lua 'local function add(id, exe, ready, login, order)
  remuda._butler_contribute("butler.agent", id, {
    order=order or 50, executable=exe, argv=function() return {exe} end,
    ready=function(_, screen) return screen:find(ready, 1, true) ~= nil end,
    login=login or {}, dialogs={}, working=function() return false end,
  })
end
add("missing", "absent-agent", "IDLE")
add("loggedout", "stub-login", "IDLE", {"Please log in"})
add("selectlogin", "stub-select-login", "IDLE", {"Select login method"})
add("expired", "stub-expired", "❯", {"Please run /login"})
add("hang", "stub-hang", "IDLE")
add("ready", "stub-ready", "IDLE")
add("early", "stub-ready", "IDLE", nil, 1)' >/dev/null
# A lower-order contributed kind is first in the configured default when no
# order override is set, and its ready candidate completes asynchronously.
lua 'local order=remuda._butler_configured_agent_order(); assert(order[1]=="early", table.concat(order, ","));
remuda._butler_choose_async(order, {name="order-check", spec=function() return {} end,
  env=function() return {} end}, function(name, kind) remuda._butler_test_order_kind=kind; if name then remuda.close(name) end end)' >/dev/null
for _ in $(seq 50); do
  [[ $(lua 'return remuda._butler_test_order_kind or ""') == early ]] && break
  sleep 0.1
done
[[ $(lua 'return remuda._butler_test_order_kind or ""') == early ]] || fail "lower-order kind was not tried first"
# Codex starts through `remuda _codex_tui`, but its registry entry requires
# the separate `codex` CLI. Its precheck must reject that missing executable.
lua 'local attempts=remuda._butler_choose({"codex"}, {
  name="codex-requires", spec=function() return {name="codex", telemetry={status_path="/tmp/codex-status"}} end,
  env=function() return {} end,
}, function() end); remuda._butler_codex_requires=attempts[1]' >/dev/null
for _ in $(seq 20); do
  [[ $(lua 'return remuda._butler_codex_requires and remuda._butler_codex_requires.reason or ""') == not_found ]] && break
  sleep 0.1
done
[[ $(lua 'return remuda._butler_codex_requires and remuda._butler_codex_requires.detail or ""') == *"codex not found in PATH"* ]] ||
  fail "Codex precheck did not use its required executable"
# A pending readiness probe must leave command dispatch responsive.
lua 'remuda._butler_choose_async({"hang"}, {name="async-hang", spec=function() return {} end,
  env=function() return {} end}, function() end)' >/dev/null
"$REMUDA_BIN" -s "$SERVER" -e 'return "responsive"' >"$SCRATCH/responsive.out" &
RESPONSIVE_PID=$!
for _ in $(seq 20); do ! kill -0 "$RESPONSIVE_PID" 2>/dev/null && break; sleep 0.1; done
if kill -0 "$RESPONSIVE_PID" 2>/dev/null; then fail "member readiness blocked the daemon"; fi
wait "$RESPONSIVE_PID"
grep -qx responsive "$SCRATCH/responsive.out" || fail "responsive command returned unexpected output"
# Full async failure matrix before the ready kind: not_found, login, timeout,
# then ready. Login must win when an expired-token screen also has a composer.
lua 'remuda._butler_readiness_timeout=5
remuda._butler_matrix_attempts=remuda._butler_choose({"missing","loggedout","selectlogin","expired","hang","ready"}, {
  name="chooser", spec=function() return {} end, env=function() return {} end,
}, function(name, kind, attempts)
  local reasons={}; for _, attempt in ipairs(attempts) do reasons[#reasons+1]=attempt.reason end
  remuda._butler_matrix_result=tostring(kind)..":"..table.concat(reasons, ",")
  if name then remuda.close(name) end
end)' >/dev/null
for _ in $(seq 250); do
  [[ -n $(lua 'return remuda._butler_matrix_result or ""') ]] && break
  sleep 0.1
done
MATRIX=$(lua 'local a={}; for _,x in ipairs(remuda._butler_matrix_attempts or {}) do a[#a+1]=x.kind..":"..x.reason end; return (remuda._butler_matrix_result or "").." attempts="..table.concat(a, ",")')
[[ "$MATRIX" == ready:not_found,login,login,login,timeout,ready* ]] || fail "async classification was wrong: $MATRIX"
# Exercise the same chooser through the Butler bootstrap and verify its report.
lua 'remuda._butler_candidate_order={"missing","ready"}; remuda._butler_readiness_timeout=5; remuda.close(remuda._butler_name); remuda._butler_reconcile()' >/dev/null
ROSTER=""
for _ in $(seq 50); do
  ROSTER=$("$REMUDA_BIN" -s "$SERVER" butler sessions)
  [[ "$ROSTER" == *$'butler\tready'* ]] && break
  sleep 0.1
done
[[ "$ROSTER" == *$'butler\tready'* ]] || fail "registered ready kind was not selected: $ROSTER"
[[ "$ROSTER" == *"missing: not_found"* ]] || fail "skipped candidate reason was not shown: $ROSTER"
# Exhaustion returns the classified attempts to callers and closes failed panes.
lua 'remuda._butler_candidate_order={"missing","loggedout","hang"}; remuda._butler_readiness_timeout=2; remuda.close(remuda._butler_name); remuda._butler_reconcile()' >/dev/null
ALL_ROSTER=$(lua 'return remuda._butler_sessions()')
for _ in $(seq 300); do
  ALL_ROSTER=$(lua 'return remuda._butler_sessions()')
  [[ "$ALL_ROSTER" == *"missing: not_found"* && "$ALL_ROSTER" == *"loggedout: login"* && "$ALL_ROSTER" == *"hang: timeout"* ]] && break
  sleep 0.1
done
for reason in 'missing: not_found' 'loggedout: login' 'hang: timeout'; do
  shown=${reason%%:*}
  [[ "$ALL_ROSTER" == *"$shown:"* ]] || fail "sessions omitted $shown attempt: $ALL_ROSTER"
done
# A completely fresh install with neither built-in executable keeps the
# command surface loaded and reports the failure through status.
SERVER=butler-fallback-empty
export HOME=$SCRATCH/empty-home XDG_CONFIG_HOME=$SCRATCH/empty-config
export XDG_DATA_HOME=$SCRATCH/empty-data REMUDA_RUNTIME_DIR=$SCRATCH/e
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/remuda/mods/butler" "$REMUDA_RUNTIME_DIR"
tar -c -C "$REPO" extension.toml packages | tar -x -C "$XDG_DATA_HOME/remuda/mods/butler"
export PATH="$SCRATCH/empty-bin:/usr/bin:/bin"
mkdir -p "$SCRATCH/empty-bin"
"$REMUDA_BIN" -s "$SERVER" daemon >"$SCRATCH/empty-daemon.log" 2>&1 &
for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$SERVER.sock ]] && break; sleep 0.1; done
"$REMUDA_BIN" -s "$SERVER" exec butler >"$SCRATCH/exec.out" 2>"$SCRATCH/exec.err" ||
  fail "bare exec butler should remain asynchronous"
set +e
"$REMUDA_BIN" -s "$SERVER" butler status >"$SCRATCH/status-failed.out" 2>"$SCRATCH/status-failed.err"
FAILED_STATUS=$?
set -e
if [[ $HAS_TYPED_FAIL == function ]]; then
  [[ $FAILED_STATUS == 1 ]] || fail "failed status should exit 1, got $FAILED_STATUS"
else
  [[ $FAILED_STATUS != 0 ]] || fail "legacy failed status should be nonzero"
fi
[[ ! -s "$SCRATCH/status-failed.out" ]] || fail "failed status wrote to stdout: $(cat "$SCRATCH/status-failed.out")"
for reason in 'claude: not_found' 'codex: not_found'; do
  grep -F "$reason" "$SCRATCH/status-failed.err" >/dev/null ||
    fail "status omitted $reason: $(cat "$SCRATCH/status-failed.out" "$SCRATCH/status-failed.err")"
done
if [[ $HAS_TYPED_FAIL == function ]] && grep -E 'runtime error|stack traceback' "$SCRATCH/status-failed.err" >/dev/null; then
  fail "failed status leaked a runtime error or Lua traceback: $(cat "$SCRATCH/status-failed.err")"
fi
for failure in 'butler: claude: not_found' 'butler: codex: not_found'; do
  grep -F "$failure" "$SCRATCH/empty-daemon.log" >/dev/null || fail "daemon log omitted clean failure line $failure"
done
EMPTY_ROSTER=$("$REMUDA_BIN" -s "$SERVER" butler sessions)
for reason in 'BUTLER ATTEMPTS' 'claude: not_found' 'codex: not_found'; do
  [[ "$EMPTY_ROSTER" == *"$reason"* ]] || fail "sessions command unavailable or omitted $reason: $EMPTY_ROSTER"
done
# A hanging first candidate leaves the command available and status reports
# the pending prefix while the image continues servicing requests.
SERVER=butler-fallback-pending
export HOME=$SCRATCH/pending-home XDG_CONFIG_HOME=$SCRATCH/pending-config
export XDG_DATA_HOME=$SCRATCH/pending-data REMUDA_RUNTIME_DIR=$SCRATCH/p
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/remuda/mods/butler" "$REMUDA_RUNTIME_DIR" "$SCRATCH/pending-bin"
tar -c -C "$REPO" extension.toml packages | tar -x -C "$XDG_DATA_HOME/remuda/mods/butler"
cat > "$SCRATCH/pending-bin/claude" <<'STUB'
#!/bin/sh
if [ -f "$REMUDA_BUTLER_PROJECT_HOME/reload-ready" ]; then
  printf '\033[2J\033[H─\n❯\n'
  sleep 30
  exit
fi
printf 'Loading agent...\n'
sleep 30
STUB
chmod +x "$SCRATCH/pending-bin/claude"
export PATH="$SCRATCH/pending-bin:/usr/bin:/bin"
REMUDA_BUTLER_READINESS_TIMEOUT=2 "$REMUDA_BIN" -s "$SERVER" daemon >"$SCRATCH/pending-daemon.log" 2>&1 &
for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$SERVER.sock ]] && break; sleep 0.1; done
"$REMUDA_BIN" -s "$SERVER" exec butler >"$SCRATCH/exec-pending.out" 2>"$SCRATCH/exec-pending.err" ||
  fail "pending exec should remain asynchronous"
set +e
"$REMUDA_BIN" -s "$SERVER" butler status >"$SCRATCH/status-pending.out" 2>"$SCRATCH/status-pending.err"
PENDING_STATUS=$?
set -e
[[ $PENDING_STATUS == 75 || $PENDING_STATUS == 1 ]] || fail "pending status returned unexpected code $PENDING_STATUS"
if [[ $HAS_TYPED_FAIL == function ]]; then
  [[ $PENDING_STATUS == 75 ]] || fail "pending status should exit 75, got $PENDING_STATUS"
fi
grep -F 'launching' "$SCRATCH/status-pending.out" "$SCRATCH/status-pending.err" >/dev/null ||
  fail "pending status omitted launching prefix: $(cat "$SCRATCH/status-pending.out" "$SCRATCH/status-pending.err")"
grep -F 'readiness budget: 19' "$SCRATCH/status-pending.err" >/dev/null ||
  fail "pending status omitted the configured two-candidate chain budget: $(cat "$SCRATCH/status-pending.err")"
"$REMUDA_BIN" -s "$SERVER" -e 'return "responsive"' >"$SCRATCH/root-responsive.out" &
ROOT_RESPONSIVE_PID=$!
for _ in $(seq 10); do ! kill -0 "$ROOT_RESPONSIVE_PID" 2>/dev/null && break; sleep 0.1; done
if kill -0 "$ROOT_RESPONSIVE_PID" 2>/dev/null; then fail "root readiness blocked the daemon"; fi
wait "$ROOT_RESPONSIVE_PID"
grep -qx responsive "$SCRATCH/root-responsive.out" || fail "root responsive call returned unexpected output"
# Reload while the first probe is hanging. stop() must cancel its owned
# chooser and close that candidate before the new lifecycle launches again.
lua 'remuda._butler_test_old_lifecycle=remuda._butler_state; local n=0; for _ in pairs(remuda._butler_state.active_choosers) do n=n+1 end; assert(n==1, "expected one active chooser")' >/dev/null
mkdir -p "$REMUDA_BUTLER_PROJECT_HOME"
touch "$REMUDA_BUTLER_PROJECT_HOME/reload-ready"
"$REMUDA_BIN" -s "$SERVER" -e 'remuda.reload("butler")' >/dev/null
RELOADED=false
for _ in $(seq 100); do
  if "$REMUDA_BIN" -s "$SERVER" butler status >"$SCRATCH/reload-status.out" 2>"$SCRATCH/reload-status.err" &&
      grep -F 'butler: up (claude)' "$SCRATCH/reload-status.out" >/dev/null; then
    RELOADED=true
    break
  fi
  sleep 0.1
done
$RELOADED || fail "Butler did not relaunch cleanly after a mid-probe reload: $(cat "$SCRATCH/reload-status.out" "$SCRATCH/reload-status.err")"
lua 'local old=remuda._butler_test_old_lifecycle.active_choosers; assert(next(old)==nil, "old lifecycle retained an active chooser"); local active=remuda._butler_state.active_choosers; assert(next(active)==nil, "new lifecycle retained a completed chooser")' >/dev/null ||
  fail "chooser remained registered after reload/relaunch"
LIVE_ROOTS=$(lua 'local n=0; for _,s in ipairs(remuda.ls()) do if s.name=="butler" and s.alive then n=n+1 end end; return n')
[[ "$LIVE_ROOTS" == 1 ]] || fail "expected exactly one live root after reload, got $LIVE_ROOTS"
echo PASS
