#!/usr/bin/env bash
# Butler must boot on a core that predates the lifecycle `start` hook
# (warmblood-kr/remuda#104), and say so; on any core it boots exactly once
# per activation. Private daemon, scratch dirs; `remuda` is whatever is first
# on PATH, so run it once with an old core and once with a current one:
#   PATH=/path/to/old-core-dir:$PATH tests/old_core_boot.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
source "$REPO/tests/awk-timeout.sh"
T=$(mktemp -d /tmp/boc.XXXXXX)
S=boc
DAEMON_PID=
export REMUDA_RUNTIME_DIR=$T/run XDG_DATA_HOME=$T/data XDG_CONFIG_HOME=$T/config
export HOME=$T/home REMUDA_BUTLER_PROJECT_HOME=$T/projects REMUDA_BUTLER_SERVER=$S
unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG
MOD=$XDG_DATA_HOME/remuda/mods/butler
mkdir -p "$MOD" "$HOME" "$XDG_CONFIG_HOME/remuda/butler"
mkdir -p "$T/bin"
cat >"$T/bin/fake-session" <<EOF
#!/bin/sh
echo "\$\$" >>"$T/child-pids"
exec /bin/sleep 3600
EOF
chmod +x "$T/bin/fake-session"
cleanup() {
  status=$?
  if [[ ${REMUDA_RUNTIME_DIR:-} == "$T/run" ]]; then
    remuda -s "$S" stop -f >/dev/null 2>&1 || true
  else
    echo "refusing to stop old-core daemon outside its scratch runtime" >&2
  fi
  if [[ -f $T/child-pids ]]; then
    while IFS= read -r pid; do
      [[ -n $pid ]] || continue
      kill "$pid" >/dev/null 2>&1 || true
    done <"$T/child-pids"
  fi
  if [[ -n $DAEMON_PID ]]; then
    kill "$DAEMON_PID" >/dev/null 2>&1 || true
    wait "$DAEMON_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$T"
  exit "$status"
}
trap cleanup EXIT INT TERM
tar -c -C "$REPO" extension.toml packages | tar -x -C "$MOD"
lua() { remuda -s "$S" -e "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
boots() { lua 'return remuda.event_counts()["butler-start"] or 0'; }

echo "core: $(remuda -s "$S" --version 2>/dev/null | tail -1)"
remuda -s "$S" daemon >"$T/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 80); do
  [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] && break
  sleep 0.25
done
[[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] || { cat "$T/daemon.log" >&2; fail "private daemon did not bind"; }
lua "remuda._butler_argv = {'$T/bin/fake-session'}" >/dev/null
remuda -s "$S" butler --headless
sleep 1
remuda -s "$S" ls | bounded_awk '$1 == "butler" { found = 1 } END { exit !found }' || fail "butler never booted"
[[ $(boots) == 1 ]] || fail "boots=$(boots) after one activation, want 1"
remuda -s "$S" butler sessions >/dev/null || fail "'butler sessions' failed: mod command not loaded"

lua "for _ = 1, 5 do remuda.reload('butler') end"
sleep 1
[[ $(boots) == 6 ]] || fail "boots=$(boots) after 5 reloads, want 6"
# Fallback boots say so in <server>.log; a current core never needs one.
fallbacks=$(grep -c 'booted by fallback' "$REMUDA_RUNTIME_DIR/remuda/$S.log" 2>/dev/null || true)
echo "fallback boots logged: ${fallbacks:-0} of 6"
[[ ${fallbacks:-0} == 0 || ${fallbacks:-0} == 6 ]] || fail "mixed start/fallback boots: $fallbacks"
echo PASS
