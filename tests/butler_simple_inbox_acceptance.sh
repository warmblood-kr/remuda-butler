#!/usr/bin/env bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
REMUDA_BIN=${REMUDA_BIN:-remuda}
CORE_REF=${REMUDA_SQL_CORE_REF:-66138e39db21c8f7d069589c779bf6ac589f777c}
source "$REPO/tests/core_ref.sh"
core_ref_check
source "$REPO/tests/lib/isolated_env.sh"
isolated_env_prepare bir bir
export REMUDA_NO_UPDATE_CHECK=1
mkdir -p "$XDG_DATA_HOME/remuda/mods/butler" "$XDG_DATA_HOME/remuda/butler/mail"/{inboxes,read,messages,objects}
cp "$REPO/extension.toml" "$XDG_DATA_HOME/remuda/mods/butler/extension.toml"
cp -R "$REPO/packages" "$XDG_DATA_HOME/remuda/mods/butler/packages"
root="$XDG_DATA_HOME/remuda/butler/mail"
printf '%s\n' '{"id":"A","from":{"host":"local","id":"sender","alias":"sender","session":"sender"},"to":[{"host":"local","id":"aa","alias":"aa","session":"aa"}],"subject":"Task","created_at":"2026-11-11","content_type":"text/plain","body":{"object_id":"object-A","bytes":4}}' > "$root/messages/A.json"
printf body > "$root/objects/object-A"
printf '%s\n' '{"message_id":"A"}' > "$root/inboxes/6161.jsonl"
start_daemon() {
  "$REMUDA_BIN" -s "$S" daemon >"$T/daemon.log" 2>&1 &
  ISOLATED_DAEMON_PID=$!
  for _ in $(seq 50); do [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] && break; sleep 0.1; done
  [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] || { cat "$T/daemon.log" >&2; exit 1; }
  isolated_env_check_daemon
  "$REMUDA_BIN" -s "$S" -e 'remuda._butler_argv={"sh","-c","sleep 60"}; remuda._butler_skip_relay=true; return remuda.exec("butler")' >/dev/null
}
start_daemon
"$REMUDA_BIN" -s "$S" -e "remuda._qa_restart_phase=1; return dofile('$REPO/tests/butler_simple_inbox_acceptance.lua')"
"$REMUDA_BIN" -s "$S" stop -f --yes
wait "$ISOLATED_DAEMON_PID" || true
ISOLATED_DAEMON_PID=
start_daemon
"$REMUDA_BIN" -s "$S" -e "remuda._qa_restart_phase=2; return dofile('$REPO/tests/butler_simple_inbox_acceptance.lua')"
"$REMUDA_BIN" -s "$S" stop -f --yes
wait "$ISOLATED_DAEMON_PID" || true
ISOLATED_DAEMON_PID=
start_daemon
"$REMUDA_BIN" -s "$S" -e "remuda._qa_restart_phase=3; return dofile('$REPO/tests/butler_simple_inbox_acceptance.lua')"
"$REMUDA_BIN" -s "$S" stop -f --yes
wait "$ISOLATED_DAEMON_PID" || true
ISOLATED_DAEMON_PID=
"$REMUDA_BIN" -s "$S" daemon >"$T/daemon.log" 2>&1 &
ISOLATED_DAEMON_PID=$!
for _ in $(seq 50); do [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] && break; sleep 0.1; done
isolated_env_check_daemon
"$REMUDA_BIN" -s "$S" -e 'remuda._butler_argv={"sh","-c","sleep 60"}; remuda._butler_skip_relay=true; remuda.db.open=function() return nil,"test failure" end; local ok,err=pcall(remuda.exec,"butler"); assert(not ok and tostring(err):find("SQLite inbox unavailable",1,true),tostring(err)); return "unavailable DB refused"'
