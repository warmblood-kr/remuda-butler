#!/usr/bin/env bash
set -euo pipefail

harness_prepare() {
  local original_runtime
  original_runtime=${REMUDA_RUNTIME_DIR:-}
  REMUDA_BIN=${REMUDA_BIN:-$(command -v remuda || true)}
  [[ -n "$REMUDA_BIN" ]] || { echo "FAIL: REMUDA_BIN is not set and remuda was not found" >&2; return 1; }
  if [[ "$REMUDA_BIN" != */* ]]; then REMUDA_BIN=$(command -v "$REMUDA_BIN"); fi
  H_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
  H_SCRATCH=$(mktemp -d /tmp/remuda-lua.XXXXXX)
  H_SCRATCH=$(cd "$H_SCRATCH" && pwd -P)
  H_SERVER="h$$"
  H_CHILD_SERVER="${H_SERVER}c"
  H_DEFAULT_RUNTIME=$original_runtime
  if [[ -z "$H_DEFAULT_RUNTIME" ]]; then H_DEFAULT_RUNTIME="/tmp/remuda-${USER:-$(id -un)}"; fi
  H_RESULT="$H_SCRATCH/result"
  export REMUDA_BIN REMUDA_LUA_REPO="$H_REPO" REMUDA_LUA_SERVER="$H_SERVER"
  export REMUDA_LUA_CHILD_SERVER="$H_CHILD_SERVER" REMUDA_LUA_RESULT="$H_RESULT"
  export REMUDA_LUA_SCRATCH="$H_SCRATCH"
  export REMUDA_LUA_DEFAULT_RUNTIME="$H_DEFAULT_RUNTIME"
  export HOME="$H_SCRATCH/home" XDG_CONFIG_HOME="$H_SCRATCH/config"
  export XDG_DATA_HOME="$H_SCRATCH/data" XDG_RUNTIME_DIR="$H_SCRATCH/runtime"
  export REMUDA_RUNTIME_DIR="$H_SCRATCH/run" REMUDA_NO_UPDATE_CHECK=1
  unset REMUDA_SERVER REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG
  local name
  for name in ${!REMUDA_BUTLER_@}; do unset "$name"; done
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR" "$REMUDA_RUNTIME_DIR"
  chmod 700 "$REMUDA_RUNTIME_DIR"
  local socket
  socket="$REMUDA_RUNTIME_DIR/remuda/$H_SERVER.sock"
  [[ "$socket" != "$H_DEFAULT_RUNTIME/remuda/$H_SERVER.sock" ]] || {
    echo "FAIL: refusing the default Remuda socket: $socket" >&2
    return 1
  }
  [[ "$socket" == "$H_SCRATCH/"* ]] || {
    echo "FAIL: harness socket escaped scratch: $socket" >&2
    return 1
  }
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'harness_cleanup $?' EXIT
}

harness_run() {
  local test_file=${1:-tests/lua/spike_test.lua}
  [[ "$test_file" =~ ^tests/lua/[A-Za-z0-9_./-]+_test\.lua$ && -f "$H_REPO/$test_file" ]] || {
    echo "FAIL: test must be a file under tests/lua: $test_file" >&2
    return 2
  }
  export REMUDA_LUA_TEST="$H_REPO/$test_file"
  cd "$H_REPO"
  local command_status=0 attempt status
  "$REMUDA_BIN" -s "$REMUDA_LUA_SERVER" lua tests/lib/harness.lua || command_status=$?
  if (( command_status != 0 )) && [[ ! -f "$H_RESULT" ]]; then
    echo "FAIL: controller launch failed (exit $command_status)" >&2
    return "$command_status"
  fi
  for attempt in $(seq 1 600); do
    [[ -s "$H_RESULT" ]] && break
    sleep 0.05
  done
  if [[ ! -s "$H_RESULT" ]]; then
    echo "FAIL: controller did not write a result within 30 seconds" >&2
    return 1
  fi
  cat "$H_RESULT"
  IFS= read -r status < "$H_RESULT"
  [[ "$status" == "PASS" ]]
}

harness_cleanup() {
  local status=${1:-0}
  [[ -n ${H_SCRATCH:-} && -d "$H_SCRATCH" ]] || return "$status"
  [[ ${REMUDA_RUNTIME_DIR:-} == "$H_SCRATCH/run" ]] || {
    echo "refusing cleanup outside the harness runtime" >&2
    return 1
  }
  # The controller stops itself and its child; this covers a controller that died first.
  "$REMUDA_BIN" -s "$H_CHILD_SERVER" stop -f >/dev/null 2>&1 || true
  "$REMUDA_BIN" -s "$H_SERVER" stop -f >/dev/null 2>&1 || true
  rm -rf "$H_SCRATCH"
  if [[ -e "$H_SCRATCH" ]]; then
    echo "harness: killed pids: 0; removed dirs: 0; left: 1" >&2
    return 1
  fi
  echo "harness: killed pids: 0; removed dirs: 1; left: 0"
  return "$status"
}
