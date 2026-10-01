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
A=bsi-a B=bsi-b D=bsi-d
export HOME=$T/home XDG_CONFIG_HOME=$T/config XDG_DATA_HOME=$T/data REMUDA_RUNTIME_DIR=$T/run
export REMUDA_BUTLER_PROJECT_HOME=$T/projects REMUDA_NO_UPDATE_CHECK=1
unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG REMUDA_BUTLER_AGENT_ID REMUDA_BUTLER_LEADER_ID
unset REMUDA_SERVER REMUDA_BUTLER_SERVER XDG_RUNTIME_DIR
# Hard rule: every remuda call below runs only with HOME and the runtime dir
# under the scratch dir and two private, non-empty session names.
assert_scratch() {
  [[ $T == /tmp/bsi.?????? || $T == /private/tmp/bsi.?????? ]] || { echo "ABORT: scratch dir is wrong: $T"; exit 9; }
  [[ $HOME == "$T/home" && $REMUDA_RUNTIME_DIR == "$T/run" && $XDG_DATA_HOME == "$T/data"
    && $XDG_CONFIG_HOME == "$T/config" ]] || { echo "ABORT: env is not scratch"; exit 9; }
  [[ $A == bsi-a && $B == bsi-b && $D == bsi-d ]] || { echo "ABORT: session names"; exit 9; }
}
assert_scratch

PIDS=()
FAKE_AGENT=$T/fake-agent
cleanup() {
  STATUS=$?
  assert_scratch
  for name in "$A" "$B" "$D"; do
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
load_butler() { # session name
  lua "$1" "remuda._butler_argv = {'$FAKE_AGENT'}; remuda.exec('butler')" >/dev/null 2>&1 || true
}

# The owner: daemon A with the root Butler, one live member and the relay.
start_daemon "$A"
load_butler "$A"
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
sleep 3 # let the owner's reconcile settle before the snapshot
mkdir "$T/snap"
cp "$REGISTRY" "$T/snap/agents.jsonl"
cp "$C/config.mcp.json" "$T/snap/config.mcp.json"
[[ ! -f $C/config.status.settings.json ]] || cp "$C/config.status.settings.json" "$T/snap/settings.json"

# The second daemon on the same home loads the mod.
start_daemon "$B"
load_butler "$B"
sleep 4 # longer than the 2 s reconcile schedule that would launch a root Butler

FAILED=()
bad() { FAILED+=("$*"); echo "not ok - $*"; }
ok() { echo "ok - $*"; }

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

# T6 and T7 need the owner lock word from core (remuda.fs.lock). Until a core
# has it they are skipped; they have never run.
if [[ $(lua "$A" 'return remuda.fs ~= nil and type(remuda.fs.lock) == "function"') == true ]]; then
  load_butler "$A"
  sleep 1
  set +e
  "$REMUDA_BIN" -s "$A" butler status >/dev/null 2>&1; OWNER_CODE=$?
  "$REMUDA_BIN" -s "$B" butler status >/dev/null 2>&1; SECOND_CODE=$?
  set -e
  [[ $OWNER_CODE != 1 && $SECOND_CODE == 1 ]] && ok "T7 a mod reload in the owner keeps ownership" \
    || bad "T7 a mod reload in the owner keeps ownership: owner exit $OWNER_CODE, second exit $SECOND_CODE"

  kill "${PIDS[0]}" # the owner daemon, started by this script
  for _ in $(seq 50); do kill -0 "${PIDS[0]}" 2>/dev/null || break; sleep 0.1; done
  start_daemon "$D"
  load_butler "$D"
  sleep 4
  ROOT_IN_D=$(lua "$D" 'for _, s in ipairs(remuda.ls()) do if s.name == "butler" then return true end end return false')
  [[ $ROOT_IN_D == true ]] && ok "T6 after the owner dies the next daemon takes over" \
    || bad "T6 after the owner dies the next daemon takes over: no root Butler in the new daemon"
else
  echo "skip - T6 after the owner dies the next daemon takes over (needs core remuda.fs.lock)"
  echo "skip - T7 a mod reload in the owner keeps ownership (needs core remuda.fs.lock)"
fi

((${#FAILED[@]} == 0)) || { echo "FAIL: ${#FAILED[@]} checks"; exit 1; }
echo PASS
