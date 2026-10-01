#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/scripts" "$fixture/src"
cp "$ROOT/scripts/check-no-shell-lua.sh" "$fixture/scripts/"
cat >"$fixture/scripts/no-shell-lua-allowlist.txt" <<'EOF'
src/frozen.lua|1
EOF
cat >"$fixture/src/frozen.lua" <<'EOF'
os.execute("existing allowlisted call")
EOF
cat >"$fixture/src/new.lua" <<'EOF'
io . popen ("new prohibited call")
os [ "execute" ] ("another new prohibited call")
os . execute ("spacing variant")
io["popen"]("bracketed popen")
local e = os.execute
os.execute "without parentheses"
os.execute[[long-bracket call]]
EOF
git -C "$fixture" init -q
git -C "$fixture" add .

if sh "$fixture/scripts/check-no-shell-lua.sh" "$fixture" >"$fixture/red.log" 2>&1; then
  echo 'guard accepted a new io.popen call' >&2
  exit 1
fi
if ! grep -F 'unapproved shell call: src/new.lua (7 occurrence(s), not allowlisted)' "$fixture/red.log" >/dev/null; then
  cat "$fixture/red.log" >&2
  echo 'guard failed without identifying the new shell call' >&2
  exit 1
fi

cat >"$fixture/src/new.lua" <<'EOF'
return true
EOF
cat >"$fixture/src/frozen.lua" <<'EOF'
return true
EOF
git -C "$fixture" add .
if sh "$fixture/scripts/check-no-shell-lua.sh" "$fixture" >"$fixture/stale.log" 2>&1; then
  echo 'guard accepted a stale allowlist entry' >&2
  exit 1
fi
if ! grep -F 'stale shell-call allowlist entry: src/frozen.lua' "$fixture/stale.log" >/dev/null; then
  cat "$fixture/stale.log" >&2
  echo 'guard failed without identifying the stale allowlist entry' >&2
  exit 1
fi

mkdir -p "$fixture/packages/butler"
cat >"$fixture/scripts/no-shell-lua-allowlist.txt" <<'EOF'
EOF
cat >"$fixture/packages/butler/foreign.lua" <<'EOF'
local windows = package.config:sub(1, 1) == "\\"
EOF
git -C "$fixture" add .
if sh "$fixture/scripts/check-no-shell-lua.sh" "$fixture" >"$fixture/os-check.log" 2>&1; then
  echo 'guard accepted an OS check outside packages/butler/system.lua' >&2
  exit 1
fi
if ! grep -F 'OS check outside packages/butler/system.lua: packages/butler/foreign.lua' "$fixture/os-check.log" >/dev/null; then
  cat "$fixture/os-check.log" >&2
  echo 'guard failed without identifying the OS check' >&2
  exit 1
fi

echo 'ok - new shell calls and OS checks fail; removed shell calls must leave the allowlist'
sh "$ROOT/scripts/check-no-shell-lua.sh"
