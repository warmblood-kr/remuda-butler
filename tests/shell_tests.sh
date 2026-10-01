#!/usr/bin/env bash
# Run every standalone test against one pinned core: each tests/*.sh (each
# makes its own private daemon and scratch dirs) and the luajit unit tests.
#
#   tests/shell_tests.sh                     # clone + build core at CORE_REF
#   REMUDA_BIN=~/.local/bin/remuda tests/shell_tests.sh
#
# Needs: bash, git (full history: live_reload.sh archives an old ref),
# awk, perl, luajit, and cargo when REMUDA_BIN is unset.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
CORE_URL=${CORE_URL:-https://github.com/warmblood-kr/remuda.git}
# Same pin as tests/rust_tests.sh and tests/golden_guidance.sh; keep them in step.
CORE_REF=${CORE_REF:-499b8b95}
T=$(mktemp -d /tmp/bst.XXXXXX)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT

if [[ -z ${REMUDA_BIN:-} ]]; then
  git clone --quiet "$CORE_URL" "$T/core" && git -C "$T/core" checkout --quiet "$CORE_REF" &&
    (cd "$T/core" && cargo build --quiet --release --bin remuda) || { echo "core build failed" >&2; exit 2; }
  # cargo resolves a relative CARGO_TARGET_DIR against the clone.
  REMUDA_BIN=$(cd "$T/core" && cd "${CARGO_TARGET_DIR:-target}/release" && pwd)/remuda
  built=$(git -C "$T/core" rev-parse --short=7 HEAD)
fi
mkdir -p "$T/bin" && cp "$REMUDA_BIN" "$T/bin/remuda" ||
  { echo "cannot copy the core binary from $REMUDA_BIN. Next: set REMUDA_BIN to a built remuda" >&2; exit 2; }
export PATH="$T/bin:$PATH" REMUDA_BIN="$T/bin/remuda" REMUDA_NO_UPDATE_CHECK=1
unset REMUDA_SERVER
version=$("$REMUDA_BIN" --version 2>/dev/null | tail -1)
# The core built here must be the one under test, never an installed remuda.
if [[ -n ${built:-} && $version != *"$built"* ]]; then
  echo "core under test is '$version', not the pinned $built. Next: rerun; if it repeats, another build is using this CARGO_TARGET_DIR" >&2
  exit 2
fi
echo "core $version, butler $(git -C "$REPO" rev-parse --short HEAD)"

failed=()
run() { # name command...
  local log="$T/$1.log"
  if (cd "$REPO" && "${@:2}") >"$log" 2>&1; then echo "PASS $1"; else echo "FAIL $1"; tail -20 "$log"; failed+=("$1"); fi
}
for lua in "$REPO"/tests/*.lua; do
  # session_tree.lua needs a live daemon's _butler_bus; session_tree.sh runs it.
  # The Matrix relay state tests need core's remuda.json; its shell wrapper
  # runs them inside the pinned daemon instead of standalone LuaJIT.
  [[ $(basename "$lua") == session_tree.lua || $(basename "$lua") == butler_matrix_relay.lua ]] && continue
  run "$(basename "$lua")" luajit "tests/$(basename "$lua")"
done
for sh in "$REPO"/tests/*.sh; do
  case $(basename "$sh") in rust_tests.sh | golden_guidance.sh | shell_tests.sh) continue ;; esac
  run "$(basename "$sh")" bash "$sh"
done

if ((${#failed[@]})); then echo "shell tests FAILED: ${failed[*]}" >&2; exit 1; fi
echo "shell tests: PASS"
