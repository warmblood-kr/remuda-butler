#!/usr/bin/env bash
# Failure fixtures for tests/lib/isolated_env.sh cleanup.
#
# A daemon that hangs before bind has no socket. Cleanup must not delete the
# scratch while the tracked process is alive: it must wait bounded, keep the
# tree and exit non-zero. It must also treat a ps failure (EPERM in a sandbox)
# as unknown, never as "gone". Once the process is verifiably gone, cleanup
# may remove the tree.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
source "$REPO/tests/lib/isolated_env.sh"

fail=0
note() { echo "FAIL: $*" >&2; fail=1; }
PIDS=()
SCRATCHES=()

cleanup_all() {
  local pid dir
  for pid in "${PIDS[@]:-}"; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  for dir in "${SCRATCHES[@]:-}"; do
    [[ -n "$dir" ]] && rm -rf -- "$dir"
  done
}
trap cleanup_all EXIT

make_scratch() {
  local dir
  dir=$(mktemp -d "/tmp/ienv.XXXXXX") || exit 2
  dir=$(cd "$dir" && pwd -P)
  mkdir -m 700 "$dir/runtime" || exit 2
  SCRATCHES+=("$dir")
  printf '%s\n' "$dir"
}

# Delayed/no-bind process: alive, no socket in the runtime.
T=$(make_scratch)
export REMUDA_RUNTIME_DIR="$T/runtime"
S=bmr
REMUDA_BIN=/usr/bin/false
sleep 30 &
ISOLATED_DAEMON_PID=$!
PIDS+=("$ISOLATED_DAEMON_PID")

if isolated_env_cleanup 0; then
  note "cleanup claimed success while the tracked process was alive"
fi
[[ -d "$T" ]] || note "cleanup removed the scratch before proving the process exited"

kill "$ISOLATED_DAEMON_PID" 2>/dev/null || true
wait "$ISOLATED_DAEMON_PID" 2>/dev/null || true
PIDS=()

if ! isolated_env_cleanup 0; then
  note "cleanup failed after the tracked process exited"
fi
[[ ! -e "$T" ]] || note "cleanup kept the scratch after the tracked process exited"

# ps failure while the process is alive: kill -0 proves "not gone", and the
# unusable ps must not turn that into deletion.
FAKEBIN=$(mktemp -d "/tmp/ienv-psbin.XXXXXX") || exit 2
SCRATCHES+=("$FAKEBIN")
printf '%s\n' '#!/bin/sh' 'echo "ps: Operation not permitted" >&2' 'exit 1' >"$FAKEBIN/ps"
chmod +x "$FAKEBIN/ps"

T=$(make_scratch)
export REMUDA_RUNTIME_DIR="$T/runtime"
sleep 30 &
ISOLATED_DAEMON_PID=$!
PIDS+=("$ISOLATED_DAEMON_PID")
if PATH="$FAKEBIN:$PATH" isolated_env_cleanup 0; then
  note "cleanup claimed success while ps could not inspect a live process"
fi
[[ -d "$T" ]] || note "cleanup deleted the scratch when ps was unusable"

kill "$ISOLATED_DAEMON_PID" 2>/dev/null || true
wait "$ISOLATED_DAEMON_PID" 2>/dev/null || true
PIDS=()
if ! isolated_env_cleanup 0; then
  note "cleanup failed after the ps-denied process exited"
fi
[[ ! -e "$T" ]] || note "cleanup kept the scratch after the ps-denied process exited"

# An unknown kill failure is not proof of exit; only "No such process" is.
(
  function kill() { echo "kill: unknown failure" >&2; return 1; }
  isolated_env_pid_alive $$
) || note "an unknown kill failure was treated as gone"

# A reaped, non-child PID positively says "No such process".
true &
gone=$!
wait "$gone" 2>/dev/null || true
if isolated_env_pid_alive "$gone"; then
  note "a reaped PID was treated as alive"
fi

if (( fail )); then exit 1; fi
echo "ok - private-envelope cleanup preserves late/no-bind, ps-denied and unknown-kill daemons"
