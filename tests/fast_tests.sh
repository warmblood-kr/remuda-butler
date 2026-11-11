#!/usr/bin/env bash
# Fast, daemon-free logic and contract checks for every change.
set -euo pipefail
cd "$(dirname "$0")/.."
BUTLER_SHELL_MODE=classify bash tests/shell_tests.sh
bash tests/lib/classify_lua_tests.sh
bash tests/lib/lua_classification_test.sh

while read -r tier test; do
  [[ $tier == fast ]] || continue
  luajit "$test"
  echo "PASS $test"
done < tests/lua-test-tiers.txt
bash tests/isolated_env_admission_test.sh
bash tests/isolated_env_cleanup_test.sh
echo 'fast tests: PASS'
