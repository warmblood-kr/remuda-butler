#!/usr/bin/env bash
# File arguments from an agent caller: send --file, reply --file and matrix
# upload read, and matrix download writes, only inside the caller's own working
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
printf 'VICTIM\n' >"$T/victim.txt"
mkdir "$T/outdir"
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
mkdir "\$PWD/sub"
ln -s "$T/outdir" "\$PWD/dirlink"
ln -s "$T/victim.txt" "\$PWD/outlink"
run dl_outside remuda -s $S butler matrix -o "$T/pwned.txt" download mxc://media.example/a1
run dl_dirlink remuda -s $S butler matrix -o "\$PWD/dirlink/pwned.txt" download mxc://media.example/a1
run dl_onlink  remuda -s $S butler matrix -o "\$PWD/outlink" download mxc://media.example/a1
run dl_inside  remuda -s $S butler matrix -o "\$PWD/sub/got.bin" download mxc://media.example/a1
run dl_default remuda -s $S butler matrix download mxc://media.example/a1
run reply_dots remuda -s $S butler reply ../../../../victim hello
run fwd_dots   remuda -s $S butler forward ../../../../victim butler
call() { printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "\$1" "\$2"; }
mcp() { name=\$1; shift; call "\$@" | remuda -s $S mcp >"$T/\$name.out" 2>&1; }
mcp mcp_dl      matrix_download '{"mxc":"mxc://media.example/b2"}'
mcp mcp_up_out  matrix_upload "{\\"path\\":\\"$T/secret.txt\\"}"
mcp mcp_up_link matrix_upload "{\\"path\\":\\"\$PWD/link.txt\\"}"
mcp mcp_up_in   matrix_upload "{\\"path\\":\\"\$PWD/in.txt\\"}"
run msend_out remuda -s $S butler matrix send --file "$T/secret.txt"
run msend_in  remuda -s $S butler matrix send --file "\$PWD/in.txt"
run setup      remuda -s $S butler matrix setup --homeserver https://evil.invalid --user @x:evil.invalid --password-file "$T/secret.txt"
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
# Media comes from the repo's fake remuda.http (tests/support/fake_http.lua, the one the
# rust download test uses); its callbacks run on tick, so tick while the member works.
lua "$(cat "$REPO/tests/support/fake_http.lua")" >/dev/null
lua 'remuda.http.respond_prefix("GET", "https://matrix.invalid/_matrix/client/v1/media/download/",
  { status = 200, headers = { ["content-type"] = "application/octet-stream" }, body = "MEDIA-BYTES" })' >/dev/null
lua 'remuda.http.respond_prefix("POST", "https://matrix.invalid/_matrix/media/v3/upload",
  { status = 200, body = [[{"content_uri":"mxc://matrix.invalid/up1"}]] })
remuda.http.respond_prefix("PUT", "https://matrix.invalid/_matrix/client/v3/rooms/",
  { status = 200, body = [[{"event_id":"$mcpup1"}]] })' >/dev/null
touch "$T/go"
for _ in $(seq 300); do [[ -e $T/done ]] && break; lua 'remuda.http.tick()' >/dev/null || true; sleep 0.1; done
[[ -e $T/done ]] || fail "the member script did not finish: $(cat "$T"/*.out 2>/dev/null)"
CWD=$(lua 'return remuda._butler_bus.agents.m1.cwd')
MEMBER_CWD=$(cat "$T/member.cwd")

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

echo "== an agent caller: download -o outside, through a directory link, and onto a link is refused; nothing is written"
for name in dl_outside dl_dirlink; do
  [[ $(cat "$T/$name.rc") != 0 ]] || fail "$name was not refused: $(cat "$T/$name.out")"
  grep -qF "is outside this session's working directory $CWD" "$T/$name.out" || fail "$name: wrong refusal: $(cat "$T/$name.out")"
  grep -qF "Next: pass -o with a path inside $CWD" "$T/$name.out" || fail "$name: no Next: line: $(cat "$T/$name.out")"
done
[[ $(cat "$T/dl_onlink.rc") != 0 ]] || fail "download onto a link was not refused: $(cat "$T/dl_onlink.out")"
grep -qF "is a symlink" "$T/dl_onlink.out" || fail "dl_onlink: wrong refusal: $(cat "$T/dl_onlink.out")"
[[ ! -e $T/pwned.txt && ! -e $T/outdir/pwned.txt ]] || fail "a refused download wrote a file outside"
[[ $(cat "$T/victim.txt") == VICTIM ]] || fail "a refused download changed the link's target"

echo "== an agent caller: download inside is written; without -o it lands in the working directory, not HOME"
[[ $(cat "$T/dl_inside.rc") == 0 ]] || fail "an inside download failed: $(cat "$T/dl_inside.out")"
[[ $(cat "$MEMBER_CWD/sub/got.bin") == MEDIA-BYTES ]] || fail "the inside download has the wrong content"
[[ $(cat "$T/dl_default.rc") == 0 ]] || fail "a download without -o failed: $(cat "$T/dl_default.out")"
[[ $(cat "$MEMBER_CWD/matrix-a1") == MEDIA-BYTES ]] || fail "the default output is not in the working directory"
[[ ! -e $HOME/matrix-a1 ]] || fail "the default output of an agent caller landed in HOME"

echo "== MCP: matrix_download writes into the working directory and returns the absolute path"
grep -qF "Downloaded 11 bytes to $MEMBER_CWD/matrix-b2" "$T/mcp_dl.out" || fail "matrix_download: $(cat "$T/mcp_dl.out")"
[[ $(cat "$MEMBER_CWD/matrix-b2") == MEDIA-BYTES ]] || fail "matrix_download wrote the wrong content"

echo "== MCP: matrix_upload outside or through a link is refused; inside returns the event id"
for name in mcp_up_out mcp_up_link; do
  grep -qF '"isError":true' "$T/$name.out" || fail "$name was not refused: $(cat "$T/$name.out")"
  grep -qF "is outside this session's working directory $CWD" "$T/$name.out" || fail "$name: wrong refusal: $(cat "$T/$name.out")"
done
grep -qF '$mcpup1' "$T/mcp_up_in.out" || fail "matrix_upload inside: $(cat "$T/mcp_up_in.out")"
[[ $(lua 'local n = 0; for _, call in ipairs(remuda.http.calls) do if call.method == "POST" and tostring(call.body):find("TOP-SECRET", 1, true) then n = n + 1 end end; return n') == 0 ]] \
  || fail "a refused matrix_upload sent the outside file"

echo "== an agent caller: matrix send --file outside is refused and posts nothing; inside is posted"
[[ $(cat "$T/msend_out.rc") != 0 ]] || fail "matrix send --file outside was not refused: $(cat "$T/msend_out.out")"
grep -qF "is outside this session's working directory $CWD" "$T/msend_out.out" || fail "msend_out: wrong refusal: $(cat "$T/msend_out.out")"
[[ $(cat "$T/msend_in.rc") == 0 ]] || fail "matrix send --file inside failed: $(cat "$T/msend_in.out")"
[[ $(lua 'local n = 0; for _, call in ipairs(remuda.http.calls) do if tostring(call.body):find("TOP-SECRET", 1, true) then n = n + 1 end end; return n') == 0 ]] \
  || fail "a refused matrix send --file posted the outside file"
[[ $(lua 'local n = 0; for _, call in ipairs(remuda.http.calls) do if call.method == "PUT" and tostring(call.body):find("INSIDE-BODY", 1, true) then n = n + 1 end end; return n') == 1 ]] \
  || fail "matrix send --file inside did not post the file text once"

echo "== an agent caller: a message id with a path in it never becomes a file name"
for name in reply_dots fwd_dots; do
  [[ $(cat "$T/$name.rc") != 0 ]] || fail "$name: a bad message id was accepted: $(cat "$T/$name.out")"
done

echo "== an agent caller: matrix setup is refused and makes no request"
[[ $(cat "$T/setup.rc") != 0 ]] || fail "matrix setup from a session was not refused: $(cat "$T/setup.out")"
grep -qF "matrix setup is operator-only" "$T/setup.out" || fail "setup: wrong refusal: $(cat "$T/setup.out")"
grep -qF "Next: run remuda butler matrix setup from your own terminal" "$T/setup.out" || fail "setup: no Next: line: $(cat "$T/setup.out")"
[[ $(lua 'local n = 0; for _, call in ipairs(remuda.http.calls) do if tostring(call.url):find("evil.invalid", 1, true) then n = n + 1 end end; return n') == 0 ]] \
  || fail "a refused matrix setup made a request to the server it named"

echo "== nothing was read from a refused path"
INBOX=$(REMUDA_BUTLER_AGENT_ID=butler remuda -s "$S" butler inbox butler 2>&1)
grep -qF "INSIDE-BODY" <<<"$INBOX" || fail "the inside file did not arrive: $INBOX"
grep -qF "TOP-SECRET-OUTSIDE" <<<"$INBOX" && fail "a refused file reached the Butler inbox"

echo "== a caller at a terminal is not restricted"
remuda -s "$S" butler send m1 --file "$T/secret.txt" >"$T/terminal.out" 2>&1 || fail "a terminal caller was refused: $(cat "$T/terminal.out")"
remuda -s "$S" butler inbox m1 2>&1 | grep -qF "TOP-SECRET-OUTSIDE" || fail "the terminal caller's file did not arrive"
remuda -s "$S" butler matrix -o "$T/terminal.bin" download mxc://media.example/a1 >"$T/terminal-dl.out" 2>&1 &
DL=$!
for _ in $(seq 100); do kill -0 "$DL" 2>/dev/null || break; lua 'remuda.http.tick()' >/dev/null || true; sleep 0.1; done
wait "$DL" || fail "a terminal caller's download failed: $(cat "$T/terminal-dl.out")"
[[ $(cat "$T/terminal.bin") == MEDIA-BYTES ]] || fail "the terminal caller's download was not written where it asked"
remuda -s "$S" butler matrix setup --help >"$T/terminal-setup.out" 2>&1 || fail "a terminal caller's matrix setup --help failed"
grep -qF "remuda butler matrix setup" "$T/terminal-setup.out" || fail "a terminal caller did not get the setup usage"
echo "butler_file_args.sh ok"
