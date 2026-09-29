#!/usr/bin/env bash
# Compile and run Butler's Rust tests against a Remuda core checkout.
#
# The tests are core integration tests (they link remuda-native and spawn its
# binary), so they are dropped into core's native/tests/ with this repo's
# packages/ beside them, and Butler is installed into a scratch XDG_DATA_HOME.
#
#   tests/rust_tests.sh                     # clones core at CORE_REF
#   CORE_DIR=~/src/remuda tests/rust_tests.sh
#
# Only Butler's tests run: the rest of butler_daemon.rs duplicates core's own
# daemon.rs and is core's to test. Needs: cargo and git. Matrix relay coverage
# uses the local Lua fake HTTP fixture, not a separate stub-server process.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
CORE_URL=${CORE_URL:-https://github.com/warmblood-kr/remuda.git}
# Core with delivery channel hooks, extension-command stdin, and fs.write_atomic.
# Bump deliberately; a core change must not redden Butler PRs.
CORE_REF=${CORE_REF:-7447a1d}

scratch=$(mktemp -d /tmp/butler-rust.XXXXXX)
scratch=$(cd "$scratch" && pwd -P)

relay_pids_under_scratch() {
  ps -ww -axo pid=,command= | awk '/MAX_PROCESSED_EVENT_IDS = 5000/ { print $1 }' |
    while read -r pid; do
      [[ -n $pid ]] || continue
      if [[ -e /proc/$pid/cwd ]]; then
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
      else
        cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)
      fi
      case "$cwd" in
        "$scratch"|"$scratch"/*) printf '%s\n' "$pid" ;;
      esac
    done
}

stop_scratch_relays() {
  local pid deadline
  for pid in $(relay_pids_under_scratch); do kill -TERM "$pid" 2>/dev/null || true; done
  deadline=$((SECONDS + 2))
  while [[ $SECONDS -lt $deadline ]] && [[ -n $(relay_pids_under_scratch) ]]; do sleep 0.05; done
  for pid in $(relay_pids_under_scratch); do kill -KILL "$pid" 2>/dev/null || true; done
  deadline=$((SECONDS + 2))
  while [[ $SECONDS -lt $deadline ]] && [[ -n $(relay_pids_under_scratch) ]]; do sleep 0.05; done
}

cleanup() {
  stop_scratch_relays
  rm -rf "$scratch"
}
trap cleanup EXIT

source_home=${HOME:-/tmp}
export CARGO_HOME=${CARGO_HOME:-$source_home/.cargo}
export RUSTUP_HOME=${RUSTUP_HOME:-$source_home/.rustup}
export HOME=$scratch/home
export XDG_CONFIG_HOME=$scratch/config
export XDG_CACHE_HOME=$scratch/cache
export XDG_STATE_HOME=$scratch/state
export REMUDA_RUNTIME_DIR=$scratch/runtime
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$REMUDA_RUNTIME_DIR"

if [[ -z ${CORE_DIR:-} ]]; then
  CORE_DIR=$scratch/remuda
  git clone --quiet "$CORE_URL" "$CORE_DIR"
  git -C "$CORE_DIR" checkout --quiet "$CORE_REF"
fi

cp "$REPO/tests/butler_daemon.rs" "$REPO/tests/butler_mcp.rs" "$CORE_DIR/native/tests/"
mkdir -p "$CORE_DIR/native/tests/support"
cp "$REPO/tests/support/fake_http.lua" "$CORE_DIR/native/tests/support/"
ln -sfn "$REPO/packages" "$CORE_DIR/packages"

export XDG_DATA_HOME=$scratch/data
export XDG_CONFIG_HOME=$scratch/config
export TMPDIR=$scratch/tmp
export HOME=$scratch/home
export REMUDA_RUNTIME_DIR=$scratch/run
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$REMUDA_RUNTIME_DIR" "$TMPDIR" "$XDG_DATA_HOME/remuda/mods/butler"
cp -R "$REPO/extension.toml" "$REPO/packages" "$XDG_DATA_HOME/remuda/mods/butler/"
unset REMUDA_SERVER REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG

echo "core $(git -C "$CORE_DIR" rev-parse --short HEAD), butler $(git -C "$REPO" rev-parse --short HEAD)"
cd "$CORE_DIR"
if [[ -z ${BUTLER_TEST_FILTER:-} ]]; then
  cargo test -p remuda-native --test butler_mcp
fi
# a_fresh_daemon_* stay in core's daemon.rs; everything else matching is Butler's.
if [[ -n ${BUTLER_TEST_FILTER:-} ]]; then
  cargo test -p remuda-native --test butler_daemon "$BUTLER_TEST_FILTER" -- --nocapture
else
  cargo test -p remuda-native --test butler_daemon -- butler matrix_reply
fi

remaining_relays=$(relay_pids_under_scratch)
if [[ -n $remaining_relays ]]; then
  echo "Matrix relay processes remain under test scratch $scratch: $remaining_relays" >&2
  exit 1
fi
