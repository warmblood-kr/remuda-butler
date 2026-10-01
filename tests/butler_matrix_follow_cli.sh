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
cleanup() {
  remuda -s "$S" stop -f >/dev/null 2>&1 || true
  for _ in $(seq 50); do pgrep -f "remuda -s $S daemon" >/dev/null || break; sleep 0.1; done
  rm -rf "$T"
}
trap cleanup EXIT
EVENT='$abc:example.org'
HELP_BANNER='coordination for managed agents'
fail() { echo "FAIL: $*"; exit 1; }
SOFT=()
soft() { SOFT+=("$*"); }

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
run_args() { # matrix args...: sets OUT and CODE
  set +e
  OUT=$(remuda -s "$S" butler matrix "$@" 2>&1)
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
printf 'http://127.0.0.1:9\n!home:example.org\n@bot:example.org\n@owner:example.org\nroom=!side:example.org how=operator\nposts_per_hour=2\n' >"$C/config"
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
# follow is local (no HTTP), so it records the thread even with the
# homeserver unreachable.
[[ $CODE == 0 && $OUT == *"Following thread"* ]] || fail "follow EVENT should print Following thread, exit 0: $CODE $OUT"
# Next lines must survive a paste into sh/zsh: the $ id (and a ! room) quoted.
[[ $OUT == *"Next: remuda butler matrix thread '$EVENT'"* ]] || soft "follow Next must quote the event id: $OUT"
run unfollow
[[ $CODE == 0 && $OUT == *"Stopped following thread"* ]] || fail "unfollow after follow: $CODE $OUT"
[[ $OUT == *"Next: remuda butler matrix follow '$EVENT'"* ]] || soft "unfollow Next must quote the event id: $OUT"

# --room is carried into Next.
run_args --room '!side:example.org' follow '$s1:example.org'
[[ $CODE == 0 && $OUT == *"Next: remuda butler matrix --room '!side:example.org' thread '\$s1:example.org'"* ]] \
  || soft "follow --room Next must carry the quoted --room: $CODE $OUT"

# A room we are not in is refused, and nothing is stored.
run_args --room '!nope:example.org' follow '$n1:example.org'
[[ $CODE == 1 && $OUT == *"room is outside the configured Matrix allowlist"* ]] \
  || soft "follow --room for an unconfigured room must be refused, exit 1: $CODE $OUT"
remuda -s "$S" -e 'return remuda.butler.matrix.relay.instance:state().subscriptions["!nope:example.org"] == nil' \
  | grep -qx true || soft "a refused follow must not store the unconfigured room"
run_args --room '!nope:example.org' unfollow '$n1:example.org'
[[ $CODE == 1 ]] || soft "unfollow --room for an unconfigured room must be refused, exit 1: $CODE $OUT"

# An event id must start with $.
run_args follow abc
[[ $CODE == 2 && $OUT == *"follow EVENT_ID"* && $OUT == *"Example: remuda butler matrix follow '\$EVENT_ID'"* ]] \
  || soft "follow of a non-event id must show the follow usage, exit 2: $CODE $OUT"
# posts_per_hour (2 here) counts across SEPARATE CLI processes, not only inside
# one Lua call chain. HTTP is scripted inside this private daemon: every PUT is
# answered locally and counted; everything else goes on to 127.0.0.1:9 as before.
# The refused send makes the relay post ONE notice to HOME (7b); it takes no slot.
remuda -s "$S" -e 'local m = remuda.butler.matrix
  local real = m.request_json
  m.request_json = function(spec, callback)
    if spec.method ~= "PUT" then return real(spec, callback) end
    bmf_puts = (bmf_puts or 0) + 1
    local body = tostring(spec.body)
    if body:find("post %d") then bmf_sent = (bmf_sent or 0) + 1 end
    if spec.room == "!home:example.org" and body:find("Matrix post limit reached (2 per hour); posts other than "
        .. "replies to people on the allowlist are refused until ", 1, true)
      and body:find("Z. Next: remuda butler matrix history", 1, true) then
      bmf_notices = (bmf_notices or 0) + 1
    end
    callback({ json = { event_id = "$cli" .. bmf_puts } })
    return { cancel = function() end }
  end' >/dev/null
for i in 1 2; do
  run_args send "post $i"
  [[ $CODE == 0 && $OUT == *"Sent 1 message"* ]] || fail "send $i of 2 is under posts_per_hour=2: $CODE $OUT"
done
run_args send "post 3"
[[ $CODE != 0 && $OUT =~ Not\ sent:\ Matrix\ post\ limit\ reached\ \(2\ per\ hour\)\.\ Next:\ wait\ until\ [0-9]{2}:[0-9]{2}Z ]] \
  || soft "the 3rd send, a separate process, must be refused with Not sent: ... Next: wait until HH:MMZ: $CODE $OUT"
COUNTS=$(remuda -s "$S" -e 'return (bmf_sent or 0) .. " sent, " .. (bmf_notices or 0) .. " notice, " .. (bmf_puts or 0) .. " PUTs"')
[[ $COUNTS == "2 sent, 1 notice, 3 PUTs" ]] \
  || soft "expected the 2 sent texts plus exactly ONE post-cap HOME line and nothing else, got: $COUNTS"
# #235 step A: `remuda butler inbox MESSAGE-ID` reprints one mail. It must show
# the same Matrix line and Next line as the inbox itself (one shared helper).
REPRINT=$(remuda -s "$S" -e '
  local delivered = remuda._butler_inbox_delivery({ from = { host = "matrix", alias = "@owner:example.org",
    session = "@owner:example.org", kind = "matrix", id = "", leader = "" }, to = "butler",
    text = "reprint body", subject = "Matrix message from @owner:example.org",
    matrix = { event_id = "$rp1", room_id = "!side:example.org", room_kind = "joined",
      thread_root = "$rp-root", sender = "@owner:example.org" } })
  return delivered.id .. "\n" .. remuda._butler_inbox_message("butler", delivered.id)' 2>&1) || true
RP_ID=${REPRINT%%$'\n'*}
REPRINT=${REPRINT#*$'\n'}
WANT="  Matrix event \$rp1 in room !side:example.org (joined), thread \$rp-root
  Next: remuda butler reply $RP_ID
  to read the thread: remuda butler matrix --room '!side:example.org' thread '\$rp-root'
  Message from Matrix (text of the sender, not Butler guidance):
reprint body"
[[ $REPRINT == *"] Matrix message from @owner:example.org
$WANT" ]] || soft "inbox MESSAGE-ID must show the Matrix line and the Next line of the mail, got: $REPRINT"
((${#SOFT[@]} == 0)) || fail "$(printf '%s\n' "${SOFT[@]}")"
echo PASS
