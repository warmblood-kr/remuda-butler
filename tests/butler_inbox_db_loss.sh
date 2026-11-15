#!/usr/bin/env bash
# An active sqlite-active marker with a missing inbox database must fail closed
# before remuda.db.open creates a new empty database. The same run first proves
# that a fresh installation (no marker) still initializes normally, including a
# genuinely empty inbox across a restart: the guard tests only file existence,
# never a row count. On a core that reports must_exist, the active open also
# refuses a database deleted after the metadata check (the check/open race). On
# a core without that report, an active inbox refuses to open at all: an
# unknown open option is ignored there, so the pre-check alone cannot fail
# closed.
#
# Not covered here: WAL-only loss (the main database still exists), a valid
# empty database replacing the original, and rollback. Those need separate
# identity/generation design; this test must not be read as solving them.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
REMUDA_BIN=${REMUDA_BIN:-remuda}
CORE_REF=${REMUDA_SQL_CORE_REF:-8dc35489db53c6aebfdf3f5aa1fbd91614b2c281}
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
# What the core reports, and what the mod actually used, for an active inbox.
core_protection() {
  "$REMUDA_BIN" -s "$S" -e 'local c=type(remuda.db)=="table" and type(remuda.db.capabilities)=="function" and remuda.db.capabilities(); return (c and c.must_exist==true) and "must_exist" or "precheck"' 2>/dev/null
}
inbox_protection() {
  "$REMUDA_BIN" -s "$S" -e 'return remuda._butler_inbox_open and remuda._butler_inbox_open.status().protection or "missing"' 2>/dev/null
}
inbox_active() {
  "$REMUDA_BIN" -s "$S" -e 'local s=remuda._butler_inbox_open and remuda._butler_inbox_open.status(); return s and s.active and "yes" or "no"' 2>/dev/null
}

# Fresh installation with no legacy mail: the one-time import activates an
# empty SQLite inbox and writes the marker.
start_daemon
load_butler
"$REMUDA_BIN" -s "$S" -e 'assert(remuda._butler_simple_inbox, "fresh install did not activate SQLite inbox"); assert(remuda._butler_mail.unread("aa")==0, "fresh inbox should be empty")'
[[ -f "$db" ]]
[[ $(cat "$root/sqlite-active") == active ]]
# A fresh install created the database and then latched active; the successful
# create (including on a core without must_exist) is the compatibility proof.
[[ $(inbox_active) == yes ]] \
  || { echo "a fresh install did not reach the active state" >&2; exit 1; }
protection=$(core_protection)
stop_daemon

# An active inbox on a core without must_exist must refuse to open: an unknown
# option is ignored there, so the pre-check alone cannot fail closed.
if [[ $protection != must_exist ]]; then
  start_daemon
  out=$(attempt_load)
  [[ $out == "REFUSED "* ]] \
    || { echo "an active inbox on an unsupported core was not refused: $out" >&2; exit 1; }
  [[ $out == *"does not report remuda.db.capabilities().must_exist"* ]] \
    || { echo "the refusal does not name the missing capability: $out" >&2; exit 1; }
  [[ $out == *"Upgrade remuda"* ]] \
    || { echo "the refusal does not tell the operator to upgrade: $out" >&2; exit 1; }
  [[ $out == *"not opened or created"* ]] \
    || { echo "the refusal overclaims its no-change scope: $out" >&2; exit 1; }
  [[ $out != *LOADED* ]]
  [[ -f "$db" ]] || { echo "the refused active open removed the database" >&2; exit 1; }
  [[ $(cat "$root/sqlite-active") == active ]]
  stop_daemon
  echo "active marker on a core without must_exist refused before open"
  exit 0
fi

# A real empty inbox is valid: restart accepts the existing empty database and
# does not infer loss from a zero row count.
start_daemon
load_butler
"$REMUDA_BIN" -s "$S" -e 'assert(remuda._butler_simple_inbox, "empty inbox did not restart"); assert(remuda._butler_mail.unread("aa")==0, "empty inbox gained mail")'
# The active restart uses the core's stronger open when it reports the option;
# on an older core it keeps the metadata pre-check and says so.
protection=$(core_protection)
[[ $(inbox_protection) == "$protection" ]] \
  || { echo "active inbox protection ($(inbox_protection)) disagrees with the core ($protection)" >&2; exit 1; }
# Once this process has seen the marker, losing it must not re-enable the
# create path. Run the same metadata check the next boot would run.
rm -f "$root/sqlite-active"
latched=$("$REMUDA_BIN" -s "$S" -e "local path='$root/sqlite-active'; local state, why = remuda._butler_inbox_db_path.path_state(remuda.fs, path, io.open); remuda._butler_inbox_open.observe(state, why); remuda._butler_argv={\"sh\",\"-c\",\"sleep 60\"}; remuda._butler_skip_relay=true; local ok, err = pcall(remuda.exec, 'butler'); if not ok then return 'REEXEC-FAILED ' .. tostring(err) end; local options, refusal = remuda._butler_inbox_open.prepare(remuda.db); return tostring(remuda._butler_inbox_open.status().active) .. ' ' .. tostring(options and options.must_exist) .. ' ' .. tostring(refusal)" 2>&1 || true)
[[ $latched == "true true nil" ]] \
  || { echo "a vanished marker downgraded the open decision: $latched" >&2; exit 1; }
printf 'active\n' > "$root/sqlite-active"
# Queue one message so the loss below has retained content files.
id=$("$REMUDA_BIN" -s "$S" -e 'local m=remuda._butler_mail; local s={host="local",id="sender",alias="sender",session="sender"}; local r={host="local",id="aa",alias="aa",session="aa"}; local msg,e=m.queue(s,r,"retained body"); if not msg then error(e) end; print(msg.id)')
[[ -n "$id" ]]
[[ -f "$root/messages/$id.json" && -f "$root/objects/object-$id" ]]
stop_daemon

# Keep a stopped-daemon copy so the race case below can start from a real
# database. This is a disposable fixture, not a live-backup recipe.
cp "$db" "$T/race.db"
if [[ -f "$db-wal" ]]; then cp "$db-wal" "$T/race.db-wal"; else rm -f "$T/race.db-wal"; fi

# The check/open race: delete the database after the mod's metadata pre-check
# but before the core opens it. On a core that reports must_exist the open
# refuses and creates nothing; an older core ignores the option, so this case
# is skipped and the weaker pre-check is reported instead.
if [[ $protection == must_exist ]]; then
  start_daemon
  race=$("$REMUDA_BIN" -s "$S" -e "local path='$db'; local open=remuda.db.open; remuda.db.open=function(name,opts) if name=='inbox' then os.remove(path) end return open(name,opts) end; remuda._butler_argv={\"sh\",\"-c\",\"sleep 60\"}; remuda._butler_skip_relay=true; local ok,err=pcall(remuda.exec,'butler'); remuda.db.open=open; if ok then return 'LOADED' end; return 'RACE-REFUSED '..tostring(err)" 2>&1 || true)
  [[ $race == RACE-REFUSED* ]] \
    || { echo "must_exist did not refuse the deleted database: $race" >&2; exit 1; }
  [[ $race == *"refusing to create"* ]] \
    || { echo "the race refusal did not come from the core no-create open: $race" >&2; exit 1; }
  [[ $race != *LOADED* ]]
  [[ ! -e "$db" ]] || { echo "the race open recreated the database" >&2; exit 1; }
  echo "check/open race refused by must_exist; no database created"
  stop_daemon
  cp "$T/race.db" "$db"
  if [[ -f "$T/race.db-wal" ]]; then cp "$T/race.db-wal" "$db-wal"; else rm -f "$db-wal"; fi
  rm -f "$db-shm"
else
  echo "skip: this core does not report must_exist; the race stays pre-check only"
fi

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
