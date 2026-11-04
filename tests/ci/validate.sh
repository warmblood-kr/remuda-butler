#!/usr/bin/env bash
# Fast QA for the shell task pool. Not matched by tests/*.sh, so it is never a
# task itself. Covers discovery parity and kinds, failure draining, success and
# failed-task detached leaks, fixture cancellation, real Remuda auto-start
# cancellation (Linux), unrelated-session protection, env isolation, no-child
# fail-closed boundary, and ownership fail-closed behavior.
#
#   REMUDA_BIN=/path/to/pinned/remuda tests/ci/validate.sh
set -uo pipefail
export LC_ALL=C

REPO=$(cd "$(dirname "$0")/../.." && pwd -P)
source "$REPO/tests/lib/pool.sh"
# Match shell_tests.sh: no live session identity or shared cache/state roots.
pool_sanitize_env

tmp=$(mktemp -d /tmp/ci-pool-validate.XXXXXX)
tmp=$(cd "$tmp" && pwd -P)
failures=0
runner= unrelated= detached= leak_pid= sp= daemon_pid=
probe_file=

fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "PASS: $*"; }

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  for p in "$runner" "$unrelated" "$detached" "$leak_pid" "$sp" "$daemon_pid"; do
    [[ -n $p ]] && kill -KILL "$p" 2>/dev/null || true
  done
  [[ -n $probe_file && -f $probe_file ]] && rm -f "$probe_file"
  if ((failures > 0)); then
    echo "validate scratch kept: $tmp" >&2
  else
    rm -rf "$tmp"
  fi
  exit "$rc"
}
trap cleanup EXIT

wait_gone() { # pid, tries
  local pid=$1 tries=$2 i
  for ((i = 0; i < tries; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  ! kill -0 "$pid" 2>/dev/null
}

# ------------------------------------------------------------ discovery
shopt -s nullglob
: >"$tmp/expected.ids"
for path in "$REPO"/tests/*.lua; do
  base=${path##*/}
  case $base in
    session_tree.lua|butler_matrix_relay.lua|butler_diagnostics_matrix.lua|butler_coordination_config.lua) continue ;;
    butler_approve_text.lua|butler_status_hook.lua|butler_guard.lua|butler_adopt.lua|butler_approval_retry.lua|butler_schedule_cli.lua|butler_typed_lines_cli.lua) continue ;;
  esac
  echo "standalone-lua/$base" >>"$tmp/expected.ids"
done
for path in "$REPO"/tests/*.sh; do
  base=${path##*/}
  case $base in
    rust_tests.sh|golden_guidance.sh|shell_tests.sh|awk-timeout.sh|core_ref.sh) continue ;;
    lua_tests.sh)
      for lpath in "$REPO"/tests/lua/*_test.lua; do
        lbase=${lpath##*/}
        if [[ $lbase == butler_path_test.lua ]]; then
          echo "direct-lua/$lbase" >>"$tmp/expected.ids"
        else
          echo "embedded-lua/$lbase" >>"$tmp/expected.ids"
        fi
      done
      continue
      ;;
  esac
  echo "shell/$base" >>"$tmp/expected.ids"
done
sort -o "$tmp/expected.ids" "$tmp/expected.ids"

"$REPO/tests/ci/manifest.sh" --list >"$tmp/actual.ids" || fail "manifest --list failed"
sort -o "$tmp/actual.ids" "$tmp/actual.ids"
if ! diff -u "$tmp/expected.ids" "$tmp/actual.ids" >"$tmp/coverage.diff"; then
  fail "coverage parity differs from the current rules"
  cat "$tmp/coverage.diff" >&2
else
  n_lua=$(grep -c '^standalone-lua/' "$tmp/actual.ids")
  n_shell=$(grep -c '^shell/' "$tmp/actual.ids")
  n_emb=$(grep -c '^embedded-lua/' "$tmp/actual.ids")
  n_direct=$(grep -c '^direct-lua/' "$tmp/actual.ids")
  n_total=$(wc -l <"$tmp/actual.ids" | tr -d ' ')
  pass "coverage parity: $n_total tasks ($n_lua standalone Lua, $n_shell shell, $n_emb embedded, $n_direct direct)"
fi

tsv=$tmp/manifest.tsv
"$REPO/tests/ci/manifest.sh" --tsv >"$tsv" || fail "manifest --tsv failed"
grep -qx 'shell/lua_tests.sh' "$tmp/actual.ids" && fail "lua_tests.sh aggregate must not be a task"
grep -q '^shell/awk-timeout.sh' "$tmp/actual.ids" && fail "awk-timeout.sh must not be a task"
grep -q '^shell/core_ref.sh' "$tmp/actual.ids" && fail "core_ref.sh must not be a task"
grep -q '^embedded-lua/butler_path_test.lua' "$tmp/actual.ids" && fail "path test must be direct, not embedded"
awk -F'\t' '$1=="direct-lua/butler_path_test.lua" { found=($3=="direct-lua" && $4=="tests/lua/butler_path_test.lua") } END { exit !found }' "$tsv" ||
  fail "path test is not the direct-lua kind"
for f in butler_cli_unit_test.lua butler_input_queue_test.lua butler_opencode_readiness_test.lua butler_owner_input_test.lua butler_schedule_delivery_test.lua; do
  awk -F'\t' -v id="embedded-lua/$f" '$1==id { found=($3=="embedded-nochild") } END { exit !found }' "$tsv" ||
    fail "$f is not embedded-nochild"
done

# ------------------------------------------------------------ failure
printf 'ok\t1\tcmd\texit 0\n' >"$tmp/fail.tsv"
printf 'bad\t1\tcmd\techo boom; exit 7\n' >>"$tmp/fail.tsv"
(
  POOL_CANCEL_REQUESTED=0
  pool_run "$tmp/fail.tsv" 2 "$tmp/fail-logs" "$tmp/fail-tasks" "$tmp" "$REPO/tests/lib/pool_task.sh"
) >"$tmp/fail.out" 2>&1
rc=$?
[[ $rc == 1 ]] && pass "failure injection: nonzero pool status" || fail "failure injection: exit $rc, expected 1"
grep -q '^FAIL bad' "$tmp/fail.out" || fail "failure injection: no FAIL bad line"
grep -q 'boom' "$tmp/fail-logs/bad.log" || fail "failure injection: failing log not retained"
[[ -f $tmp/fail-logs/ok.status && -f $tmp/fail-logs/bad.status ]] || fail "failure injection: status files missing"
[[ -f $tmp/fail-logs/bad.status && $(cut -f1 "$tmp/fail-logs/bad.status") == 7 ]] ||
  fail "failure injection: failing task status is not 7"
grep -q 'task rusage' "$tmp/fail.out" || fail "failure injection: no labelled rusage summary"

# ------------------------------------------------ detached leak after failure
cat >"$tmp/leak_task.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
perl -MPOSIX -e '
  POSIX::setsid();
  chdir $ENV{CI_POOL_TASK_DIR} or die $!;
  open my $f, ">", "$ENV{CI_POOL_TASK_DIR}/registry/leak.pid" or die $!;
  print $f "$$\n"; close $f;
  exec "sleep", "300";
' &
for _ in $(seq 1 100); do [[ -s "$CI_POOL_TASK_DIR/registry/leak.pid" ]] && break; sleep 0.01; done
exit "${LEAK_RC:-0}"
SH
chmod +x "$tmp/leak_task.sh"
for mode in success failure; do
  if [[ $mode == success ]]; then lrc=0; else lrc=3; fi
  printf 'leak-%s\t1\tcmd\tLEAK_RC=%s bash %s\n' "$mode" "$lrc" "$tmp/leak_task.sh" >"$tmp/leak.tsv"
  (
    POOL_CANCEL_REQUESTED=0
    pool_run "$tmp/leak.tsv" 1 "$tmp/leak-$mode-logs" "$tmp/leak-$mode-tasks" "$tmp" "$REPO/tests/lib/pool_task.sh"
  ) >"$tmp/leak-$mode.out" 2>&1
  rc=$?
  [[ $rc == 1 ]] && pass "$mode-path leak: pool failed" || fail "$mode-path leak: pool exit $rc, expected 1"
  grep -q 'surviving processes after task\|detached survivors' "$tmp/leak-$mode.out" ||
    fail "$mode-path leak: no survivor report"
  f=$(find "$tmp/leak-$mode-tasks" -path '*/registry/leak.pid' -print -quit 2>/dev/null || true)
  if [[ -n $f ]]; then
    lp=$(head -1 "$f")
    wait_gone "$lp" 100 && pass "$mode-path leak: detached process killed" ||
      fail "$mode-path leak: detached process still alive"
  fi
done

# ---------------------------------------- token-only leak after success
if [[ -d /proc ]]; then
  cat >"$tmp/token_only_task.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
perl -MPOSIX -e '
  POSIX::setsid();
  chdir $ENV{CI_POOL_TASK_DIR} or die $!;
  open my $f, ">", "$ENV{CI_POOL_TASK_DIR}/token-only.pid" or die $!;
  print $f "$$\n"; close $f;
  exec "sleep", "300";
' &
for _ in $(seq 1 100); do
  [[ -s "$CI_POOL_TASK_DIR/token-only.pid" ]] && break
  sleep 0.01
done
exit 0
SH
  chmod +x "$tmp/token_only_task.sh"
  printf 'token-leak\t1\tcmd\tbash %s\n' "$tmp/token_only_task.sh" >"$tmp/token.tsv"
  (
    POOL_CANCEL_REQUESTED=0
    pool_run "$tmp/token.tsv" 1 "$tmp/token-logs" "$tmp/token-tasks" "$tmp" "$REPO/tests/lib/pool_task.sh"
  ) >"$tmp/token.out" 2>&1
  rc=$?
  [[ $rc == 1 ]] && pass "token-only leak: detected survivor fails the suite" ||
    fail "token-only leak: pool exit $rc, expected 1"
  grep -q 'detached survivors detected' "$tmp/token.out" ||
    fail "token-only leak: no detected-survivor report"
  f=$(find "$tmp/token-tasks" -name token-only.pid -print -quit 2>/dev/null || true)
  if [[ -n $f ]]; then
    tp=$(head -1 "$f")
    wait_gone "$tp" 100 && pass "token-only leak: survivor killed" ||
      fail "token-only leak: survivor still alive"
  fi
else
  echo "SKIP: token-only leak QA needs Linux /proc"
fi

# ------------------------------------- cancellation of a fixture detached child
cat >"$tmp/cancel_task.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
unset $(compgen -e | grep '^REMUDA_' | grep -vx REMUDA_BIN) 2>/dev/null || true
perl -MPOSIX -e '
  POSIX::setsid();
  chdir $ENV{CI_POOL_TASK_DIR} or die $!;
  open my $f, ">", "$ENV{CI_POOL_TASK_DIR}/registry/detached.pid" or die $!;
  print $f "$$\n"; close $f;
  exec "sleep", "300";
' &
sleep 300
SH
chmod +x "$tmp/cancel_task.sh"
printf 'hang\t1\tcmd\tbash %s\n' "$tmp/cancel_task.sh" >"$tmp/cancel.tsv"
cat >"$tmp/run_cancel.sh" <<SH
#!/usr/bin/env bash
set -uo pipefail
source "$REPO/tests/lib/pool.sh"
POOL_CANCEL_REQUESTED=0
trap 'POOL_CANCEL_REQUESTED=1' INT TERM
pool_run "$tmp/cancel.tsv" 1 "$tmp/cancel-logs" "$tmp/cancel-tasks" "$tmp" "$REPO/tests/lib/pool_task.sh"
SH
chmod +x "$tmp/run_cancel.sh"
perl -MPOSIX -e 'POSIX::setsid(); exec "sleep","300"' &
unrelated=$!
bash "$tmp/run_cancel.sh" >"$tmp/cancel.out" 2>&1 &
runner=$!
for ((i = 0; i < 150; i++)); do
  f=$(find "$tmp/cancel-tasks" -path '*/registry/detached.pid' -print -quit 2>/dev/null || true)
  [[ -n $f ]] && { detached=$(head -1 "$f"); break; }
  kill -0 "$runner" 2>/dev/null || break
  sleep 0.1
done
if [[ -z $detached ]]; then
  fail "cancellation: detached child never registered"
else
  kill -TERM "$runner" 2>/dev/null || true
  wait "$runner"; rc=$?
  [[ $rc != 0 ]] && pass "cancellation: nonzero pool status ($rc)" || fail "cancellation: pool exited 0"
  wait_gone "$detached" 150 && pass "cancellation: fixture survivor killed" ||
    fail "cancellation: fixture survivor still alive"
  kill -0 "$unrelated" 2>/dev/null && pass "cancellation: unrelated session survived" ||
    fail "cancellation: unrelated session was killed"
  kill -TERM "$unrelated" 2>/dev/null || true
  wait "$unrelated" 2>/dev/null || true
  unrelated=
  grep -q 'cancellation requested' "$tmp/cancel.out" || fail "cancellation: no cancellation log"
  grep -q '^FAIL hang' "$tmp/cancel.out" || fail "cancellation: no FAIL hang line"
  find "$tmp/cancel-logs" -name '*.status' -print -quit | grep -q . &&
    pass "cancellation: status/log retained" || fail "cancellation: no status retained"
fi

# ------------------------- real Remuda auto-start daemon cancellation
if [[ -n ${REMUDA_BIN:-} && -x ${REMUDA_BIN:-} ]]; then
  cat >"$tmp/real_daemon_task.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
name="c$RANDOM$RANDOM"
"$REMUDA_BIN" -s "$name" -e "1" || echo "client failed: $?"
lock="$REMUDA_RUNTIME_DIR/remuda/$name.sock.lock"
for _ in $(seq 1 100); do [[ -f $lock ]] && break; sleep 0.05; done
[[ -f $lock ]] || { echo "no daemon lock: $lock" >&2; exit 4; }
pid=$(tr -cd '0-9' <"$lock")
[[ -n $pid ]] || exit 4
printf '%s\n' "$pid" >"$CI_POOL_TASK_DIR/registry/daemon.pid"
echo "daemon-pid=$pid"
echo "task-pgid=$(ps -o pgid= -p $$ | tr -d ' ')"
echo "daemon-pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')"
sleep 300
SH
  chmod +x "$tmp/real_daemon_task.sh"
  printf 'real-daemon\t1\tcmd\tbash %s\n' "$tmp/real_daemon_task.sh" >"$tmp/real.tsv"
  cat >"$tmp/run_real.sh" <<SH
#!/usr/bin/env bash
set -uo pipefail
source "$REPO/tests/lib/pool.sh"
POOL_CANCEL_REQUESTED=0
trap 'POOL_CANCEL_REQUESTED=1' INT TERM
pool_run "$tmp/real.tsv" 1 "$tmp/real-logs" "$tmp/real-tasks" "$tmp" "$REPO/tests/lib/pool_task.sh"
SH
  chmod +x "$tmp/run_real.sh"
  perl -MPOSIX -e 'POSIX::setsid(); exec "sleep","300"' &
  unrelated=$!
  bash "$tmp/run_real.sh" >"$tmp/real.out" 2>&1 &
  runner=$!
  for ((i = 0; i < 200; i++)); do
    f=$(find "$tmp/real-tasks" -path '*/registry/daemon.pid' -print -quit 2>/dev/null || true)
    [[ -n $f ]] && { daemon_pid=$(head -1 "$f"); break; }
    kill -0 "$runner" 2>/dev/null || break
    sleep 0.1
  done
  if [[ -z $daemon_pid ]]; then
    fail "real daemon cancellation: daemon did not start"
  else
    det=$(grep '^daemon-pgid=' "$tmp/real-logs/real-daemon.log" | tail -1 | cut -d= -f2)
    tpg=$(grep '^task-pgid=' "$tmp/real-logs/real-daemon.log" | tail -1 | cut -d= -f2)
    kill -TERM "$runner" 2>/dev/null || true
    wait "$runner"; rc=$?
    [[ $rc != 0 ]] && pass "real daemon cancellation: nonzero pool status ($rc)" ||
      fail "real daemon cancellation: pool exited 0"
    wait_gone "$daemon_pid" 200 && pass "real daemon cancellation: Remuda daemon killed" ||
      fail "real daemon cancellation: Remuda daemon still alive"
    if [[ -n $det && -n $tpg && $det != "$tpg" ]]; then
      pass "real daemon cancellation: daemon was in a different process group"
    else
      echo "NOTE: real daemon stayed in the task group; group kill covered it"
    fi
    kill -0 "$unrelated" 2>/dev/null && pass "real daemon cancellation: unrelated session survived" ||
      fail "real daemon cancellation: unrelated session was killed"
    kill -TERM "$unrelated" 2>/dev/null || true
    wait "$unrelated" 2>/dev/null || true
    unrelated=
  fi
else
  echo "SKIP: real detached Remuda daemon cancellation needs Linux /proc and REMUDA_BIN"
fi

# ------------------------------------------------------------ env isolation
(
  export REMUDA_SESSION_ID=live-session
  export REMUDA_BUTLER_AGENT_ID=live-agent
  export REMUDA_RUNTIME_DIR=/tmp/live-runtime
  export XDG_CACHE_HOME=/tmp/live-cache
  export REMUDA_BUTLER_LIVE_CODEX=1
  unset POOL_ORIGINAL_CODEX_HOME
  export CODEX_HOME=/tmp/live-codex-home
  pool_sanitize_env
  [[ $POOL_ORIGINAL_CODEX_HOME == /tmp/live-codex-home ]] || exit 1
  printf 'env\t1\tcmd\tenv\n' >"$tmp/env.tsv"
  POOL_CANCEL_REQUESTED=0
  pool_run "$tmp/env.tsv" 1 "$tmp/env-logs" "$tmp/env-tasks" "$tmp" "$REPO/tests/lib/pool_task.sh"
  [[ $POOL_ORIGINAL_CODEX_HOME == /tmp/live-codex-home ]] || exit 1
) >"$tmp/env.out" 2>&1
rc=$?
[[ $rc == 0 ]] || fail "env isolation: pool exit $rc"
log=$tmp/env-logs/env.log
grep -q '^CODEX_HOME=/tmp/live-codex-home$' "$log" && fail "env isolation: inherited CODEX_HOME leaked"
grep -q '^REMUDA_SESSION_ID=live-session$' "$log" && fail "env isolation: live session id leaked"
grep -q '^REMUDA_BUTLER_AGENT_ID=live-agent$' "$log" && fail "env isolation: live agent id leaked"
grep -q '^REMUDA_BUTLER_LIVE_CODEX=1$' "$log" || fail "env isolation: deliberate knob dropped"
grep -q "^HOME=$tmp/env-tasks/env/home$" "$log" || fail "env isolation: HOME not task-private"
grep -q "^XDG_CACHE_HOME=$tmp/env-tasks/env/cache$" "$log" || fail "env isolation: cache not task-private"
grep -q "^XDG_STATE_HOME=$tmp/env-tasks/env/state$" "$log" || fail "env isolation: state not task-private"
grep -q "^REMUDA_RUNTIME_DIR=$tmp/env-tasks/env/remuda-runtime$" "$log" || fail "env isolation: runtime not task-private"
grep -q '^CI_POOL_TASK_TOKEN=ci-pool-' "$log" || fail "env isolation: task token missing"
[[ $failures == 0 ]] && pass "env isolation: live identity cleared, private roots and knobs retained"

# ------------------------------------------------ no-child fail-closed probe
if [[ -n ${REMUDA_BIN:-} && -x ${REMUDA_BIN:-} ]]; then
  probe_file="$REPO/tests/lua/ci_nochild_failclosed_test.lua"
  cat >"$probe_file" <<'LUA'
T.test("no-child remote boundary is closed", function()
  for _, name in ipairs({ "eval", "mcp_eval", "mcp_call", "new_session" }) do
    local ok, err
    if name == "eval" then ok, err = pcall(function() return T.eval("return 1") end)
    elseif name == "mcp_eval" then ok, err = pcall(function() return T.mcp_eval("return 1") end)
    elseif name == "mcp_call" then ok, err = pcall(function() return T.mcp_call("x") end)
    else ok, err = pcall(function() return T.new_session("n", {"sh"}) end) end
    T.ok(not ok and tostring(err):find("no%-child") ~= nil, name .. " must fail closed: " .. tostring(err))
  end
end)
LUA
  REMUDA_LUA_NO_CHILD=1 bash "$REPO/tests/lua_tests.sh" tests/lua/ci_nochild_failclosed_test.lua >"$tmp/nochild.out" 2>&1
  rc=$?
  rm -f "$probe_file"
  probe_file=
  [[ $rc == 0 ]] && pass "no-child mode: child helpers fail closed" ||
    { fail "no-child mode: fail-closed probe failed"; tail -20 "$tmp/nochild.out" >&2; }
else
  echo "SKIP: no-child fail-closed probe needs REMUDA_BIN"
fi

# ------------------------------------------------------- fail-closed checks
POOL_SELF_PID=$$
POOL_SELF_PGID=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')
pool_group_owned "$$" "$$" && fail "fail-closed: accepted own pid as an owned group" ||
  pass "fail-closed: own pid is never an owned group"
perl -MPOSIX -e 'POSIX::setsid(); exec "sleep","5"' &
sp=$!
sleep 0.1
spg=$(ps -o pgid= -p "$sp" 2>/dev/null | tr -d ' ')
if [[ -n $spg && $spg == "$sp" ]] && pool_group_owned "$sp" "$spg"; then
  pass "fail-closed: verified session leader owns its group"
else
  fail "fail-closed: verified session leader rejected"
fi
kill -TERM "$sp" 2>/dev/null || true
wait "$sp" 2>/dev/null || true
sp=
mkdir -p "$tmp/direct-task"
bash "$REPO/tests/lib/pool_task.sh" direct "$tmp/direct.status" "$tmp/direct.log" \
  "$tmp/direct-task" direct-token -- true >/dev/null 2>&1
rc=$?
[[ $rc == 98 && -f $tmp/direct.status && $(cut -f1 "$tmp/direct.status") == 98 ]] &&
  pass "fail-closed: wrapper refused to run outside an owned group" ||
  fail "fail-closed: wrapper did not refuse (exit $rc)"
if [[ -f $tmp/direct.status ]]; then
  [[ $(cut -f4 "$tmp/direct.status") == "-" && $(cut -f5 "$tmp/direct.status") == "-" &&
    $(cut -f6 "$tmp/direct.status") == "-" ]] &&
    [[ $(cut -f7 "$tmp/direct.status") == *"not a process-group leader"* ]] &&
    pass "status TSV: empty rusage fields keep their placeholder columns" ||
    fail "status TSV: placeholder columns collapsed or note moved"
fi

# ----------------------------------------- detected-leak aggregate failure
(
  POOL_TOKEN_PREFIX=fake-prefix-
  POOL_SURVIVOR_FAIL=0
  n=0
  pool_token_survivors() { n=$((n + 1)); [[ $n == 1 ]] && echo 999999; }
  pool_kill_owned() { return 0; }
  pool_audit_pool >/dev/null 2>&1
  rc=$?
  [[ $rc == 1 && $POOL_SURVIVOR_FAIL == 1 ]]
) && pass "aggregate: a detected-and-killed survivor still fails the suite" ||
  fail "aggregate: detected survivor did not fail the suite"

# ----------------------------------------- cache early-failure cleanup
(
  source "$REPO/tests/ci/core_binary.sh"
  source "$REPO/tests/core_ref.sh"
  t=$(mktemp -d /tmp/ci-core-cache.XXXXXX)
  trap 'rm -rf "$t"' EXIT
  mkdir -p "$t/cache"
  CORE_URL="$t/no-such-core"
  TMPDIR="$t"
  core_binary_build_and_publish "$t/cache" testkey "$t/cache/entry" >"$t/cache-test.log" 2>&1
  rc=$?
  [[ $rc == 0 ]] && cat "$t/cache-test.log" >&2
  [[ $rc != 0 ]] || exit 1
  [[ ! -e "$t/remuda-core-cache-testkey.lock" ]] || exit 1
  compgen -G "$t/remuda-core-build.*" >/dev/null && exit 1
  exit 0
) && pass "cache: early build failure removes temp tree and lock" ||
  fail "cache: early build failure left a lock or temp tree"

# ----------------------------------------- cache live lock is not deleted
(
  source "$REPO/tests/ci/core_binary.sh"
  source "$REPO/tests/core_ref.sh"
  t=$(mktemp -d /tmp/ci-core-cache.XXXXXX)
  trap 'rm -rf "$t"' EXIT
  mkdir -p "$t/cache" "$t/remuda-core-cache-busy.lock"
  printf '%s\n' "$$" >"$t/remuda-core-cache-busy.lock/pid"
  before=$(cat "$t/remuda-core-cache-busy.lock/pid")
  CORE_BINARY_LOCK_WAIT=2 CORE_URL="$t/no-such-core" TMPDIR="$t" \
    core_binary_build_and_publish "$t/cache" busy "$t/cache/busy" >/dev/null 2>&1
  rc=$?
  after=$(cat "$t/remuda-core-cache-busy.lock/pid" 2>/dev/null || true)
  [[ $rc == 2 && -d "$t/remuda-core-cache-busy.lock" && $before == "$after" ]]
) && pass "cache: a live lock is not deleted; waiter fails bounded" ||
  fail "cache: a live lock was deleted or not failed bounded"

if ((failures > 0)); then
  echo "pool validation FAILED: $failures check(s)" >&2
  exit 1
fi
echo "pool validation: PASS"
exit 0
