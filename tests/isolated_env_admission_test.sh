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
cleanup() { rm -f "$SENTINEL"; }
trap cleanup EXIT

before=$(find "$PARENT" -maxdepth 1 -type d -name 'zzz.*' 2>/dev/null | wc -l | tr -d ' ')
(
  set -euo pipefail
  source "$REPO/tests/lib/isolated_env.sh"
  REPO=$REPO
  REMUDA_BIN=/usr/bin/false
  REMUDA_RUNTIME_DIR=$PARENT
  isolated_env_prepare zzz zzz
) >/tmp/ienv-admission.out 2>&1
status=$?
after=$(find "$PARENT" -maxdepth 1 -type d -name 'zzz.*' 2>/dev/null | wc -l | tr -d ' ')
(( status != 0 )) || note "alias refusal returned success"
(( after == before )) || note "alias refusal leaked a scratch directory"
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
