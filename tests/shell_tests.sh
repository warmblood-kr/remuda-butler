#!/usr/bin/env bash
# Run every standalone test against one pinned core: each tests/*.sh (each
# makes its own private daemon and scratch dirs) and the luajit unit tests.
#
#   tests/shell_tests.sh                     # clone/build/cache core at CORE_REF
#   REMUDA_BIN=~/.local/bin/remuda tests/shell_tests.sh
#   SHELL_TESTS_JOBS=1 tests/shell_tests.sh  # serial local mode
#   tests/shell_tests.sh --list              # coverage manifest, no execution
#
# Needs: bash, git (full history: live_reload.sh archives an old ref),
# awk, perl, luajit, and cargo when REMUDA_BIN is unset and the binary cache
# misses.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
CORE_URL=${CORE_URL:-https://github.com/warmblood-kr/remuda.git}
# The core pin is shared: tests/core_ref.sh.
source "$REPO/tests/core_ref.sh"
source "$REPO/tests/ci/core_binary.sh"
source "$REPO/tests/lib/pool.sh"

case ${1:-} in
  --list)
    exec "$REPO/tests/ci/manifest.sh" --list
    ;;
  --tsv)
    exec "$REPO/tests/ci/manifest.sh" --tsv
    ;;
  "")
    ;;
  *)
    echo "usage: tests/shell_tests.sh [--list|--tsv]" >&2
    exit 2
    ;;
esac

T=$(mktemp -d /tmp/bst.XXXXXX)
T=$(cd "$T" && pwd -P)
LOGDIR=$T/logs
TASKDIR=$T/tasks
mkdir -p "$LOGDIR" "$TASKDIR"
POOL_CANCEL_REQUESTED=0
POOL_STARTED=0

retain_evidence() {
  local mode=$1 dest=${SHELL_TESTS_ARTIFACTS:-} d
  [[ -n $dest ]] || return 0
  mkdir -p "$dest" || return 0
  if [[ $mode == all ]]; then
    cp -R "$T/logs" "$dest/" 2>/dev/null || true
    cp "$T/manifest.tsv" "$dest/manifest.tsv" 2>/dev/null || true
    mkdir -p "$dest/registries" 2>/dev/null || true
    for d in "$T"/tasks/*; do
      [[ -d $d ]] || continue
      cp -R "$d/registry" "$dest/registries/$(basename "$d")" 2>/dev/null || true
    done
  else
    [[ -f $T/logs/summary.tsv ]] && cp "$T/logs/summary.tsv" "$dest/summary.tsv" 2>/dev/null || true
    cp "$T/manifest.tsv" "$dest/manifest.tsv" 2>/dev/null || true
  fi
  echo "shell tests artifacts: $dest" >&2
}

write_step_summary() {
  local f=$T/logs/summary.tsv
  [[ -n ${GITHUB_STEP_SUMMARY:-} && -f $f ]] || return 0
  {
    echo
    echo "## shell pool"
    echo
    echo '```'
    head -25 "$f"
    echo '```'
  } >>"$GITHUB_STEP_SUMMARY" 2>/dev/null || true
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  write_step_summary
  if ((rc != 0)); then
    retain_evidence all
    echo "shell tests scratch kept: $T" >&2
  else
    retain_evidence summary
    if [[ ${SHELL_TESTS_KEEP:-0} == 1 ]]; then
      echo "shell tests scratch kept: $T"
    else
      rm -rf "$T"
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'POOL_CANCEL_REQUESTED=1' INT TERM

core_binary_resolve || exit 2
core_ref_check || exit 2

mkdir -p "$T/bin" && cp "$REMUDA_BIN" "$T/bin/remuda" && chmod 755 "$T/bin/remuda" || {
  echo "cannot copy the core binary from $REMUDA_BIN. Next: set REMUDA_BIN to a built remuda" >&2
  exit 2
}
export PATH="$T/bin:$PATH" REMUDA_BIN="$T/bin/remuda" REMUDA_NO_UPDATE_CHECK=1
unset REMUDA_SERVER

version=$("$REMUDA_BIN" --version 2>/dev/null | tail -1)
echo "core $version, butler $(git -C "$REPO" rev-parse --short HEAD)"

# Every task gets private HOME/XDG/runtime/cache/state roots and no inherited
# live session identity. Deliberate knobs (REMUDA_BIN, CORE_REF,
# REMUDA_LUA_RESULT_WAIT, BUTLER_TEST_FILTER, REMUDA_BUTLER_LIVE_CODEX) survive;
# CODEX_HOME is pinned to the real login before HOME moves.
pool_sanitize_env

"$REPO/tests/ci/manifest.sh" --tsv >"$T/manifest.tsv" || exit 2
if ((POOL_CANCEL_REQUESTED)); then
  echo "shell tests: cancelled before the pool started" >&2
  exit 130
fi

jobs=${SHELL_TESTS_JOBS:-12}
case $jobs in
  ''|*[!0-9]*)
    echo "SHELL_TESTS_JOBS must be a positive integer, got '$jobs'" >&2
    exit 2
    ;;
esac
jobs=$((10#$jobs))
if ((jobs < 1)); then
  echo "SHELL_TESTS_JOBS must be at least 1" >&2
  exit 2
fi

POOL_STARTED=1
pool_run "$T/manifest.tsv" "$jobs" "$LOGDIR" "$TASKDIR" "$REPO" "$REPO/tests/lib/pool_task.sh"
rc=$?
if ((rc != 0)); then
  exit "$rc"
fi
echo "shell tests: PASS"
exit 0
