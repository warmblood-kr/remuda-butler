#!/usr/bin/env bash
# Bounded task pool for tests/shell_tests.sh.
#
# One process per task, each in its own session/process group created by
# POSIX::setsid. The pool never signals its own group: before a group signal
# it proves pid == pgid (and pid == sid on Linux). A task that cannot prove
# ownership is killed by PID only. Detached descendants are found by a unique
# non-REMUDA token in their environment (Linux) or a task-private PID registry
# (fixture/local fallback), and killed only after ownership is re-verified.
#
# bash 3.2 compatible: no associative arrays, no `wait -n`, no ${var,,}.
set -uo pipefail

POOL_SLOT_PID=()
POOL_SLOT_ID=()
POOL_SLOT_STATUS=()
POOL_SLOT_LOG=()
POOL_SLOT_START=()
POOL_SLOT_PGID=()
POOL_SLOT_TASK=()
POOL_SLOT_TOKEN=()
POOL_SLOT_REAPED=()
POOL_SLOT_WAIT_RC=()

pool_now_us() {
  if [[ -n ${EPOCHREALTIME:-} ]]; then
    printf '%s' "${EPOCHREALTIME/./}"
  else
    perl -MTime::HiRes=time -e 'printf "%d", time * 1000000'
  fi
}

pool_safe_id() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
}

# Remove live Butler/session identity and shared cache/state roots. Deliberate
# knobs (REMUDA_BIN, PATH, CORE_REF, REMUDA_LUA_RESULT_WAIT, BUTLER_TEST_FILTER,
# REMUDA_BUTLER_LIVE_CODEX) survive. CODEX_HOME is pinned to the real login
# before each task moves HOME.
pool_sanitize_env() {
  local n
  POOL_ORIGINAL_HOME=${HOME:-/tmp}
  # Do not export CODEX_HOME globally: fixtures such as the coordination-config
  # test require "no Codex layer". Capture the real login only for the opt-in
  # live Codex task, which explicitly moves HOME.
  POOL_ORIGINAL_CODEX_HOME=${CODEX_HOME:-}
  if [[ -z $POOL_ORIGINAL_CODEX_HOME && -d $POOL_ORIGINAL_HOME/.codex ]]; then
    POOL_ORIGINAL_CODEX_HOME="$POOL_ORIGINAL_HOME/.codex"
  fi
  for n in ${!REMUDA_BUTLER_@}; do
    [[ $n == REMUDA_BUTLER_LIVE_CODEX ]] && continue
    unset "$n"
  done
  unset REMUDA_SERVER REMUDA_RUNTIME_DIR REMUDA_SESSION_CAPABILITY
  unset REMUDA_SESSION_ID REMUDA_SESSION_NAME REMUDA_DAEMON_ID
  unset XDG_CACHE_HOME XDG_STATE_HOME XDG_RUNTIME_DIR
}

pool_pid_alive() {
  local pid=$1 state
  kill -0 "$pid" 2>/dev/null || return 1
  if [[ -r /proc/$pid/stat ]]; then
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
    [[ $state == Z ]] && return 1
  else
    state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ $state == Z* ]] && return 1
  fi
  return 0
}

# True only when pid leads its own group/session and is not the pool's group.
pool_group_owned() {
  local pid=$1 pgid=$2 sid
  [[ -n ${pid:-} && -n ${pgid:-} && $pgid == "$pid" ]] || return 1
  [[ $pid != "$POOL_SELF_PID" && $pgid != "$POOL_SELF_PGID" ]] || return 1
  [[ $pgid != 0 && $pgid != 1 ]] || return 1
  if [[ -r /proc/$pid/stat ]]; then
    sid=$(awk '{print $6}' "/proc/$pid/stat" 2>/dev/null)
    [[ $sid == "$pid" ]] || return 1
  fi
  return 0
}

pool_env_has() {
  local file=$1 entry=$2
  [[ -r $file ]] || return 1
  if grep -qzxF -- "$entry" "$file" 2>/dev/null; then return 0; fi
  tr '\0' '\n' <"$file" 2>/dev/null | grep -qxF -- "$entry"
}

pool_pid_token() {
  local pid=$1
  [[ -r /proc/$pid/environ ]] || return 1
  tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null |
    sed -n 's/^CI_POOL_TASK_TOKEN=//p' | head -1
}

# Ownership proof for a detached survivor: exact non-REMUDA token (Linux) or a
# PID recorded in the task's own registry (macOS and token-clearing wrappers).
pool_pid_owned() {
  local pid=$1 token=$2 taskdir=$3 f regpid
  [[ -n ${pid:-} && $pid != "$POOL_SELF_PID" ]] || return 1
  pool_pid_alive "$pid" || return 1
  if pool_env_has "/proc/$pid/environ" "CI_POOL_TASK_TOKEN=$token" ||
    pool_env_has "/proc/$pid/environ" "REMUDA_CI_TASK_TOKEN=$token"; then
    return 0
  fi
  [[ -d $taskdir/registry ]] || return 1
  for f in "$taskdir"/registry/*.pid; do
    [[ -f $f ]] || continue
    regpid=$(awk 'NR==1 {print $1}' "$f")
    [[ $regpid == "$pid" ]] && return 0
  done
  return 1
}

pool_registry_survivors() {
  local token=$1 taskdir=$2 pid f
  [[ -d $taskdir/registry ]] || return 0
  for f in "$taskdir"/registry/*.pid; do
    [[ -f $f ]] || continue
    [[ ${f##*/} == root.pid ]] && continue
    pid=$(awk 'NR==1 {print $1}' "$f")
    [[ -n $pid ]] || continue
    pool_pid_owned "$pid" "$token" "$taskdir" && echo "$pid"
  done | sort -un
}

pool_token_survivors() {
  local prefix=$1 f pid entry found
  [[ -d /proc ]] || return 0
  for f in /proc/[0-9]*/environ; do
    [[ -r $f ]] || continue
    pid=${f#/proc/}
    pid=${pid%/environ}
    [[ $pid == "$POOL_SELF_PID" ]] && continue
    found=0
    while IFS= read -r entry; do
      case $entry in
        "CI_POOL_TASK_TOKEN=$prefix"*) found=1; break ;;
      esac
    done < <(tr '\0' '\n' <"$f" 2>/dev/null)
    ((found)) && echo "$pid"
  done | sort -un
}

pool_token_owned() {
  local prefix=$1 pid=$2 tok
  tok=$(pool_pid_token "$pid" || true)
  case $tok in "$prefix"*) return 0 ;; esac
  return 1
}

pool_owned() {
  local mode=$1 token=$2 taskdir=$3 pid=$4
  if [[ $mode == task ]]; then
    pool_pid_owned "$pid" "$token" "$taskdir"
  else
    pool_token_owned "$token" "$pid"
  fi
}

# Kill verified PIDs, then prove none remain. mode=task|token.
pool_kill_owned() {
  local mode=$1 token=$2 taskdir=$3 pids=$4 pid i alive
  [[ -n $pids ]] || return 0
  for pid in $pids; do
    pool_owned "$mode" "$token" "$taskdir" "$pid" && kill -TERM "$pid" 2>/dev/null || true
  done
  for ((i = 0; i < 20; i++)); do
    alive=0
    for pid in $pids; do
      pool_owned "$mode" "$token" "$taskdir" "$pid" && pool_pid_alive "$pid" && alive=1
    done
    ((alive)) || break
    sleep 0.1
  done
  for pid in $pids; do
    pool_owned "$mode" "$token" "$taskdir" "$pid" && pool_pid_alive "$pid" &&
      kill -KILL "$pid" 2>/dev/null || true
  done
  for ((i = 0; i < 20; i++)); do
    alive=0
    for pid in $pids; do
      pool_owned "$mode" "$token" "$taskdir" "$pid" && pool_pid_alive "$pid" && alive=1
    done
    ((alive)) || break
    sleep 0.1
  done
  for pid in $pids; do
    pool_owned "$mode" "$token" "$taskdir" "$pid" && pool_pid_alive "$pid" && return 1
  done
  return 0
}

# Per-task audit: task-owned PID registry only (cheap). The expensive token
# sweep runs once for the whole pool in pool_audit_pool.
pool_audit_task() {
  local id=$1 token=$2 taskdir=$3 log=$4 pids i
  for ((i = 0; i < 5; i++)); do
    pids=$(pool_registry_survivors "$token" "$taskdir")
    [[ -z $pids ]] && return 0
    sleep 0.2
  done
  pids=$(pool_registry_survivors "$token" "$taskdir")
  [[ -z $pids ]] && return 0
  printf 'FAIL: surviving processes after task: %s\n' "$(printf '%s ' $pids)" >>"$log"
  if ! pool_kill_owned task "$token" "$taskdir" "$pids"; then
    printf 'FAIL: survivors still alive after TERM/KILL: %s\n' "$(printf '%s ' $pids)" >>"$log"
  fi
  return 1
}

# Final pool-wide detached audit. Covers processes that cleared REMUDA_*.
pool_audit_pool() {
  local pids
  pids=$(pool_token_survivors "$POOL_TOKEN_PREFIX")
  [[ -z $pids ]] && return 0
  echo "pool: detached survivors carrying this run's token: $(printf '%s ' $pids)" >&2
  if ! pool_kill_owned token "$POOL_TOKEN_PREFIX" "" "$pids"; then
    echo "FAIL: detached survivors remain after TERM/KILL: $(printf '%s ' $pids)" >&2
    POOL_SURVIVOR_FAIL=1
    return 1
  fi
  pids=$(pool_token_survivors "$POOL_TOKEN_PREFIX")
  [[ -z $pids ]] && return 0
  echo "FAIL: detached survivors remain: $(printf '%s ' $pids)" >&2
  POOL_SURVIVOR_FAIL=1
  return 1
}

pool_slot_set() {
  local s=$1 pid=$2 id=$3 status=$4 log=$5 taskdir=$6 token=$7 pgid=$8
  POOL_SLOT_PID[s]=$pid
  POOL_SLOT_ID[s]=$id
  POOL_SLOT_STATUS[s]=$status
  POOL_SLOT_LOG[s]=$log
  POOL_SLOT_START[s]=$(pool_now_us)
  POOL_SLOT_PGID[s]=$pgid
  POOL_SLOT_TASK[s]=$taskdir
  POOL_SLOT_TOKEN[s]=$token
  POOL_SLOT_REAPED[s]=0
}

pool_launch() {
  local s=$1 id=$2 kind=$3 arg=$4
  local safe taskdir status log token pid i rpid rpgid rsid
  local -a cmd=()
  safe=$(pool_safe_id "$id")
  taskdir="$POOL_TASKDIR/$safe"
  status="$POOL_LOGDIR/$safe.status"
  log="$POOL_LOGDIR/$safe.log"
  token="${POOL_TOKEN_PREFIX}${safe}"
  rm -rf "$taskdir"
  mkdir -p "$taskdir" || {
    echo "pool: cannot create task dir for $id" >&2
    POOL_FAILED+=("$id")
    return 1
  }
  case $kind in
    lua) cmd=(luajit "tests/$arg") ;;
    shell) cmd=(bash "tests/$arg") ;;
    embedded) cmd=(bash "tests/lua_tests.sh" "tests/lua/$arg") ;;
    embedded-nochild) cmd=(env REMUDA_LUA_NO_CHILD=1 bash "tests/lua_tests.sh" "tests/lua/$arg") ;;
    direct-lua) cmd=(luajit "$arg") ;;
    cmd) cmd=(bash -c "$arg") ;;
    *)
      echo "pool: unknown task kind '$kind' for $id" >&2
      POOL_FAILED+=("$id")
      return 1
      ;;
  esac
  # The opt-in live Codex test is the only task that needs the real login; the
  # coordination-config fixture requires no Codex layer, so CODEX_HOME is not
  # exported to every task.
  if [[ $id == shell/codex_mcp_mail.sh && -n ${POOL_ORIGINAL_CODEX_HOME:-} ]]; then
    cmd=(env "CODEX_HOME=$POOL_ORIGINAL_CODEX_HOME" "${cmd[@]}")
  fi

  # set +m in pool_run keeps this job in the pool's group so setsid succeeds.
  # If setsid/exec fails, perl dies before the task can run in our group.
  perl -MPOSIX -e '
    my $pid = $$;
    if (getpgrp(0) != $pid) {
      if (POSIX::setsid() < 0) {
        die "setsid failed: $!\n" if getpgrp(0) != $pid;
      }
    }
    exec @ARGV or die "exec failed: $!\n";
  ' bash "$POOL_WRAPPER" "$id" "$status" "$log" "$taskdir" "$token" -- "${cmd[@]}" \
    >"$log" 2>&1 &
  pid=$!

  for ((i = 0; i < 300; i++)); do
    [[ -f "$taskdir/registry/root.pid" || -f "$status" ]] && break
    pool_pid_alive "$pid" || break
    sleep 0.01
  done

  if [[ ! -f "$taskdir/registry/root.pid" ]]; then
    [[ -f "$status" ]] || printf '98\t%s\t%s\t\t\t%s\t%s\n' "$(pool_now_us)" "$(pool_now_us)" "" \
      "setsid/exec failed before ownership registration" >"$status"
    pool_slot_set "$s" "$pid" "$id" "$status" "$log" "$taskdir" "$token" ""
    return 0
  fi
  IFS=$'\t' read -r rpid rpgid rsid <"$taskdir/registry/root.pid"
  if [[ $rpid != "$pid" || -z $rpgid || $rpgid != "$pid" ]] ||
    [[ -n $rsid && $rsid != "$pid" ]] || [[ $rpgid == "$POOL_SELF_PGID" ]]; then
    printf '98\t%s\t%s\t\t\t%s\t%s\n' "$(pool_now_us)" "$(pool_now_us)" "" \
      "ownership proof failed: launcher=$pid registry=$rpid pgid=$rpgid sid=$rsid" >"$status"
    # Fail closed: direct PID only, never an unproven group.
    kill -TERM "$pid" 2>/dev/null || true
    pool_slot_set "$s" "$pid" "$id" "$status" "$log" "$taskdir" "$token" ""
    return 0
  fi
  pool_slot_set "$s" "$pid" "$id" "$status" "$log" "$taskdir" "$token" "$rpgid"
  return 0
}

# Collect one finished slot. cancelled=1 records a cancellation failure.
pool_collect() {
  local s=$1 cancelled=${2:-0}
  local pid=${POOL_SLOT_PID[s]} id=${POOL_SLOT_ID[s]}
  local status=${POOL_SLOT_STATUS[s]} log=${POOL_SLOT_LOG[s]}
  local taskdir=${POOL_SLOT_TASK[s]} token=${POOL_SLOT_TOKEN[s]}
  local rc start end user sys wall note elapsed_millis elapsed survivors=0
  if [[ ${POOL_SLOT_REAPED[s]:-0} == 1 ]]; then
    rc=${POOL_SLOT_WAIT_RC[s]:-137}
  else
    wait "$pid" 2>/dev/null
    rc=$?
    POOL_SLOT_REAPED[s]=1
    POOL_SLOT_WAIT_RC[s]=$rc
  fi
  start=${POOL_SLOT_START[s]}
  end=$(pool_now_us)
  user= sys= wall= note=
  if [[ -f $status ]]; then
    IFS=$'\t' read -r rc start end user sys wall note <"$status"
  fi
  [[ $rc =~ ^[0-9]+$ ]] || rc=98
  ((cancelled)) && [[ $rc == 0 ]] && rc=143
  if [[ -z ${start:-} || -z ${end:-} ]] || ((end < start)); then
    start=${POOL_SLOT_START[s]}
    end=$(pool_now_us)
  fi
  [[ -n ${wall:-} ]] || wall=$(awk "BEGIN{printf \"%.2f\", ($end - $start)/1000000}")
  elapsed_millis=$(((end - start) / 1000))
  ((elapsed_millis < 0)) && elapsed_millis=0
  elapsed="$((elapsed_millis / 1000)).$(((elapsed_millis % 1000) / 100))"

  if ((!cancelled)); then
    pool_audit_task "$id" "$token" "$taskdir" "$log" || survivors=1
    [[ $survivors == 1 && $rc == 0 ]] && rc=1
  fi

  POOL_RESULTS+=("$id"$'\t'"$rc"$'\t'"$wall"$'\t'"${user:--}"$'\t'"${sys:--}")
  if ((cancelled)); then
    echo "FAIL $id ${wall}s (cancelled)"
    POOL_FAILED+=("$id")
  elif [[ $rc == 0 ]]; then
    echo "PASS $id ${wall}s (user ${user:--}s sys ${sys:--}s)"
    [[ -f $log ]] && grep -E '^(SKIP|NOTE|codexless subset)' "$log" 2>/dev/null | sed 's/^/  /' || true
  else
    echo "FAIL $id ${wall}s (user ${user:--}s sys ${sys:--}s)"
    echo "--- $id (log: $log)"
    tail -n 40 "$log" 2>/dev/null | sed 's/^/  /' || true
    POOL_FAILED+=("$id")
  fi

  POOL_SLOT_PID[s]= POOL_SLOT_ID[s]= POOL_SLOT_STATUS[s]= POOL_SLOT_LOG[s]=
  POOL_SLOT_START[s]= POOL_SLOT_PGID[s]= POOL_SLOT_TASK[s]= POOL_SLOT_TOKEN[s]=
}

pool_cancel() {
  local jobs=$1 grace=${SHELL_TESTS_CANCEL_GRACE:-15}
  local s pid pgid deadline alive i pids wrc
  POOL_CANCELLED=1
  [[ $grace =~ ^[0-9]+$ ]] || grace=15
  echo "pool: cancellation requested; signaling owned task groups" >&2

  for ((s = 0; s < jobs; s++)); do
    pid=${POOL_SLOT_PID[s]:-}
    [[ -n $pid ]] || continue
    pgid=${POOL_SLOT_PGID[s]:-}
    if pool_group_owned "$pid" "$pgid"; then
      kill -TERM -- "-$pgid" 2>/dev/null || true
    elif pool_pid_alive "$pid"; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  deadline=$((SECONDS + grace))
  while ((SECONDS < deadline)); do
    alive=0
    for ((s = 0; s < jobs; s++)); do
      pid=${POOL_SLOT_PID[s]:-}
      [[ -n $pid ]] || continue
      if [[ ${POOL_SLOT_REAPED[s]:-0} != 1 && -f ${POOL_SLOT_STATUS[s]} ]]; then
        wait "$pid" 2>/dev/null
        wrc=$?
        POOL_SLOT_REAPED[s]=1
        POOL_SLOT_WAIT_RC[s]=$wrc
        continue
      fi
      pool_pid_alive "$pid" && alive=1
    done
    ((alive)) || break
    sleep 0.2
  done

  for ((s = 0; s < jobs; s++)); do
    pid=${POOL_SLOT_PID[s]:-}
    [[ -n $pid ]] || continue
    pool_pid_alive "$pid" || continue
    pgid=${POOL_SLOT_PGID[s]:-}
    if pool_group_owned "$pid" "$pgid"; then
      kill -KILL -- "-$pgid" 2>/dev/null || true
    else
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done

  for ((s = 0; s < jobs; s++)); do
    pid=${POOL_SLOT_PID[s]:-}
    [[ -n $pid ]] || continue
    pids=$(pool_registry_survivors "${POOL_SLOT_TOKEN[s]}" "${POOL_SLOT_TASK[s]}")
    [[ -n $pids ]] || continue
    echo "pool: cancelling detached survivors for ${POOL_SLOT_ID[s]}: $(printf '%s ' $pids)" >&2
    if ! pool_kill_owned task "${POOL_SLOT_TOKEN[s]}" "${POOL_SLOT_TASK[s]}" "$pids"; then
      echo "FAIL: survivors for ${POOL_SLOT_ID[s]} remain: $(printf '%s ' $pids)" >&2
      POOL_SURVIVOR_FAIL=1
    fi
  done
  pool_audit_pool || true

  for ((s = 0; s < jobs; s++)); do
    [[ -n ${POOL_SLOT_PID[s]:-} ]] || continue
    pool_collect "$s" 1
  done
  return 130
}

pool_summary() {
  local wall_ms f r total_user total_sys
  wall_ms=$((($(pool_now_us) - POOL_WALL_START) / 1000))
  f="$POOL_LOGDIR/summary.tsv"
  printf 'id\trc\twall_s\tuser_s\tsys_s\n' >"$f"
  for r in "${POOL_RESULTS[@]}"; do printf '%s\n' "$r" >>"$f"; done
  total_user=$(awk -F'\t' 'NR>1 && $4 != "-" {s+=$4} END{printf "%.2f", s+0}' "$f")
  total_sys=$(awk -F'\t' 'NR>1 && $5 != "-" {s+=$5} END{printf "%.2f", s+0}' "$f")
  echo "pool: ${#POOL_RESULTS[@]} tasks, ${#POOL_FAILED[@]} failed, wall ${wall_ms}ms"
  echo "pool: task rusage user ${total_user}s sys ${total_sys}s (detached processes excluded)"
  if ((${#POOL_RESULTS[@]} > 0)); then
    echo "pool: slowest tasks:"
    {
      head -1 "$f"
      tail -n +2 "$f" | sort -t$'\t' -k3,3nr | head -10
    } | sed 's/^/  /'
  fi
}

# pool_run MANIFEST JOBS LOGDIR TASKDIR WORKDIR [WRAPPER]
pool_run() {
  local manifest=$1 jobs=$2 logdir=$3 taskdir_root=$4 workdir=$5
  local wrapper=${6:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pool_task.sh}
  local manifest_sorted=$manifest
  local n next running s id dur kind arg pid
  local -a m_id=() m_dur=() m_kind=() m_arg=()

  POOL_SELF_PID=$$
  POOL_SELF_PGID=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')
  POOL_CANCELLED=0
  POOL_FAILED=()
  POOL_RESULTS=()
  POOL_SURVIVOR_FAIL=0
  POOL_WALL_START=$(pool_now_us)
  POOL_TOKEN_PREFIX="ci-pool-$$-${POOL_WALL_START}-${RANDOM}-"
  POOL_LOGDIR=$logdir
  POOL_TASKDIR=$taskdir_root
  POOL_WORKDIR=$workdir
  POOL_WRAPPER=$wrapper
  # The pool boundary owns sanitization, so a direct pool_run caller cannot
  # leak a live session into a task either.
  pool_sanitize_env

  mkdir -p "$POOL_LOGDIR" "$POOL_TASKDIR" || return 2
  cd "$POOL_WORKDIR" || return 2
  set +m
  ((${POOL_CANCEL_REQUESTED:-0})) && { echo "pool: cancelled before start" >&2; return 130; }

  if ((jobs > 1)); then
    manifest_sorted=$manifest.sorted
    LC_ALL=C sort -s -t$'\t' -k2,2nr -k1,1 "$manifest" >"$manifest_sorted" || return 2
  fi
  while IFS=$'\t' read -r id dur kind arg || [[ -n ${id:-} ]]; do
    [[ -n $id ]] || continue
    m_id+=("$id"); m_dur+=("$dur"); m_kind+=("$kind"); m_arg+=("$arg")
  done <"$manifest_sorted"

  n=${#m_id[@]}
  ((n > 0)) || { echo "pool: empty manifest" >&2; return 2; }
  ((jobs > n)) && jobs=$n
  ((jobs >= 1)) || jobs=1
  for ((s = 0; s < jobs; s++)); do
    POOL_SLOT_PID[s]= POOL_SLOT_ID[s]= POOL_SLOT_STATUS[s]= POOL_SLOT_LOG[s]=
    POOL_SLOT_START[s]= POOL_SLOT_PGID[s]= POOL_SLOT_TASK[s]= POOL_SLOT_TOKEN[s]=
    POOL_SLOT_REAPED[s]=0 POOL_SLOT_WAIT_RC[s]=0
  done

  echo "pool: $n tasks, $jobs workers"
  next=0 running=0
  while ((next < n || running > 0)); do
    if ((${POOL_CANCEL_REQUESTED:-0})); then
      pool_cancel "$jobs"
      pool_summary
      return 130
    fi
    for ((s = 0; s < jobs; s++)); do
      pid=${POOL_SLOT_PID[s]:-}
      if [[ -n $pid && -f ${POOL_SLOT_STATUS[s]} ]] || { [[ -n $pid ]] && ! pool_pid_alive "$pid"; }; then
        pool_collect "$s" 0
        running=$((running - 1))
      fi
      if [[ -z ${POOL_SLOT_PID[s]:-} ]] && ((next < n)); then
        pool_launch "$s" "${m_id[next]}" "${m_kind[next]}" "${m_arg[next]}" && running=$((running + 1))
        next=$((next + 1))
      fi
    done
    sleep 0.05
  done

  pool_audit_pool || true
  pool_summary
  ((POOL_SURVIVOR_FAIL)) && ((${#POOL_FAILED[@]} == 0)) && POOL_FAILED+=("detached-survivors")
  if ((${#POOL_FAILED[@]})) || ((POOL_SURVIVOR_FAIL)); then
    echo "shell tests FAILED: ${POOL_FAILED[*]}" >&2
    return 1
  fi
  return 0
}
