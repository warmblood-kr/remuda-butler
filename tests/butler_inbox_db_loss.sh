#!/usr/bin/env bash
# An active sqlite-active marker with a missing inbox database must fail closed
# before remuda.db.open creates a new empty database. The same run first proves
# that a fresh installation (no marker) still initializes normally, including a
# genuinely empty inbox across a restart: the guard tests only file existence,
# never a row count.
#
# Not covered here: WAL-only loss (the main database still exists), a valid
# empty database replacing the original, and rollback. Those need separate
# identity/generation design; this test must not be read as solving them.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
REMUDA_BIN=${REMUDA_BIN:-remuda}
CORE_REF=${REMUDA_SQL_CORE_REF:-b713e3e31a5f04e9812d19742984fe4c4c05fe1f}
source "$REPO/tests/core_ref.sh"
core_ref_check
source "$REPO/tests/lib/isolated_env.sh"
isolated_env_prepare idl idl
export REMUDA_NO_UPDATE_CHECK=1
# Core's db root follows XDG_STATE_HOME; use it so the guard's XDG branch is
# exercised, not only the $HOME/.local/state fallback covered by the unit test.
export XDG_STATE_HOME="$T/state"
mkdir -m 700 "$XDG_STATE_HOME"
mkdir -p "$XDG_DATA_HOME/remuda/mods/butler" "$XDG_DATA_HOME/remuda/butler/mail"/{inboxes,read,messages,objects}
cp "$REPO/extension.toml" "$XDG_DATA_HOME/remuda/mods/butler/extension.toml"
cp -R "$REPO/packages" "$XDG_DATA_HOME/remuda/mods/butler/packages"
root="$XDG_DATA_HOME/remuda/butler/mail"
db_dir="$XDG_STATE_HOME/remuda/db/butler"
db="$db_dir/inbox.db"
start_daemon() {
  "$REMUDA_BIN" -s "$S" daemon >"$T/daemon.log" 2>&1 &
  ISOLATED_DAEMON_PID=$!
  for _ in $(seq 50); do [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] && break; sleep 0.1; done
  [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] || { cat "$T/daemon.log" >&2; exit 1; }
  isolated_env_check_daemon
}
stop_daemon() {
  "$REMUDA_BIN" -s "$S" stop -f --yes
  wait "$ISOLATED_DAEMON_PID" || true
  ISOLATED_DAEMON_PID=
}
load_butler() {
  "$REMUDA_BIN" -s "$S" -e 'remuda._butler_argv={"sh","-c","sleep 60"}; remuda._butler_skip_relay=true; return remuda.exec("butler")' >/dev/null
}
attempt_load() {
  "$REMUDA_BIN" -s "$S" -e 'local ok,err=pcall(remuda.exec,"butler"); if ok then return "LOADED" end; return "REFUSED "..tostring(err)' 2>&1 || true
}

# Fresh installation with no legacy mail: the one-time import activates an
# empty SQLite inbox and writes the marker.
start_daemon
load_butler
"$REMUDA_BIN" -s "$S" -e 'assert(remuda._butler_simple_inbox, "fresh install did not activate SQLite inbox"); assert(remuda._butler_mail.unread("aa")==0, "fresh inbox should be empty")'
[[ -f "$db" ]]
[[ $(cat "$root/sqlite-active") == active ]]
stop_daemon

# A real empty inbox is valid: restart accepts the existing empty database and
# does not infer loss from a zero row count.
start_daemon
load_butler
"$REMUDA_BIN" -s "$S" -e 'assert(remuda._butler_simple_inbox, "empty inbox did not restart"); assert(remuda._butler_mail.unread("aa")==0, "empty inbox gained mail")'
# Queue one message so the loss below has retained content files.
id=$("$REMUDA_BIN" -s "$S" -e 'local m=remuda._butler_mail; local s={host="local",id="sender",alias="sender",session="sender"}; local r={host="local",id="aa",alias="aa",session="aa"}; local msg,e=m.queue(s,r,"retained body"); if not msg then error(e) end; print(msg.id)')
[[ -n "$id" ]]
[[ -f "$root/messages/$id.json" && -f "$root/objects/object-$id" ]]
stop_daemon

# Marked active, database and sidecars gone. No automatic recovery or guess:
# the next load must refuse before creating anything.
rm -f "$db" "$db-wal" "$db-shm"
[[ ! -e "$db" && ! -e "$db-wal" && ! -e "$db-shm" ]]
start_daemon
out=$(attempt_load)
[[ $out == "REFUSED "* ]] || { echo "expected refusal, got: $out" >&2; exit 1; }
[[ $out == *"SQLite inbox unavailable"* ]] || { echo "refusal lacks cause: $out" >&2; exit 1; }
[[ $out == *"sqlite-active marker is set but the inbox database is missing at"* ]] \
  || { echo "refusal lacks the marker/database detail: $out" >&2; exit 1; }
[[ $out == *"$db"* ]] || { echo "refusal does not name the database path: $out" >&2; exit 1; }
[[ $out == *"did not open or create the database"* ]] \
  || { echo "refusal does not limit its no-change claim: $out" >&2; exit 1; }
[[ $out != *"LOADED"* ]]
[[ ! -e "$db" && ! -e "$db-wal" && ! -e "$db-shm" ]] \
  || { echo "refusal created a database or sidecar" >&2; exit 1; }
[[ $(cat "$root/sqlite-active") == active ]]
[[ -f "$root/messages/$id.json" && -f "$root/objects/object-$id" ]]

# The guard is stable: a second attempt refuses again and still creates nothing.
out=$(attempt_load)
[[ $out == "REFUSED "* && $out == *"inbox database is missing"* ]] \
  || { echo "second refusal differed: $out" >&2; exit 1; }
[[ ! -e "$db" && ! -e "$db-wal" && ! -e "$db-shm" ]]

# A marker check that cannot answer is not "no marker": fail closed before any
# open instead of falling back to a fresh import.
out=$("$REMUDA_BIN" -s "$S" -e 'local fs=remuda.fs; local real=fs.realpath; fs.realpath=function(path) if path:find("sqlite-active",1,true) then return nil,"denied: test" end return real(path) end; local ok,err=pcall(remuda.exec,"butler"); fs.realpath=real; if ok then return "LOADED" end; return "MARKER-REFUSED "..tostring(err)' 2>&1 || true)
[[ $out == "MARKER-REFUSED "* && $out == *"cannot check the inbox marker"* ]] \
  || { echo "indeterminate marker was not refused: $out" >&2; exit 1; }
[[ ! -e "$db" && ! -e "$db-wal" && ! -e "$db-shm" ]]
stop_daemon
echo "active marker with missing database refused before creation"
