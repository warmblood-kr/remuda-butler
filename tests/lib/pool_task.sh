#!/usr/bin/env bash
# One pool task. It is exec'd after the pool's perl launcher has created a
# session/process group, so $$ must already be the group leader. It verifies
# that ownership itself and fails closed (exit 98) rather than run a task in
# the parent's group.
set -uo pipefail

id=$1
status=$2
log=$3
taskdir=$4
token=$5
shift 5
[[ ${1:-} == -- ]] && shift

export REMUDA_CI_TASK_TOKEN="$token"
export REMUDA_CI_TASK_DIR="$taskdir"
export REMUDA_CI_TASK_REGISTRY="$taskdir/registry"
# A non-REMUDA spelling survives tests that intentionally clear REMUDA_* (the
# live Codex test unsets every REMUDA_* except REMUDA_BIN). This is the
# authoritative token for detached-process ownership.
export CI_POOL_TASK_TOKEN="$token"
export CI_POOL_TASK_DIR="$taskdir"

mkdir -p "$taskdir/home" "$taskdir/config" "$taskdir/data" "$taskdir/cache" \
  "$taskdir/state" "$taskdir/xdg-runtime" "$taskdir/remuda-runtime" \
  "$taskdir/tmp" "$taskdir/registry" || exit 98

# Private roots for every task: no shared ~/.cache, ~/.config, ~/.local/state,
# runtime socket directory or tmp. Tests may override these, but they start
# from an isolated baseline. CODEX_HOME is captured by the pool before HOME
# moves, so a deliberate native login path survives.
export HOME="$taskdir/home"
export XDG_CONFIG_HOME="$taskdir/config"
export XDG_DATA_HOME="$taskdir/data"
export XDG_CACHE_HOME="$taskdir/cache"
export XDG_STATE_HOME="$taskdir/state"
export XDG_RUNTIME_DIR="$taskdir/xdg-runtime"
export REMUDA_RUNTIME_DIR="$taskdir/remuda-runtime"
export TMPDIR="$taskdir/tmp"

now_us() {
  if [[ -n ${EPOCHREALTIME:-} ]]; then
    printf '%s' "${EPOCHREALTIME/./}"
  else
    perl -MTime::HiRes=time -e 'printf "%d", time * 1000000'
  fi
}

start=$(now_us)
user= sys= wall= note=
time_file="$taskdir/time"

write_status() {
  local rc=$1 msg=${2:-} tmp="$status.tmp.$$"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$rc" "$start" "$(now_us)" "${user:--}" "${sys:--}" "${wall:--}" "$msg" >"$tmp" &&
    mv "$tmp" "$status"
}

cancelled=
trap 'cancelled=1' TERM INT

# Fail closed: the pool must only signal a group this process really owns.
pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')
if [[ -z $pgid || $pgid != "$$" ]]; then
  write_status 98 "not a process-group leader: pid=$$ pgid=${pgid:-?}"
  exit 98
fi
sid=
if [[ -r /proc/$$/stat ]]; then
  sid=$(awk '{print $6}' "/proc/$$/stat")
  if [[ $sid != "$$" ]]; then
    write_status 98 "not a session leader: pid=$$ sid=${sid:-?}"
    exit 98
  fi
fi

printf '%s\t%s\t%s\n' "$$" "$pgid" "${sid:-}" >"$taskdir/registry/root.pid.tmp.$$" &&
  mv "$taskdir/registry/root.pid.tmp.$$" "$taskdir/registry/root.pid" || {
  write_status 98 "cannot write ownership registry"
  exit 98
}

# /usr/bin/time reports the task process and children it reaps. A detached
# process is not included; the pool calls this observed task rusage, never
# complete CPU. -p works on GNU and BSD time; the file keeps task stderr clean.
if [[ -x /usr/bin/time ]]; then
  /usr/bin/time -p -o "$time_file" "$@"
  rc=$?
  if [[ -r $time_file ]]; then
    while read -r key value; do
      case $key in
        real) wall=$value ;;
        user) user=$value ;;
        sys) sys=$value ;;
      esac
    done <"$time_file"
  fi
else
  "$@"
  rc=$?
fi

if [[ -n $cancelled ]]; then rc=143; fi
[[ -n $wall ]] || wall=$(awk "BEGIN{printf \"%.2f\", ($(now_us) - $start)/1000000}")
write_status "$rc" "${cancelled:+cancelled}"
exit "$rc"
