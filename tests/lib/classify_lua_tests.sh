#!/usr/bin/env bash
# Every Lua test is explicitly assigned to the fast, contract or deep tier.
set -euo pipefail
root=${1:-$(cd "$(dirname "$0")/../.." && pwd)}
manifest="$root/tests/lua-test-tiers.txt"
[[ -f $manifest ]] || { echo 'missing Lua test tier manifest' >&2; exit 2; }
list=$(mktemp -d)
trap 'rm -rf "$list"' EXIT
: > "$list/declared"
while read -r tier path extra; do
  [[ -z $tier || $tier == \#* ]] && continue
  case "$tier" in fast|contract|deep) ;; *) echo "invalid Lua tier: $tier" >&2; exit 2 ;; esac
  [[ -n $path && -z ${extra:-} ]] || { echo 'invalid Lua tier entry' >&2; exit 2; }
  case "$path" in tests/*.lua) ;; *) echo "invalid Lua test path: $path" >&2; exit 2 ;; esac
  if [[ $tier == fast && $path == tests/lua/* ]]; then
    echo "daemon Lua test cannot run in fast tier: $path" >&2; exit 2
  fi
  if [[ $tier == contract && $path != tests/lua/butler_fast_contract_test.lua ]]; then
    echo "not run by the contract job: $path" >&2; exit 2
  fi
  [[ -f $root/$path ]] || { echo "missing Lua test: $path" >&2; exit 2; }
  printf '%s\n' "$path" >> "$list/declared"
done < "$manifest"
contract=tests/lua/butler_fast_contract_test.lua
if [[ -f $root/$contract ]] && ! grep -Fxq "contract $contract" "$manifest"; then
  echo 'core contract test must remain in the contract tier' >&2; exit 2
fi
sort "$list/declared" > "$list/sorted"
if [[ -n $(uniq -d "$list/sorted") ]]; then echo 'duplicate Lua test tier entry' >&2; exit 2; fi
: > "$list/actual"
for file in "$root"/tests/*.lua "$root"/tests/lua/*_test.lua; do
  [[ -f $file ]] || continue
  printf '%s\n' "${file#"$root"/}" >> "$list/actual"
done
sort "$list/actual" -o "$list/actual"
if ! diff -u "$list/sorted" "$list/actual"; then
  echo 'Lua test tier classification is incomplete' >&2; exit 2
fi
echo 'Lua test classification: PASS'
