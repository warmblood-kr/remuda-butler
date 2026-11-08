#!/usr/bin/env bash
# Failure fixture for tests/lib/isolated_env.sh cleanup.
#
# A daemon that hangs before bind has no socket. Cleanup must not delete the
# scratch while the tracked process is alive: it must wait bounded, keep the
# tree and exit non-zero. Once the process is gone, cleanup may remove it.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
source "$REPO/tests/lib/isolated_env.sh"

fail=0
note() { echo "FAIL: $*" >&2; fail=1; }

T=$(mktemp -d /tmp/ienv.XXXXXX) || exit 2
T=$(cd "$T" && pwd -P)
mkdir -m 700 "$T/runtime" || exit 2
export REMUDA_RUNTIME_DIR="$T/runtime"
S=bmr
REMUDA_BIN=/usr/bin/false
ISOLATED_DAEMON_PID=

cleanup_all() {
  if [[ -n ${ISOLATED_DAEMON_PID:-} ]] && kill -0 "$ISOLATED_DAEMON_PID" 2>/dev/null; then
    kill "$ISOLATED_DAEMON_PID" 2>/dev/null || true
    wait "$ISOLATED_DAEMON_PID" 2>/dev/null || true
  fi
  rm -rf -- "$T"
}
trap cleanup_all EXIT

# Delayed/no-bind process: alive, no socket in the runtime.
sleep 30 &
ISOLATED_DAEMON_PID=$!

if isolated_env_cleanup 0; then
  note "cleanup claimed success while the tracked process was alive"
fi
[[ -d "$T" ]] || note "cleanup removed the scratch before proving the process exited"

kill "$ISOLATED_DAEMON_PID" 2>/dev/null || true
wait "$ISOLATED_DAEMON_PID" 2>/dev/null || true

if ! isolated_env_cleanup 0; then
  note "cleanup failed after the tracked process exited"
fi
[[ ! -e "$T" ]] || note "cleanup kept the scratch after the tracked process exited"

if (( fail )); then exit 1; fi
echo "ok - private-envelope cleanup preserves a late/no-bind daemon"
