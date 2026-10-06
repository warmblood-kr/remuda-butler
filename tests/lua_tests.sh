#!/usr/bin/env bash
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
if (( $# == 0 )); then
  shopt -s nullglob
  files=("$REPO"/tests/lua/*_test.lua)
  failed=()
  for file in "${files[@]}"; do
    name=${file#"$REPO/"}
    start=$SECONDS
    if out=$("$REPO/tests/lua_tests.sh" "$name" 2>&1); then
      echo "PASS $name $((SECONDS - start))s"
    else
      # Show the whole log of the failing file, never just its tail: it names the real failure.
      echo "FAIL $name $((SECONDS - start))s"
      printf '%s\n' "$out"
      failed+=("$name")
    fi
  done
  if ((${#failed[@]})); then echo "lua tests FAILED: ${failed[*]}" >&2; exit 1; fi
  exit 0
fi
if (( $# != 1 )); then
  echo "usage: tests/lua_tests.sh [tests/lua/file_test.lua]" >&2
  exit 2
fi
source "$REPO/tests/lib/harness.sh"
harness_prepare
harness_run "$1"
