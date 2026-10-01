#!/usr/bin/env bash
# An unknown Butler verb must report failure after printing general usage.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
REMUDA_BIN=$(command -v "$REMUDA_BIN")
S=buv
T=$(mktemp -d /tmp/buv.XXXXXX)
T=$(cd "$T" && pwd -P)
export REMUDA_RUNTIME_DIR=$T/run XDG_DATA_HOME=$T/data XDG_CONFIG_HOME=$T/config HOME=$T/home
export REMUDA_BUTLER_PROJECT_HOME=$T/projects REMUDA_NO_UPDATE_CHECK=1
unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG REMUDA_BUTLER_AGENT_ID REMUDA_BUTLER_LEADER_ID
mkdir -p "$XDG_DATA_HOME/remuda/mods/butler" "$HOME" "$T/bin"
tar -c -C "$REPO" extension.toml packages | tar -x -C "$XDG_DATA_HOME/remuda/mods/butler"
ln -s "$REMUDA_BIN" "$T/bin/remuda"
export PATH="$T/bin:/usr/bin:/bin"
cleanup() {
  remuda -s "$S" stop -f >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

remuda -s "$S" daemon </dev/null >/dev/null 2>&1 &
for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$S.sock ]] && break; sleep 0.1; done
remuda -s "$S" -e "remuda._butler_argv = {'sh', '-c', 'sleep 1000'}; remuda.exec('butler')" >/dev/null

set +e
OUT=$(remuda -s "$S" butler nosuchverb 2>&1)
CODE=$?
set -e
[[ $CODE == 2 ]] || { echo "FAIL: unknown Butler verb should exit 2, got $CODE: $OUT"; exit 1; }
[[ $OUT == *"remuda butler — coordination for managed agents"* ]] \
  || { echo "FAIL: unknown Butler verb omitted usage: $OUT"; exit 1; }
echo "PASS: unknown Butler verb printed usage and exited 2"
