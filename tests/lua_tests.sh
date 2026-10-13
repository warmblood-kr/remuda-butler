#!/usr/bin/env bash
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
if (( $# == 0 )); then
  shopt -s nullglob
  files=("$REPO"/tests/lua/*_test.lua)
  failed=() logs=()
  for file in "${files[@]}"; do
    name=${file#"$REPO/"}
    start=$SECONDS
    if out=$("$REPO/tests/lua_tests.sh" "$name" 2>&1); then
      echo "PASS $name $((SECONDS - start))s"
    else
      echo "FAIL $name $((SECONDS - start))s"
      failed+=("$name")
      logs+=("--- $name"$'\n'"$out")
    fi
  done
  # Failing logs last: shell_tests.sh shows only the tail of this script's output, and it must name the real failure.
  if ((${#failed[@]})); then printf '%s\n' "${logs[@]}"; echo "lua tests FAILED: ${failed[*]}" >&2; exit 1; fi
  exit 0
fi
if (( $# != 1 )); then
  echo "usage: tests/lua_tests.sh [tests/lua/file_test.lua]" >&2
  exit 2
fi
source "$REPO/tests/lib/harness.sh"
harness_prepare
harness_run "$1"
