#!/usr/bin/env bash
# Run every standalone test against one pinned core: each tests/*.sh (each
# makes its own private daemon and scratch dirs) and the luajit unit tests.
#
#   tests/shell_tests.sh                     # clone + build core at CORE_REF
#   REMUDA_BIN=~/.local/bin/remuda tests/shell_tests.sh
#
# Needs: bash, git (full history: live_reload.sh archives an old ref),
# python3, luajit, and cargo when REMUDA_BIN is unset.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
CORE_URL=${CORE_URL:-https://github.com/warmblood-kr/remuda.git}
# Keep in step with tests/rust_tests.sh and tests/golden_guidance.sh; Butler's
# lifecycle declaration needs the schedule and hook APIs available in 4bbd90f (hook owner by extent).
CORE_REF=${CORE_REF:-4bbd90f}
T=$(mktemp -d /tmp/bst.XXXXXX)
trap 'rm -rf "$T"' EXIT

if [[ -z ${REMUDA_BIN:-} ]]; then
  git clone --quiet "$CORE_URL" "$T/core" && git -C "$T/core" checkout --quiet "$CORE_REF" &&
    (cd "$T/core" && cargo build --quiet --release --bin remuda) || { echo "core build failed" >&2; exit 2; }
  REMUDA_BIN=$T/core/target/release/remuda
fi
mkdir -p "$T/bin" && cp "$REMUDA_BIN" "$T/bin/remuda"
export PATH="$T/bin:$PATH" REMUDA_BIN="$T/bin/remuda" REMUDA_NO_UPDATE_CHECK=1
unset REMUDA_SERVER
echo "core $(remuda --version 2>/dev/null | tail -1), butler $(git -C "$REPO" rev-parse --short HEAD)"

failed=()
run() { # name command...
  local log="$T/$1.log"
  if (cd "$REPO" && "${@:2}") >"$log" 2>&1; then echo "PASS $1"; else echo "FAIL $1"; tail -20 "$log"; failed+=("$1"); fi
}
for lua in "$REPO"/tests/*.lua; do
  # session_tree.lua needs a live daemon's _butler_bus; session_tree.sh runs it.
  [[ $(basename "$lua") == session_tree.lua ]] && continue
  run "$(basename "$lua")" luajit "tests/$(basename "$lua")"
done
for sh in "$REPO"/tests/*.sh; do
  case $(basename "$sh") in rust_tests.sh | golden_guidance.sh | shell_tests.sh) continue ;; esac
  run "$(basename "$sh")" bash "$sh"
done

if ((${#failed[@]})); then echo "shell tests FAILED: ${failed[*]}" >&2; exit 1; fi
echo "shell tests: PASS"
