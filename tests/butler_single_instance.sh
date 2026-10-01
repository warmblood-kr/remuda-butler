#!/usr/bin/env bash
# Single-instance guard (#195): a SECOND daemon that loads the Butler mod on
# the same home must not touch the state the first daemon owns. Two throwaway
# daemons on ONE scratch home; the homeserver is 127.0.0.1:9, so nothing
# leaves the machine. Never point this at a real home.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
T=$(mktemp -d /tmp/bsi.XXXXXX)
T=$(cd "$T" && pwd -P)
A=bsi-a B=bsi-b X=bsi-c D=bsi-d L=bsi-l G=bsi-g
export HOME=$T/home XDG_CONFIG_HOME=$T/config XDG_DATA_HOME=$T/data REMUDA_RUNTIME_DIR=$T/run
export REMUDA_BUTLER_PROJECT_HOME=$T/projects REMUDA_NO_UPDATE_CHECK=1
unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG REMUDA_BUTLER_TOPICS REMUDA_BUTLER_AGENT_ID REMUDA_BUTLER_LEADER_ID
unset REMUDA_SERVER REMUDA_BUTLER_SERVER XDG_RUNTIME_DIR
# Hard rule: every remuda call below runs only with the home, the runtime dir,
# the data side AND the config side under the scratch dir, and private session
# names. The config side matters as much as the data side: "a scratch data home
# with the real config" is exactly the damage this test is about. The override
# variables paths.lua reads (REMUDA_BUTLER_CONFIG, _TOKEN, _TOPICS) must stay
# unset, so no path can point outside the scratch dir.
assert_scratch() {
  [[ $T == /tmp/bsi.?????? || $T == /private/tmp/bsi.?????? ]] || { echo "ABORT: scratch dir is wrong: $T"; exit 9; }
  [[ $HOME == "$T/home" && $REMUDA_RUNTIME_DIR == "$T/run" && $XDG_DATA_HOME == "$T/data"
    && $XDG_CONFIG_HOME == "$T/config" && $REMUDA_BUTLER_PROJECT_HOME == "$T/projects" ]] \
    || { echo "ABORT: env is not scratch"; exit 9; }
  [[ -z ${REMUDA_BUTLER_CONFIG+set} && -z ${REMUDA_BUTLER_TOKEN+set} && -z ${REMUDA_BUTLER_TOPICS+set}
    && -z ${XDG_RUNTIME_DIR+set} ]] || { echo "ABORT: a Butler path override is set"; exit 9; }
  [[ $A == bsi-a && $B == bsi-b && $X == bsi-c && $D == bsi-d && $L == bsi-l && $G == bsi-g ]] || { echo "ABORT: session names"; exit 9; }
}
assert_scratch
# A daemon that is started with its own homes gets them only from inside the scratch dir.
under_scratch() {
  local path
  for path in "$@"; do
    [[ $path == "$T"/* && $path != *..* ]] || { echo "ABORT: not under the scratch dir: $path"; exit 9; }
  done
}

PIDS=()
FAKE_AGENT=$T/fake-agent
cleanup() {
  STATUS=$?
  assert_scratch
  for name in "$A" "$B" "$X" "$D" "$L" "$G"; do
    [[ -S $REMUDA_RUNTIME_DIR/remuda/$name.sock ]] || continue
    "$REMUDA_BIN" -s "$name" stop -f >/dev/null 2>&1 || true
  done
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do
    for _ in $(seq 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
  done
  if [[ -f $T/child-pids ]]; then
    # Only a PID that is still this script's fake agent; never a reused one.
    while IFS= read -r pid; do
      [[ -n $pid && $(ps -o command= -p "$pid" 2>/dev/null) == "/bin/sleep 1000" ]] || continue
      kill "$pid" 2>/dev/null || true
    done <"$T/child-pids"
  fi
  LEFT=$(ps -ax -o pid,command | grep -F "$T" | grep -v grep || true)
  [[ -z $LEFT ]] || echo "leftovers: $LEFT"
  rm -rf "$T"
  exit "$STATUS"
}
trap cleanup EXIT INT TERM

mkdir -p "$HOME" "$XDG_CONFIG_HOME/remuda/butler" "$XDG_DATA_HOME/remuda/mods/butler" "$REMUDA_RUNTIME_DIR"
chmod 700 "$REMUDA_RUNTIME_DIR"
tar -c -C "$REPO" extension.toml packages | tar -x -C "$XDG_DATA_HOME/remuda/mods/butler"
cat >"$FAKE_AGENT" <<EOF
#!/bin/sh
echo "\$\$" >>"$T/child-pids"
exec /bin/sleep 1000
EOF
chmod +x "$FAKE_AGENT"
C=$XDG_CONFIG_HOME/remuda/butler
printf 'http://127.0.0.1:9\n!home:example.org\n@bot:example.org\n@owner:example.org\n' >"$C/config"
printf 'token\n' >"$C/token"
chmod 600 "$C/config" "$C/token"
REGISTRY=$XDG_DATA_HOME/remuda/butler/agents.jsonl

lua() { assert_scratch; "$REMUDA_BIN" -s "$1" -e "$2"; }
start_daemon() { # session name
  assert_scratch
  REMUDA_BUTLER_SERVER=$1 "$REMUDA_BIN" -s "$1" daemon </dev/null >"$T/$1.log" 2>&1 &
  PIDS+=($!)
  for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$1.sock ]] && break; sleep 0.1; done
  [[ -S $REMUDA_RUNTIME_DIR/remuda/$1.sock ]] || { cat "$T/$1.log"; echo "FAIL: daemon $1 did not start"; exit 1; }
}
load_butler() { # session name, optional Lua run first
  lua "$1" "${2:-}remuda._butler_argv = {'$FAKE_AGENT'}; remuda.exec('butler')" >/dev/null 2>&1 || true
}

# The owner: daemon A with the root Butler, one live member and the relay.
start_daemon "$A"
# The guard needs core's remuda.fs.lock. On a core without it the same checks
# run with a FAKED lock word (the owner is granted it, every other daemon finds
# it held): that proves Butler's side, not the kernel lock, so the takeover and
# reload tests stay skipped until a core has the word.
LOCK_WORD=$(lua "$A" 'return remuda.fs ~= nil and type(remuda.fs.lock) == "function"')
FAKE_OWNER="" FAKE_SECOND="" FAKE_OTHER_DATA=""
if [[ $LOCK_WORD != true ]]; then
  CAN_FAKE=$(lua "$A" 'return (pcall(function() remuda.fs.lock = function() return {} end end)) and type(remuda.fs.lock) == "function"')
  [[ $CAN_FAKE == true ]] || { echo "skip - all: this core has no remuda.fs.lock and it cannot be faked"; exit 0; }
  FAKE_OWNER="remuda.fs.lock = function() return { release = function() end } end; "
  # A daemon with its own data home: that lock is free, the config lock is held.
  FAKE_OTHER_DATA="remuda.fs.lock = function(path) if path:find('/data2/', 1, true) then return { release = function() end } end return nil, 'held', 'remuda-lock session=$A pid=1 since=1790000000' end; "
  FAKE_SECOND="remuda.fs.lock = function() return nil, 'held', 'remuda-lock session=$A pid=1 since=1790000000' end; "
  echo "note - the lock is FAKED: this core has no remuda.fs.lock, so T1-T7 prove Butler's side only, not the OS lock"
else
  echo "note - the lock is REAL: this core has remuda.fs.lock ($("$REMUDA_BIN" --version | cut -d+ -f1))"
fi
load_butler "$A" "$FAKE_OWNER"
for _ in $(seq 50); do
  lua "$A" 'return remuda._butler_agent_builders ~= nil' | grep -qx true && break
  sleep 0.1
done
lua "$A" "remuda._butler_agent_builders.fake = function() return {'$FAKE_AGENT'} end; remuda._butler_launch('fake', 'member')" >/dev/null
for _ in $(seq 50); do
  lua "$A" 'return remuda.butler.matrix.relay.instance ~= nil' | grep -qx true && break
  sleep 0.1
done
lua "$A" 'return remuda.butler.matrix.relay.instance ~= nil' | grep -qx true || { echo "FAIL: setup: owner relay did not start"; exit 1; }
grep -q '"alias":"member"' "$REGISTRY" || { echo "FAIL: setup: owner has no member row in agents.jsonl"; exit 1; }
[[ -f $C/config.mcp.json ]] || { echo "FAIL: setup: owner wrote no config.mcp.json"; exit 1; }
FAILED=()
bad() { FAILED+=("$*"); echo "not ok - $*"; }
ok() { echo "ok - $*"; }
# config.mcp.json holds the root capability: owner-only, like config and token.
MCP_MODE=$(ls -l "$C/config.mcp.json" | cut -c1-10)
[[ $MCP_MODE == "-rw-------" ]] && ok "T0 config.mcp.json is private (0600)" \
  || bad "T0 config.mcp.json is private (0600): mode is $MCP_MODE"
# A member's MCP config carries that member's capability; it lives in the temp dir.
MEMBER_MCP=$(lua "$A" "return remuda._butler_agent_support.mcp_config_path('probe', 'test-token')")
MEMBER_MODE=$(ls -l "$MEMBER_MCP" | cut -c1-10)
[[ $MEMBER_MCP != *.probe.mcp.json ]] || rm -f "$MEMBER_MCP" "${MEMBER_MCP%.probe.mcp.json}"
[[ $MEMBER_MODE == "-rw-------" ]] && ok "T0 a member MCP config is private (0600)" \
  || bad "T0 a member MCP config is private (0600): mode is $MEMBER_MODE"
sleep 3 # let the owner's reconcile settle before the snapshot
mkdir "$T/snap"
cp "$REGISTRY" "$T/snap/agents.jsonl"
cp "$C/config.mcp.json" "$T/snap/config.mcp.json"
[[ ! -f $C/config.status.settings.json ]] || cp "$C/config.status.settings.json" "$T/snap/settings.json"

# The second daemon on the same home loads the mod.
start_daemon "$B"
load_butler "$B" "$FAKE_SECOND"
sleep 4 # longer than the 2 s reconcile schedule that would launch a root Butler

cmp -s "$REGISTRY" "$T/snap/agents.jsonl" && ok "T1 a second daemon does not touch agents.jsonl" \
  || bad "T1 a second daemon does not touch agents.jsonl: $(diff "$T/snap/agents.jsonl" "$REGISTRY" | grep '^>' | cut -c1-200 | head -3)"

T2=ok
cmp -s "$C/config.mcp.json" "$T/snap/config.mcp.json" || T2="config.mcp.json changed"
if [[ -f $T/snap/settings.json ]]; then
  cmp -s "$C/config.status.settings.json" "$T/snap/settings.json" || T2="$T2; status settings changed"
fi
[[ $T2 == ok ]] && ok "T2 a second daemon does not rewrite config.mcp.json or the status settings" \
  || bad "T2 a second daemon does not rewrite config.mcp.json or the status settings: ${T2#ok; }"

ROOT_IN_B=$(lua "$B" 'for _, s in ipairs(remuda.ls()) do if s.name == "butler" then return true end end return false')
[[ $ROOT_IN_B == false ]] && ok "T3 a second daemon starts no root Butler" \
  || bad "T3 a second daemon starts no root Butler: its session list has 'butler'"

RELAY_IN_B=$(lua "$B" 'local m = remuda.butler and remuda.butler.matrix; return (m and m.relay and m.relay.instance) ~= nil')
[[ $RELAY_IN_B == false ]] && ok "T4 a second daemon starts no relay" \
  || bad "T4 a second daemon starts no relay: it has a relay instance"

assert_scratch
set +e
OUT=$("$REMUDA_BIN" -s "$B" butler status 2>&1); CODE=$?
set -e
NEXTS=$(printf '%s\n' "$OUT" | grep -c '^Next:' || true)
if [[ $CODE == 1 && $OUT == *"already running in another Remuda daemon"* && $NEXTS == 1
  && $OUT == *"Next: remuda -s $A butler status"* ]]; then
  ok "T5 a second daemon refuses with one line and one Next:"
else
  bad "T5 a second daemon refuses with one line and one Next: exit $CODE, output: $(printf '%s' "$OUT" | head -3 | cut -c1-200)"
fi
assert_scratch
DOCTOR=$("$REMUDA_BIN" -s "$B" butler doctor 2>&1 | head -1 || true)
[[ $DOCTOR == "Not the owning daemon:"*"$A"* ]] && ok "T5 doctor still runs in a second daemon and its first line names the owner" \
  || bad "T5 doctor still runs in a second daemon and its first line names the owner: $(printf '%s' "$DOCTOR" | cut -c1-200)"

# T6: the empty session name (-s "") that caused the incident behind #195 is
# refused like any other second daemon. It runs ONLY on the scratch home: the
# env is asserted again immediately before each command, and this daemon is
# stopped by its recorded PID, never through `remuda -s "" stop`. When core
# refuses an empty session name (warmblood-kr/remuda#402) this becomes a test
# of that refusal.
EMPTY=""
empty_guard() {
  assert_scratch
  [[ $HOME == /private/tmp/bsi.*/home || $HOME == /tmp/bsi.*/home ]] || { echo "ABORT: HOME is not scratch"; exit 9; }
  [[ $REMUDA_RUNTIME_DIR == /private/tmp/bsi.*/run || $REMUDA_RUNTIME_DIR == /tmp/bsi.*/run ]] \
    || { echo "ABORT: runtime dir is not scratch"; exit 9; }
}
cp "$REGISTRY" "$T/snap/agents-before-empty.jsonl"
empty_guard
REMUDA_BUTLER_SERVER=$EMPTY "$REMUDA_BIN" -s "$EMPTY" daemon </dev/null >"$T/empty.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/.sock ]] && break; sleep 0.1; done
T6=ok
if [[ -S $REMUDA_RUNTIME_DIR/remuda/.sock ]]; then
  empty_guard
  "$REMUDA_BIN" -s "$EMPTY" -e "${FAKE_SECOND}remuda._butler_argv = {'$FAKE_AGENT'}; remuda.exec('butler')" >/dev/null 2>&1 || true
  sleep 4
  empty_guard
  set +e
  OUT=$("$REMUDA_BIN" -s "$EMPTY" butler status 2>&1); CODE=$?
  set -e
  [[ $CODE == 1 && $OUT == *"already running in another Remuda daemon"* ]] \
    || T6="butler status: exit $CODE, output: $(printf '%s' "$OUT" | head -2 | cut -c1-160)"
  empty_guard
  ROOT_IN_EMPTY=$("$REMUDA_BIN" -s "$EMPTY" -e 'for _, s in ipairs(remuda.ls()) do if s.name == "butler" then return true end end return false')
  [[ $ROOT_IN_EMPTY == false ]] || T6="$T6; it has a root Butler session"
  cmp -s "$REGISTRY" "$T/snap/agents-before-empty.jsonl" || T6="$T6; agents.jsonl changed"
elif kill -0 "${PIDS[${#PIDS[@]}-1]}" 2>/dev/null; then
  T6="the empty-name daemon is running but has no socket at remuda/.sock"
fi # else: core refused the empty session name and the daemon exited, which is a pass
[[ $T6 == ok ]] && ok "T6 a daemon with an empty session name is refused too" \
  || bad "T6 a daemon with an empty session name is refused too: ${T6#ok; }"

# T7: a daemon with a DIFFERENT data home but the SAME config path (a scratch
# XDG_DATA_HOME next to the real config) is refused too: config.mcp.json and
# the relay state live beside the config file, not in the data home.
mkdir -p "$T/data2/remuda/mods/butler"
tar -c -C "$REPO" extension.toml packages | tar -x -C "$T/data2/remuda/mods/butler"
cp "$C/config.mcp.json" "$T/snap/config.mcp.json.t7"
[[ ! -f $C/config.since ]] || cp "$C/config.since" "$T/snap/config.since.t7"
assert_scratch
under_scratch "$T/data2" # its config side stays the exported, asserted $T/config
XDG_DATA_HOME=$T/data2 REMUDA_BUTLER_SERVER=$X "$REMUDA_BIN" -s "$X" daemon </dev/null >"$T/$X.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$X.sock ]] && break; sleep 0.1; done
[[ -S $REMUDA_RUNTIME_DIR/remuda/$X.sock ]] || { cat "$T/$X.log"; echo "FAIL: daemon $X did not start"; exit 1; }
load_butler "$X" "$FAKE_OTHER_DATA"
sleep 4
T7=ok
cmp -s "$C/config.mcp.json" "$T/snap/config.mcp.json.t7" || T7="config.mcp.json changed"
if [[ -f $T/snap/config.since.t7 ]]; then
  cmp -s "$C/config.since" "$T/snap/config.since.t7" || T7="$T7; the relay .since file changed"
fi
RELAY_IN_X=$(lua "$X" 'local m = remuda.butler and remuda.butler.matrix; return (m and m.relay and m.relay.instance) ~= nil')
[[ $RELAY_IN_X == false ]] || T7="$T7; it has a relay instance"
ROOT_IN_X=$(lua "$X" 'for _, s in ipairs(remuda.ls()) do if s.name == "butler" then return true end end return false')
[[ $ROOT_IN_X == false ]] || T7="$T7; it has a root Butler session"
assert_scratch
set +e
OUT=$("$REMUDA_BIN" -s "$X" butler status 2>&1); CODE=$?
set -e
[[ $CODE == 1 && $OUT == *"already running in another Remuda daemon"* ]] \
  || T7="$T7; butler status: exit $CODE, output: $(printf '%s' "$OUT" | head -2 | cut -c1-160)"
[[ $T7 == ok ]] && ok "T7 a daemon with the same config path and another data home is refused" \
  || bad "T7 a daemon with the same config path and another data home is refused: ${T7#ok; }"

# T7b: a home with NO Matrix files (every new install) is owned by its first
# daemon: the config lock sits beside the resolved config path, which is known
# even when the config file does not exist.
mkdir -p "$T/local/home" "$T/local/config" "$T/local/data/remuda/mods/butler"
tar -c -C "$REPO" extension.toml packages | tar -x -C "$T/local/data/remuda/mods/butler"
assert_scratch
under_scratch "$T/local/home" "$T/local/config" "$T/local/data"
HOME=$T/local/home XDG_CONFIG_HOME=$T/local/config XDG_DATA_HOME=$T/local/data REMUDA_BUTLER_SERVER=$L \
  "$REMUDA_BIN" -s "$L" daemon </dev/null >"$T/$L.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$L.sock ]] && break; sleep 0.1; done
[[ -S $REMUDA_RUNTIME_DIR/remuda/$L.sock ]] || { cat "$T/$L.log"; echo "FAIL: daemon $L did not start"; exit 1; }
load_butler "$L" "$FAKE_OWNER"
sleep 4
LOCAL_STATE=$(lua "$L" 'local root = false; for _, s in ipairs(remuda.ls()) do if s.name == "butler" then root = true end end
  return "refused=" .. tostring(remuda._butler_standby ~= nil) .. " root_butler=" .. tostring(root)')
# The guard creates the config directory for its lock; Matrix setup later puts
# the token and config there, so it must be private from the start.
LOCAL_CONFIG_MODE=$(ls -ld "$T/local/config/remuda/butler" 2>/dev/null | cut -c1-10)
[[ $LOCAL_CONFIG_MODE == "drwx------" ]] && ok "T7b the config directory the guard creates is private (0700)" \
  || bad "T7b the config directory the guard creates is private (0700): mode is ${LOCAL_CONFIG_MODE:-missing}"
[[ $LOCAL_STATE == "refused=false root_butler=true" ]] && ok "T7b a home with no Matrix files is owned by its first daemon" \
  || bad "T7b a home with no Matrix files is owned by its first daemon: $LOCAL_STATE; $("$REMUDA_BIN" -s "$L" butler status 2>&1 | head -1 | cut -c1-160)"

# T7c (faked word only): the owner is gone -> a refused daemon says so, and the
# command its Next: line prints really makes THIS daemon the owner, once. With
# the real word T8 does the same against a dead owner.
if [[ $LOCK_WORD != true ]]; then
  mkdir -p "$T/gone/home" "$T/gone/config/remuda/butler" "$T/gone/data/remuda/mods/butler"
  tar -c -C "$REPO" extension.toml packages | tar -x -C "$T/gone/data/remuda/mods/butler"
  cp "$C/config" "$C/token" "$T/gone/config/remuda/butler/"
  chmod 600 "$T/gone/config/remuda/butler/config" "$T/gone/config/remuda/butler/token"
  assert_scratch
  under_scratch "$T/gone/home" "$T/gone/config" "$T/gone/data"
  HOME=$T/gone/home XDG_CONFIG_HOME=$T/gone/config XDG_DATA_HOME=$T/gone/data REMUDA_BUTLER_SERVER=$G \
    "$REMUDA_BIN" -s "$G" daemon </dev/null >"$T/$G.log" 2>&1 &
  PIDS+=($!)
  for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$G.sock ]] && break; sleep 0.1; done
  [[ -S $REMUDA_RUNTIME_DIR/remuda/$G.sock ]] || { cat "$T/$G.log"; echo "FAIL: daemon $G did not start"; exit 1; }
  load_butler "$G" "$FAKE_SECOND"
  sleep 2
  lua "$G" "${FAKE_OWNER}return true" >/dev/null # the owner is gone: the locks are free now
  assert_scratch
  set +e
  OUT=$("$REMUDA_BIN" -s "$G" butler status 2>&1); CODE=$?
  set -e
  T7C=ok
  [[ $CODE == 1 && $OUT == *"that owned this home is gone. This daemon has not taken over."* ]] \
    || T7C="butler status: exit $CODE, output: $(printf '%s' "$OUT" | head -2 | cut -c1-160)"
  NEXT_COMMAND=$(printf '%s\n' "$OUT" | sed -n 's/^Next: \(remuda exec butler\).*/\1/p')
  [[ $NEXT_COMMAND == "remuda exec butler" ]] || T7C="$T7C; no reload command in the Next: line"
  [[ $(lua "$G" 'return remuda._butler_standby ~= nil') == true ]] || T7C="$T7C; the daemon took over without being asked"
  assert_scratch
  "$REMUDA_BIN" -s "$G" exec butler >/dev/null 2>&1 || true # the printed command, with this daemon's -s
  sleep 5
  GONE_STATE=$(lua "$G" 'local roots = 0; for _, s in ipairs(remuda.ls()) do if s.name == "butler" then roots = roots + 1 end end
    local m = remuda.butler and remuda.butler.matrix
    return "refused=" .. tostring(remuda._butler_standby ~= nil) .. " root_butlers=" .. roots .. " relay=" .. tostring((m and m.relay and m.relay.instance) ~= nil)')
  [[ $GONE_STATE == "refused=false root_butlers=1 relay=true" ]] || T7C="$T7C; after the printed command: $GONE_STATE"
  [[ -f $T/gone/config/remuda/butler/config.mcp.json ]] || T7C="$T7C; no root MCP config was written"
  # The command entry answers as the Butler now, not with the refusal it gave before.
  assert_scratch
  set +e
  OUT=$("$REMUDA_BIN" -s "$G" butler status 2>&1); CODE=$?
  set -e
  [[ $CODE != 1 && $OUT == "butler: "* ]] || T7C="$T7C; butler status after the takeover: exit $CODE, output: $(printf '%s' "$OUT" | head -1 | cut -c1-120)"
  [[ $T7C == ok ]] && ok "T7c when the owner is gone the printed command makes this daemon the owner" \
    || bad "T7c when the owner is gone the printed command makes this daemon the owner: ${T7C#ok; }"
fi

# T8 and T9 need the owner lock word from core (remuda.fs.lock). Until a core
# has it they are skipped; they have never run.
if [[ $LOCK_WORD == true ]]; then
  # Both lock files and core's .info sidecars exist and are owner-only.
  LOCK_MODES=""
  for file in "$XDG_DATA_HOME/remuda/butler/lock" "$C/config.lock"; do
    for path in "$file" "$file.info"; do
      MODE=$(ls -l "$path" 2>/dev/null | cut -c1-10)
      [[ $MODE == "-rw-------" ]] || LOCK_MODES="$LOCK_MODES ${path#"$T"/}=${MODE:-missing}"
    done
  done
  [[ -z $LOCK_MODES ]] && ok "T8 both lock files and their .info sidecars are private (0600)" \
    || bad "T8 both lock files and their .info sidecars are private (0600):$LOCK_MODES"

  load_butler "$A"
  sleep 1
  set +e
  "$REMUDA_BIN" -s "$A" butler status >/dev/null 2>&1; OWNER_CODE=$?
  "$REMUDA_BIN" -s "$B" butler status >/dev/null 2>&1; SECOND_CODE=$?
  set -e
  [[ $OWNER_CODE != 1 && $SECOND_CODE == 1 ]] && ok "T9 a mod reload in the owner keeps ownership" \
    || bad "T9 a mod reload in the owner keeps ownership: owner exit $OWNER_CODE, second exit $SECOND_CODE"

  kill "${PIDS[0]}" # the owner daemon, started by this script
  for _ in $(seq 50); do kill -0 "${PIDS[0]}" 2>/dev/null || break; sleep 0.1; done
  # A refused daemon re-asks on each verb: it says the owner is gone and does not take over.
  assert_scratch
  set +e
  OUT=$("$REMUDA_BIN" -s "$B" butler status 2>&1); CODE=$?
  set -e
  ROOT_IN_B=$(lua "$B" 'for _, s in ipairs(remuda.ls()) do if s.name == "butler" then return true end end return false')
  [[ $CODE == 1 && $OUT == *"that owned this home is gone"* && $OUT == *"Next: remuda exec butler"* && $ROOT_IN_B == false ]] \
    && ok "T8 after the owner dies a refused daemon says so and does not take over" \
    || bad "T8 after the owner dies a refused daemon says so and does not take over: exit $CODE, root Butler $ROOT_IN_B, output: $(printf '%s' "$OUT" | head -2 | cut -c1-160)"
  # The printed command makes THAT daemon the owner, once: one root Butler, the relay, both locks.
  assert_scratch
  "$REMUDA_BIN" -s "$B" exec butler >/dev/null 2>&1 || true
  sleep 5
  TAKEOVER=$(lua "$B" 'local roots = 0; for _, s in ipairs(remuda.ls()) do if s.name == "butler" then roots = roots + 1 end end
    local m = remuda.butler and remuda.butler.matrix
    return "refused=" .. tostring(remuda._butler_standby ~= nil) .. " root_butlers=" .. roots .. " relay=" .. tostring((m and m.relay and m.relay.instance) ~= nil)')
  set +e
  OUT=$("$REMUDA_BIN" -s "$B" butler status 2>&1); CODE=$?
  set -e
  [[ $TAKEOVER == "refused=false root_butlers=1 relay=true" && $CODE != 1 && $OUT == "butler: "* ]] \
    && ok "T8 the printed command makes the refused daemon the owner" \
    || bad "T8 the printed command makes the refused daemon the owner: $TAKEOVER; butler status exit $CODE: $(printf '%s' "$OUT" | head -1 | cut -c1-120)"
  # ...and a daemon started after that is refused: the new owner holds both locks.
  start_daemon "$D"
  load_butler "$D"
  sleep 4
  ROOT_IN_D=$(lua "$D" 'for _, s in ipairs(remuda.ls()) do if s.name == "butler" then return true end end return false')
  [[ $ROOT_IN_D == false ]] && ok "T8 a daemon started after the takeover is refused" \
    || bad "T8 a daemon started after the takeover is refused: it has a root Butler"
else
  echo "skip - T8 after the owner dies: a refused daemon says so, its printed command takes over, a later daemon is refused (needs core remuda.fs.lock)"
  echo "skip - T9 a mod reload in the owner keeps ownership (needs core remuda.fs.lock)"
fi

((${#FAILED[@]} == 0)) || { echo "FAIL: ${#FAILED[@]} checks"; exit 1; }
echo PASS
