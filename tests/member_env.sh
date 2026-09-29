#!/usr/bin/env bash
# Butler-launched sessions must keep Claude transcripts even when the daemon
# inherited CLAUDE_CODE_CHILD_SESSION. Throwaway daemon only.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(cd "$(mktemp -d /tmp/bme.XXXXXX)" && pwd -P); S=bme
export REMUDA_RUNTIME_DIR=$T/run XDG_DATA_HOME=$T/data XDG_CONFIG_HOME=$T/config HOME=$T/home
export REMUDA_BUTLER_PROJECT_HOME=$T/projects CLAUDE_CODE_CHILD_SESSION=1
unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG
mkdir -p "$XDG_DATA_HOME/remuda/mods/butler" "$HOME"
tar -c -C "$REPO" extension.toml packages | tar -x -C "$XDG_DATA_HOME/remuda/mods/butler"
trap 'remuda -s $S stop -f >/dev/null 2>&1 || true; rm -rf "$T"' EXIT
remuda -s "$S" daemon </dev/null >/dev/null 2>&1 &
for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$S.sock ]] && break; sleep 0.1; done
ENV="{'sh', '-c', 'env | grep CLAUDE_CODE_; sleep 1000'}"
remuda -s "$S" -e "remuda._butler_argv = $ENV; remuda.exec('butler')"
for _ in $(seq 50); do
  if remuda -s "$S" -e 'return remuda._butler_agent_builders ~= nil' | grep -qx true; then break; fi
  sleep 0.1
done
remuda -s "$S" -e "remuda._butler_agent_builders.fake = function() return $ENV end
  remuda._butler_launch('fake', 'm1')"
sleep 1
for name in butler m1; do
  remuda -s "$S" -e "return remuda.capture('$name')" | grep -q 'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1' \
    || { echo "FAIL: $name lacks CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1"; exit 1; }
done
echo PASS
