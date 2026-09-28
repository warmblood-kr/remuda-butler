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
# daemon.rs and is core's to test. Needs: cargo, git, python3.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
CORE_URL=${CORE_URL:-https://github.com/warmblood-kr/remuda.git}
# Core with delivery channel hooks. Bump deliberately; a core change must not
# redden Butler PRs.
CORE_REF=${CORE_REF:-844b0c9}

scratch=$(mktemp -d /tmp/butler-rust.XXXXXX)
trap 'rm -rf "$scratch"' EXIT

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
cp "$REPO/tests/support/matrix_stub_server.py" "$REPO/tests/support/fake_http.lua" "$CORE_DIR/native/tests/support/"
ln -sfn "$REPO/packages" "$CORE_DIR/packages"

export XDG_DATA_HOME=$scratch/data
mkdir -p "$XDG_DATA_HOME/remuda/mods/butler"
cp -R "$REPO/extension.toml" "$REPO/packages" "$XDG_DATA_HOME/remuda/mods/butler/"
unset REMUDA_SERVER REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG

echo "core $(git -C "$CORE_DIR" rev-parse --short HEAD), butler $(git -C "$REPO" rev-parse --short HEAD)"
cd "$CORE_DIR"
cargo test -p remuda-native --test butler_mcp
# a_fresh_daemon_* stay in core's daemon.rs; everything else matching is Butler's.
cargo test -p remuda-native --test butler_daemon -- butler matrix_reply --skip a_fresh_daemon
