#!/usr/bin/env bash
# follow/unfollow through the daemon CLI entry (`remuda butler matrix ...`), not
# matrix.cli directly: the verb must reach the Matrix CLI, and an unconfigured
# Matrix gives setup guidance with exit 1. Throwaway daemon only; the
# homeserver is 127.0.0.1:9, so nothing leaves the machine.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d /tmp/bmf.XXXXXX)
T=$(cd "$T" && pwd -P); S=bmf
export REMUDA_RUNTIME_DIR=$T/run XDG_DATA_HOME=$T/data XDG_CONFIG_HOME=$T/config HOME=$T/home
export REMUDA_BUTLER_PROJECT_HOME=$T/projects REMUDA_NO_UPDATE_CHECK=1
unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG
mkdir -p "$XDG_DATA_HOME/remuda/mods/butler" "$HOME"
tar -c -C "$REPO" extension.toml packages | tar -x -C "$XDG_DATA_HOME/remuda/mods/butler"
trap 'remuda -s $S stop -f >/dev/null 2>&1 || true; rm -rf "$T"' EXIT
EVENT='$abc:example.org'
HELP_BANNER='coordination for managed agents'
fail() { echo "FAIL: $*"; exit 1; }

start_butler() {
  remuda -s "$S" daemon </dev/null >/dev/null 2>&1 &
  for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$S.sock ]] && break; sleep 0.1; done
  remuda -s "$S" -e "remuda._butler_argv = {'sh', '-c', 'sleep 1000'}; remuda.exec('butler')" >/dev/null
  for _ in $(seq 50); do
    if remuda -s "$S" -e 'return remuda._butler_agent_builders ~= nil' | grep -qx true; then return; fi
    sleep 0.1
  done
  fail "butler did not load"
}

run() { # verb: sets OUT and CODE
  set +e
  OUT=$(remuda -s "$S" butler matrix "$1" "$EVENT" 2>&1)
  CODE=$?
  set -e
}

# 1. Unconfigured: setup guidance, exit 1, never the general help.
start_butler
for verb in follow unfollow; do
  run "$verb"
  [[ $OUT != *"$HELP_BANNER"* ]] || fail "unconfigured $verb printed the general butler help"
  [[ $CODE == 1 ]] || fail "unconfigured $verb should exit 1, got $CODE"
  [[ $OUT == *"Next: remuda butler matrix setup"* ]] || fail "unconfigured $verb lacks setup guidance: $OUT"
done
remuda -s "$S" stop -f >/dev/null 2>&1 || true
for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$S.sock ]] || break; sleep 0.1; done

# 2. Configured (relay running): the verb reaches the Matrix CLI.
C=$XDG_CONFIG_HOME/remuda/butler
mkdir -p "$C"
printf 'http://127.0.0.1:9\n!home:example.org\n@bot:example.org\n@owner:example.org\n' >"$C/config"
printf 'token\n' >"$C/token"
chmod 600 "$C/config" "$C/token"
start_butler
for _ in $(seq 50); do
  if remuda -s "$S" -e 'return remuda.butler.matrix.relay.instance ~= nil' | grep -qx true; then break; fi
  sleep 0.1
done
remuda -s "$S" -e 'return remuda.butler.matrix.relay.instance ~= nil' | grep -qx true || fail "Matrix relay did not start"

run unfollow
[[ $OUT != *"$HELP_BANNER"* ]] || fail "unfollow EVENT printed the general butler help"
[[ $CODE == 0 && $OUT == *"Not following"* ]] || fail "unfollow of an unknown thread should print Not following, exit 0: $CODE $OUT"
run follow
[[ $OUT != *"$HELP_BANNER"* ]] || fail "follow EVENT printed the general butler help"
# The homeserver is unreachable, so follow either records the thread or
# reports the transport error; both prove it reached the Matrix CLI.
[[ $OUT == *"Following thread"* || $OUT == *"HTTP transport error"* ]] || fail "follow EVENT did not reach the Matrix CLI: $CODE $OUT"
if [[ $OUT == *"Following thread"* ]]; then
  run unfollow
  [[ $CODE == 0 && $OUT == *"Stopped following thread"* ]] || fail "unfollow after follow: $CODE $OUT"
fi
echo PASS
