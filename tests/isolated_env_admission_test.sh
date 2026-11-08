#!/usr/bin/env bash
# Admission/refusal and scratch-retention fixture for tests/lib/isolated_env.sh.
# Pure shell: no daemon, no scheduler, no session.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
source "$REPO/tests/lib/isolated_env.sh"

fail=0
note() { echo "FAIL: $*" >&2; fail=1; }
PARENT=$(cd /tmp && pwd -P)
SENTINEL=$(mktemp /tmp/ienv-sentinel.XXXXXX) || exit 2
LOG=$(mktemp /tmp/ienv-admission-log.XXXXXX) || exit 2
cleanup() { rm -f "$SENTINEL" "${LOG:-}"; }
trap cleanup EXIT

(
  set -euo pipefail
  source "$REPO/tests/lib/isolated_env.sh"
  REPO=$REPO
  REMUDA_BIN=/usr/bin/false
  REMUDA_RUNTIME_DIR=$PARENT
  isolated_env_prepare zzz zzz
) >"$LOG" 2>&1
status=$?
# The refusal names the scratch it created. Assert that exact tree is gone,
# rather than counting a shared /tmp prefix (another run may use it too).
leaked=$(sed -n 's/^private-env: FAIL: scratch aliases inherited REMUDA_RUNTIME_DIR: //p' "$LOG" | tail -1)
(( status != 0 )) || note "alias refusal returned success"
[[ -n "$leaked" ]] || note "alias refusal did not name the created scratch"
[[ ! -e "$leaked" ]] || note "alias refusal leaked $leaked"
[[ -f "$SENTINEL" ]] || note "cleanup removed a foreign sentinel"

d=$(mktemp -d /tmp/ienv-mode.XXXXXX) || exit 2
chmod 755 "$d"
if ( source "$REPO/tests/lib/isolated_env.sh"; isolated_env_private_dir "$d" ); then
  note "mode-0755 directory was admitted"
fi
rm -rf -- "$d"

real=$(mktemp -d /tmp/ienv-real.XXXXXX) || exit 2
link="/tmp/ienv-link.$$"
ln -s "$real" "$link"
if ( source "$REPO/tests/lib/isolated_env.sh"; isolated_env_private_dir "$link" ); then
  note "symlinked directory was admitted"
fi
rm -f -- "$link"
rm -rf -- "$real"

scratch=$(
  set -euo pipefail
  source "$REPO/tests/lib/isolated_env.sh"
  REPO=$REPO
  REMUDA_BIN=/usr/bin/false
  isolated_env_prepare oktest oktest
  echo "$T"
  isolated_env_cleanup 0
)
if [[ -n "$scratch" && -e "$scratch" ]]; then
  note "successful admission cleanup kept $scratch"
fi
[[ -f "$SENTINEL" ]] || note "successful cleanup removed a foreign sentinel"

if (( fail )); then exit 1; fi
echo "ok - private-envelope admission refuses foreign paths and retains only owned scratch"
