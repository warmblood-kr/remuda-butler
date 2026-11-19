#!/usr/bin/env bash
# The installer's opt-in physical name: record, init.lua override, poll script.
# No live daemon: a stub remuda records the calls and prints ready status.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)

run_installer() { # scratch [env assignments...]
  local scratch=$1
  shift
  mkdir -p "$scratch/bin" "$scratch/home/.config/remuda/butler"
  printf token >"$scratch/home/.config/remuda/butler/token"
  printf config >"$scratch/home/.config/remuda/butler/config"
  cat >"$scratch/bin/remuda" <<'SH'
#!/bin/sh
printf 'name=%s args=%s\n' "${REMUDA_BUTLER_NAME:-}" "$*" >>"$REMUDA_TEST_CALLS"
case "$1" in
  mod|exec|ls) exit 0 ;;
  butler) printf 'ready\n'; exit 0 ;;
  *) printf 'remuda: unknown command: %s\n' "$1" >&2; exit 2 ;;
esac
SH
  cat >"$scratch/bin/uname" <<'SH'
#!/bin/sh
printf 'Darwin\n'
SH
  for name in launchctl systemctl; do
    cat >"$scratch/bin/$name" <<'SH'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >>"$REMUDA_TEST_CALLS"
SH
  done
  chmod +x "$scratch/bin/"*
  (
    cd "$REPO"
    env HOME="$scratch/home" XDG_CONFIG_HOME="$scratch/home/.config" \
      XDG_DATA_HOME="$scratch/data" PATH="$scratch/bin:/usr/bin:/bin" \
      REMUDA_TEST_CALLS="$scratch/calls" "$@" \
      sh install/install-butler.sh >"$scratch/out" 2>&1
  )
}

fail() {
  echo "FAIL: $*" >&2
  [ -n "${scratch:-}" ] && { echo "--- out" >&2; cat "$scratch/out" >&2 || true; }
  exit 1
}

# 1. Opt-in distinct name.
scratch=$(mktemp -d /tmp/butler-installer-name.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM
run_installer "$scratch" REMUDA_BUTLER_NAME=butler-alt || fail "installer exited $?"

record="$scratch/data/remuda/butler/effective-name"
[ -f "$record" ] || fail "installer did not write $record"
grep -qx 'version=1' "$record" || fail "record has no version"
grep -qx 'logical=butler' "$record" || fail "record lost the logical name"
grep -qx 'name=butler-alt' "$record" || fail "record did not keep the physical name"

init="$scratch/home/.config/remuda/init.lua"
[ -f "$init" ] || fail "installer did not write init.lua"
grep -qx 'remuda._butler_initial_name_override = "butler-alt"' "$init" \
  || fail "init.lua does not carry the override"
grep -qx 'remuda.exec("butler")' "$init" || fail "init.lua no longer registers butler"
command -v luajit >/dev/null 2>&1 && { luajit -b "$init" /dev/null || fail "init.lua is not valid Lua"; }

poll="$scratch/home/.config/remuda/butler-poll.sh"
[ -f "$poll" ] || fail "installer did not write the poll script"
grep -q 'butler_name="butler-alt"' "$poll" || fail "poll script lost the effective name"
grep -Fq 'awk -v name="$butler_name"' "$poll" || fail "poll awk does not use the effective name"
grep -q '\$1 == "butler"' "$poll" && fail "poll script still hardcodes the literal name"
grep -Fq 'REMUDA_BUTLER_NAME="$butler_name" remuda exec butler' "$poll" \
  || fail "poll relaunch does not pass the effective name to the daemon image"
grep -q 'name=butler-alt args=exec butler' "$scratch/calls" \
  || fail "the install probe did not pass REMUDA_BUTLER_NAME"

# 2. A default install keeps the name butler everywhere, and the package reads
#    back exactly that name from the record this script wrote.
scratch=$(mktemp -d /tmp/butler-installer-default.XXXXXX)
run_installer "$scratch" || fail "default installer exited $?"
grep -qx 'name=butler' "$scratch/data/remuda/butler/effective-name" \
  || fail "default record is not butler"
grep -qx 'remuda._butler_initial_name_override = "butler"' \
  "$scratch/home/.config/remuda/init.lua" || fail "default init.lua override is not butler"
grep -q 'butler_name="butler"' "$scratch/home/.config/remuda/butler-poll.sh" \
  || fail "default poll script is not butler"
if command -v luajit >/dev/null 2>&1; then
  resolved=$(EFFECTIVE_NAME_MOD="$REPO/packages/butler/effective_name.lua" \
    EFFECTIVE_RECORD="$scratch/data/remuda/butler/effective-name" luajit -e '
    local M = dofile(assert(os.getenv("EFFECTIVE_NAME_MOD")))
    local f = assert(io.open(assert(os.getenv("EFFECTIVE_RECORD")), "rb"))
    local text = f:read("a"); f:close()
    io.write(tostring(M.resolve(nil, nil, M.recorded_name(text))))
  ')
  [ "$resolved" = butler ] || fail "the package reads '$resolved' from the default record"
fi
rm -rf "$scratch"

# 3. An invalid name is refused before any persistence layer is written.
scratch=$(mktemp -d /tmp/butler-installer-invalid.XXXXXX)
if run_installer "$scratch" REMUDA_BUTLER_NAME='butler/alt'; then
  rm -rf "$scratch"
  fail "installer accepted an invalid REMUDA_BUTLER_NAME"
fi
grep -q 'REMUDA_BUTLER_NAME' "$scratch/out" || { rm -rf "$scratch"; fail "refusal does not name the variable"; }
[ -e "$scratch/home/.config/remuda/init.lua" ] && { rm -rf "$scratch"; fail "refusal still wrote init.lua"; }
[ -e "$scratch/home/.config/remuda/butler-poll.sh" ] && { rm -rf "$scratch"; fail "refusal still wrote the poll script"; }
[ -e "$scratch/data/remuda/butler/effective-name" ] && { rm -rf "$scratch"; fail "refusal still wrote the record"; }
rm -rf "$scratch"

# 4. A failed record write stops the install and preserves every later file:
#    leaving the record claiming one name while the probe launched under
#    another would be the exact mismatch this record exists to prevent.
scratch=$(mktemp -d /tmp/butler-installer-nowrite.XXXXXX)
mkdir -p "$scratch/data/remuda/butler" "$scratch/home/.config/remuda"
printf 'prior init.lua\n' >"$scratch/home/.config/remuda/init.lua"
printf 'prior poll\n' >"$scratch/home/.config/remuda/butler-poll.sh"
chmod 500 "$scratch/data/remuda/butler"
if run_installer "$scratch" REMUDA_BUTLER_NAME=butler-alt; then
  chmod 700 "$scratch/data/remuda/butler"; rm -rf "$scratch"
  fail "installer succeeded although the record was unwritable"
fi
chmod 700 "$scratch/data/remuda/butler"
grep -q 'effective-name' "$scratch/out" \
  || { rm -rf "$scratch"; fail "the refusal does not name the record it could not write"; }
grep -qx 'prior init.lua' "$scratch/home/.config/remuda/init.lua" \
  || { rm -rf "$scratch"; fail "a failed record write overwrote init.lua"; }
grep -qx 'prior poll' "$scratch/home/.config/remuda/butler-poll.sh" \
  || { rm -rf "$scratch"; fail "a failed record write overwrote the poll script"; }
[ -e "$scratch/calls" ] && grep -q 'args=exec butler' "$scratch/calls" \
  && { rm -rf "$scratch"; fail "the probe ran under a name the record did not keep"; }
rm -rf "$scratch"

echo "PASS installer writes the opt-in effective name, keeps the default, and refuses an invalid name or failed record write"
