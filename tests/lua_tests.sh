#!/usr/bin/env bash
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
if (( $# == 0 )); then
  shopt -s nullglob
  files=("$REPO"/tests/lua/*_test.lua)
  status=0
  for file in "${files[@]}"; do
    if "$REPO/tests/lua_tests.sh" "${file#"$REPO/"}"; then
      :
    else
      status=1
    fi
  done
  exit "$status"
fi
if (( $# != 1 )); then
  echo "usage: tests/lua_tests.sh [tests/lua/file_test.lua]" >&2
  exit 2
fi
source "$REPO/tests/lib/harness.sh"
harness_prepare
harness_run "$1"
