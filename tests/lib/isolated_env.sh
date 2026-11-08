#!/usr/bin/env bash
# Shared private envelope for daemon-run suites.
#
# Accident prevention, not a security boundary. The disposable daemon is the
# isolation; this preflight makes an accidental run in an ordinary shell or
# against the default runtime fail before a daemon is created.
#
# The caller must set REPO and REMUDA_BIN, keep `set -euo pipefail`, and call
#   isolated_env_prepare PREFIX SERVER
# before creating the daemon. prepare installs its own trap first, so a
# mid-prepare failure cannot leak the scratch tree. Paths are canonical
# (pwd -P), owned by this user, mode 0700, and contain no symlinked component
# after mktemp.

isolated_env_fail() {
  echo "private-env: FAIL: $*" >&2
  return 1
}

isolated_env_private_dir() {
  local dir=$1
  [[ -d "$dir" && ! -L "$dir" && -O "$dir" ]] ||
    { isolated_env_fail "not an owned directory: $dir"; return 1; }
  [[ -n $(find "$dir" -maxdepth 0 -type d -perm 700 -user "$(id -un)" 2>/dev/null) ]] ||
    { isolated_env_fail "not mode 0700: $dir"; return 1; }
}

isolated_env_prepare() {
  local prefix=$1 server=$2
  local inherited_runtime default_runtime id name socket
  # Install the trap before mktemp: a mid-prepare failure must not leak the
  # scratch tree either.
  isolated_env_install_trap
  ISOLATED_DAEMON_PID=

  [[ -n ${REPO:-} ]] || { isolated_env_fail "REPO is not set"; return 1; }
  [[ "$prefix" =~ ^[a-z]+$ ]] ||
    { isolated_env_fail "prefix must be lowercase letters: $prefix"; return 1; }
  [[ "$server" =~ ^[A-Za-z0-9._-]{1,64}$ ]] ||
    { isolated_env_fail "server name is malformed: $server"; return 1; }

  inherited_runtime=${REMUDA_RUNTIME_DIR:-}
  default_runtime="/tmp/remuda-${USER:-$(id -un)}"

  S=$server
  T=$(mktemp -d "/tmp/${prefix}.XXXXXX") || return 1
  T=$(cd "$T" && pwd -P) || return 1
  isolated_env_private_dir "$T" || return 1

  [[ "$T" != "$default_runtime" && "$T" != "$default_runtime/"* ]] ||
    { isolated_env_fail "scratch aliases the default runtime: $T"; return 1; }
  if [[ -n "$inherited_runtime" ]]; then
    [[ "$T" != "$inherited_runtime" && "$T" != "$inherited_runtime/"* ]] ||
      { isolated_env_fail "scratch aliases inherited REMUDA_RUNTIME_DIR: $T"; return 1; }
  fi

  export HOME="$T/home"
  export XDG_CONFIG_HOME="$T/config"
  export XDG_DATA_HOME="$T/data"
  export XDG_RUNTIME_DIR="$T/xdg-runtime"
  export REMUDA_RUNTIME_DIR="$T/runtime"

  # Identity must come only from this disposable envelope. Scrub the child
  # environment before the daemon inherits it. The shell can enumerate the
  # prefix; the Lua guard checks the documented names (plus REMUDA_SERVER).
  unset REMUDA_SERVER REMUDA_SESSION_CAPABILITY
  for name in ${!REMUDA_BUTLER_@}; do unset "$name"; done

  for name in "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR" "$REMUDA_RUNTIME_DIR"; do
    mkdir -m 700 "$name" || return 1
    isolated_env_private_dir "$name" || return 1
  done

  id="${prefix}-$$-${RANDOM}"
  socket="$REMUDA_RUNTIME_DIR/remuda/$S.sock"
  [[ "$socket" == "$T/"* ]] ||
    { isolated_env_fail "socket escaped scratch: $socket"; return 1; }
  [[ "$socket" != "$default_runtime/remuda/$S.sock" ]] ||
    { isolated_env_fail "refusing the default runtime socket: $socket"; return 1; }

  export REMUDA_TEST_CONTEXT="isolated-v1:$id"
  export REMUDA_TEST_ENVELOPE="isolated-v1|$id|$T|$HOME|$XDG_CONFIG_HOME|$XDG_DATA_HOME|$REMUDA_RUNTIME_DIR|$socket"
  export REMUDA_LUA_REPO="$REPO"
  return 0
}

isolated_env_check_daemon() {
  local runtime=$REMUDA_RUNTIME_DIR
  local dir="$runtime/remuda"
  local socket="$dir/$S.sock"
  isolated_env_private_dir "$runtime" || return 1
  [[ -d "$dir" && ! -L "$dir" && -O "$dir" ]] ||
    { isolated_env_fail "daemon runtime dir is not owned and real: $dir"; return 1; }
  [[ -n $(find "$dir" -maxdepth 0 -type d -perm 700 -user "$(id -un)" 2>/dev/null) ]] ||
    { isolated_env_fail "daemon runtime dir is not mode 0700: $dir"; return 1; }
  [[ -S "$socket" && ! -L "$socket" && -O "$socket" ]] ||
    { isolated_env_fail "daemon socket is not an owned real socket: $socket"; return 1; }
  [[ -n $(find "$socket" -maxdepth 0 -type s -perm 600 -user "$(id -un)" 2>/dev/null) ]] ||
    { isolated_env_fail "daemon socket is not mode 0600: $socket"; return 1; }
  return 0
}

# True while PID is a live (non-zombie) process. ps also reports empty when it
# is gone, and Z* when it exited but has not been reaped yet.
isolated_env_pid_alive() {
  local pid=$1 state
  [[ -n "$pid" ]] || return 1
  state=$(ps -o stat= -p "$pid" 2>/dev/null) || return 1
  [[ -n "$state" && "$state" != Z* ]]
}

isolated_env_cleanup() {
  local status=${1:-0}
  [[ -n ${T:-} && -e ${T:-} ]] || return "$status"
  if [[ -L "$T" || ! -O "$T" || ${REMUDA_RUNTIME_DIR:-} != "$T/runtime" ]]; then
    echo "private-env: refusing cleanup outside the owned scratch: ${T:-}" >&2
    return 1
  fi
  local socket="$T/runtime/remuda/${S:-}.sock" pid=${ISOLATED_DAEMON_PID:-}
  local alive=0 up=0 i
  if [[ -n "$pid" ]]; then
    if isolated_env_pid_alive "$pid"; then
      alive=1
    else
      wait "$pid" 2>/dev/null || true
    fi
  fi
  if (( alive )); then
    if [[ -S "$socket" && -n ${REMUDA_BIN:-} && -n ${S:-} ]]; then
      "$REMUDA_BIN" -s "$S" stop -f >/dev/null 2>&1 || true
    fi
    # A daemon that failed before bind is still our process: wait bounded and
    # keep the scratch if it cannot be proven exited.
    for i in $(seq 1 30); do
      if ! isolated_env_pid_alive "$pid"; then
        alive=0
        wait "$pid" 2>/dev/null || true
        break
      fi
      sleep 0.1
    done
  fi
  # An untracked daemon may still answer on the socket. Socket absence alone is
  # not proof: a late bind can appear after this check.
  if [[ -S "$socket" && -n ${REMUDA_BIN:-} && -n ${S:-} ]]; then
    if "$REMUDA_BIN" -s "$S" ls >/dev/null 2>&1; then up=1; fi
  fi
  if (( alive || up )); then
    echo "private-env: cannot prove the private daemon is down; keeping scratch $T" >&2
    return 1
  fi
  rm -rf -- "$T"
  return "$status"
}

isolated_env_install_trap() {
  trap 'isolated_env_cleanup $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
