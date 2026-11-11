#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tests/lua"
printf 'fast tests/first.lua\ndeep tests/lua/second_test.lua\n' > "$tmp/tests/lua-test-tiers.txt"
touch "$tmp/tests/first.lua" "$tmp/tests/lua/second_test.lua"
bash "$repo/tests/lib/classify_lua_tests.sh" "$tmp"
touch "$tmp/tests/unclassified.lua"
if bash "$repo/tests/lib/classify_lua_tests.sh" "$tmp" >"$tmp/log" 2>&1; then
  echo 'unclassified top-level Lua test passed' >&2; exit 1
fi
rm "$tmp/tests/unclassified.lua"
touch "$tmp/tests/lua/unclassified_test.lua"
if bash "$repo/tests/lib/classify_lua_tests.sh" "$tmp" >"$tmp/log" 2>&1; then
  echo 'unclassified daemon Lua test passed' >&2; exit 1
fi
rm "$tmp/tests/lua/unclassified_test.lua"
mkdir -p "$tmp/tests/lua/sub"
touch "$tmp/tests/lua/sub/nested_test.lua"
if bash "$repo/tests/lib/classify_lua_tests.sh" "$tmp" >"$tmp/log" 2>&1; then
  echo 'unclassified nested daemon Lua test passed' >&2; exit 1
fi
printf 'deep tests/lua/sub/nested_test.lua\n' >> "$tmp/tests/lua-test-tiers.txt"
if bash "$repo/tests/lib/classify_lua_tests.sh" "$tmp" >"$tmp/log" 2>&1; then
  echo 'nested test accepted although deep runner cannot discover it' >&2; exit 1
fi
sed -i.bak '/nested_test.lua/d' "$tmp/tests/lua-test-tiers.txt"
rm "$tmp/tests/lua/sub/nested_test.lua"
sed -i.bak 's/^deep /fast /' "$tmp/tests/lua-test-tiers.txt"
if bash "$repo/tests/lib/classify_lua_tests.sh" "$tmp" >"$tmp/log" 2>&1; then
  echo 'daemon test incorrectly accepted in fast tier' >&2; exit 1
fi
mv "$tmp/tests/lua-test-tiers.txt.bak" "$tmp/tests/lua-test-tiers.txt"
printf 'fast tests/first.lua\n' >> "$tmp/tests/lua-test-tiers.txt"
if bash "$repo/tests/lib/classify_lua_tests.sh" "$tmp" >"$tmp/log" 2>&1; then
  echo 'duplicate tier entry passed' >&2; exit 1
fi
echo 'Lua classification tests: PASS'
