#!/usr/bin/env bash
# File arguments from an agent caller: send --file, reply --file and matrix
# upload take only a path that resolves inside the caller's own working
# directory; a caller at a terminal is not restricted. Private daemon; the
# member is a real session that runs the CLI itself, so core's caller identity
# and the real `realpath` are the ones under test.
#   REMUDA_BIN=~/.local/bin/remuda tests/butler_file_args.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
REMUDA_BIN=$(command -v "$REMUDA_BIN")
# /tmp, not $TMPDIR: the daemon socket path must stay under the 103-byte sun_path limit (#163).
T=$(mktemp -d /tmp/bfa.XXXXXX)
T=$(cd "$T" && pwd -P); S=bfa
export REMUDA_RUNTIME_DIR=$T/run XDG_DATA_HOME=$T/data XDG_CONFIG_HOME=$T/config HOME=$T/home
export REMUDA_BUTLER_PROJECT_HOME=$T/projects REMUDA_NO_UPDATE_CHECK=1
unset REMUDA_SERVER REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG REMUDA_BUTLER_AGENT_ID REMUDA_BUTLER_LEADER_ID \
  REMUDA_BUTLER_SESSION_NAME REMUDA_BUTLER_AGENT_ALIAS REMUDA_BUTLER_AGENT_KIND REMUDA_SESSION_CAPABILITY
mkdir -p "$XDG_DATA_HOME/remuda/mods/butler" "$HOME" "$T/bin"
tar -c -C "$REPO" extension.toml packages | tar -x -C "$XDG_DATA_HOME/remuda/mods/butler"
ln -s "$REMUDA_BIN" "$T/bin/remuda"
export PATH="$T/bin:/usr/bin:/bin"
cleanup() {
  if [[ ${REMUDA_RUNTIME_DIR:-} == "$T/run" ]]; then remuda -s "$S" stop -f >/dev/null 2>&1 || true; fi
  rm -rf "$T"
}
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
echo "core $(remuda --version 2>/dev/null | tail -1) ($REMUDA_BIN)"

printf 'TOP-SECRET-OUTSIDE\n' >"$T/secret.txt"
# Matrix must look configured for `matrix upload` to reach the path check. The host is
# under .invalid, which never resolves; a refused upload makes no request at all.
mkdir -p "$XDG_CONFIG_HOME/remuda/butler"
printf 'not-a-real-token\n' >"$XDG_CONFIG_HOME/remuda/butler/token"
printf '%s\n' 'https://matrix.invalid' '!room:matrix.invalid' '@butler:matrix.invalid' '@owner:matrix.invalid' \
  >"$XDG_CONFIG_HOME/remuda/butler/config"
chmod 600 "$XDG_CONFIG_HOME/remuda/butler/token" "$XDG_CONFIG_HOME/remuda/butler/config"
# The member: waits for the go file, then runs the CLI from inside its own session.
cat >"$T/member.sh" <<MEMBER
#!/bin/sh
while [ ! -e "$T/go" ]; do sleep 0.1; done
run() { name=\$1; shift; "\$@" >"$T/\$name.out" 2>&1; echo \$? >"$T/\$name.rc"; }
printf 'INSIDE-BODY\n' >"\$PWD/in.txt"
ln -s "$T/secret.txt" "\$PWD/link.txt"
pwd -P >"$T/member.cwd"
run inside   remuda -s $S butler send butler --file "\$PWD/in.txt"
run outside  remuda -s $S butler send butler --file "$T/secret.txt"
run symlink  remuda -s $S butler send butler --file "\$PWD/link.txt"
run dotdot   remuda -s $S butler send butler --file "\$PWD/../../../../../secret.txt"
run leader   remuda -s $S butler send-to-leader --file "$T/secret.txt"
run blanked  env REMUDA_BUTLER_AGENT_ID= REMUDA_BUTLER_SESSION_NAME= remuda -s $S butler send butler --file "$T/secret.txt"
run upload   remuda -s $S butler matrix upload "$T/secret.txt"
run uplink   remuda -s $S butler matrix upload "\$PWD/link.txt"
touch "$T/done"
sleep 1000
MEMBER
chmod +x "$T/member.sh"

remuda -s "$S" daemon </dev/null >"$T/daemon.log" 2>&1 &
for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$S.sock ]] && break; sleep 0.1; done
lua() { remuda -s "$S" -e "$1" 2>&1; }
lua "remuda._butler_argv = {'sleep', '1000'}; remuda.exec('butler')" >/dev/null
for _ in $(seq 100); do lua 'return remuda._butler_agent_builders ~= nil' | grep -qx true && break; sleep 0.1; done
lua "remuda._butler_agent_builders.fake = function() return {'$T/member.sh'} end; remuda._butler_launch('fake', 'm1')" >/dev/null
for _ in $(seq 300); do lua 'return remuda._butler_bus.agents.m1 ~= nil' | grep -qx true && break; sleep 0.1; done
lua 'return remuda._butler_bus.agents.m1 ~= nil' | grep -qx true || fail "member m1 was not registered"
touch "$T/go"
for _ in $(seq 300); do [[ -e $T/done ]] && break; sleep 0.1; done
[[ -e $T/done ]] || fail "the member script did not finish: $(cat "$T"/*.out 2>/dev/null)"
CWD=$(lua 'return remuda._butler_bus.agents.m1.cwd')

echo "== an agent caller: a file inside its working directory is sent"
[[ $(cat "$T/inside.rc") == 0 ]] || fail "an inside file was refused: $(cat "$T/inside.out")"

echo "== an agent caller: outside, symlink, '..', send-to-leader and a blanked identity are refused"
for name in outside symlink dotdot leader blanked; do
  [[ $(cat "$T/$name.rc") != 0 ]] || fail "$name was not refused: $(cat "$T/$name.out")"
  grep -qF "is outside this session's working directory $CWD" "$T/$name.out" || fail "$name: wrong refusal: $(cat "$T/$name.out")"
  grep -qF "Next: copy the file into $CWD and pass that path, or pipe the text: cat FILE | remuda butler send NAME -" "$T/$name.out" \
    || fail "$name: no Next: line: $(cat "$T/$name.out")"
done
grep -qF "refused: --file $T/secret.txt is outside" "$T/outside.out" || fail "the refusal does not name the path: $(cat "$T/outside.out")"

echo "== an agent caller: matrix upload outside is refused before anything else"
for name in upload uplink; do
  [[ $(cat "$T/$name.rc") != 0 ]] || fail "$name was not refused: $(cat "$T/$name.out")"
  grep -qF "is outside this session's working directory $CWD" "$T/$name.out" || fail "$name: wrong refusal: $(cat "$T/$name.out")"
  grep -qF "Next: copy the file into $CWD and pass that path" "$T/$name.out" || fail "$name: no Next: line"
  grep -qF "pipe the text" "$T/$name.out" && fail "$name: the upload refusal offers a pipe"
done

echo "== nothing was read from a refused path"
INBOX=$(REMUDA_BUTLER_AGENT_ID=butler remuda -s "$S" butler inbox butler 2>&1)
grep -qF "INSIDE-BODY" <<<"$INBOX" || fail "the inside file did not arrive: $INBOX"
grep -qF "TOP-SECRET-OUTSIDE" <<<"$INBOX" && fail "a refused file reached the Butler inbox"

echo "== a caller at a terminal is not restricted"
remuda -s "$S" butler send m1 --file "$T/secret.txt" >"$T/terminal.out" 2>&1 || fail "a terminal caller was refused: $(cat "$T/terminal.out")"
remuda -s "$S" butler inbox m1 2>&1 | grep -qF "TOP-SECRET-OUTSIDE" || fail "the terminal caller's file did not arrive"
echo "butler_file_args.sh ok"
