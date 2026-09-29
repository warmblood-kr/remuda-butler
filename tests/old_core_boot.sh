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
T=$(cd "$T" && pwd -P)
S=boc
ID=$((RANDOM % 90000 + 10000))  # this run's own fake-session sleep
DAEMON_PID=
export REMUDA_RUNTIME_DIR=$T/run XDG_DATA_HOME=$T/data XDG_CONFIG_HOME=$T/config
export HOME=$T/home REMUDA_BUTLER_PROJECT_HOME=$T/projects REMUDA_BUTLER_SERVER=$S
unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG
MOD=$XDG_DATA_HOME/remuda/mods/butler
mkdir -p "$MOD" "$HOME" "$XDG_CONFIG_HOME/remuda/butler" "$T/bin"
cat >"$T/bin/fake-session" <<EOF_SESSION
#!/bin/sh
echo "\$\$" >>"$T/child-pids"
exec /bin/sleep "$ID"
EOF_SESSION
chmod +x "$T/bin/fake-session"
cleanup() {
  local status=$? pid killed=0 left=0
  local descendants=() session_pids=()
  if [[ -n "$DAEMON_PID" ]]; then
    while IFS= read -r pid; do [[ -n "$pid" ]] && descendants+=("$pid"); done < <(
      ps -axo pid=,ppid= | awk -v root="$DAEMON_PID" '
        { ppid[$1]=$2; rows[NR]=$1 }
        END {
          found[root]=1
          do {
            changed=0
            for (i=1; i<=NR; i++) if (!found[rows[i]] && found[ppid[rows[i]]]) {
              found[rows[i]]=1; changed=1
            }
          } while (changed)
          for (i=1; i<=NR; i++) if (rows[i] != root && found[rows[i]]) print rows[i]
        }')
  fi
  if [[ -f $T/child-pids ]]; then
    while IFS= read -r pid; do [[ -n "$pid" ]] && session_pids+=("$pid"); done <"$T/child-pids"
  fi
  if [[ ${REMUDA_RUNTIME_DIR:-} == "$T/run" ]]; then
    remuda -s "$S" stop -f >/dev/null 2>&1 || true
  else
    echo "refusing to stop old-core daemon outside its scratch runtime" >&2
  fi
  for pid in "${descendants[@]}" "${session_pids[@]}" "$DAEMON_PID"; do
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      killed=$((killed + 1))
    fi
  done
  [[ -n "$DAEMON_PID" ]] && wait "$DAEMON_PID" 2>/dev/null || true
  for _ in $(seq 20); do
    left=0
    for pid in "${descendants[@]}" "${session_pids[@]}"; do
      [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1 && left=$((left + 1))
    done
    [[ $left == 0 ]] && break
    sleep 0.05
  done
  rm -rf "$T"
  echo "resources cleaned: $killed killed / $left left"
  trap - EXIT INT TERM
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
