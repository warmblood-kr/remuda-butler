#!/usr/bin/env bash
# reply/forward through the real CLI, as members (caller env), on a private -s.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
SCRATCH=$(mktemp -d /tmp/brf.XXXXXX)
SERVER=brf
export HOME=$SCRATCH/home XDG_CONFIG_HOME=$SCRATCH/config XDG_DATA_HOME=$SCRATCH/data
export REMUDA_RUNTIME_DIR=$SCRATCH/run REMUDA_NO_UPDATE_CHECK=1 REMUDA_BUTLER_PROJECT_HOME=$SCRATCH/projects
unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG REMUDA_BUTLER_AGENT_ID REMUDA_BUTLER_LEADER_ID REMUDA_BUTLER_SESSION_NAME
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/remuda/mods/butler" "$REMUDA_RUNTIME_DIR"
tar -c -C "$REPO" extension.toml packages | tar -x -C "$XDG_DATA_HOME/remuda/mods/butler"

cleanup() {
  "$REMUDA_BIN" -s "$SERVER" stop -f >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
lua() { "$REMUDA_BIN" -s "$SERVER" -e "$1"; }
as() { local id=$1; shift; REMUDA_BUTLER_AGENT_ID=$id "$REMUDA_BIN" -s "$SERVER" butler "$@"; }

"$REMUDA_BIN" -s "$SERVER" daemon >"$SCRATCH/daemon.log" 2>&1 &
for _ in $(seq 50); do
  [[ -S $REMUDA_RUNTIME_DIR/remuda/$SERVER.sock ]] && break
  sleep 0.1
done
[[ -S $REMUDA_RUNTIME_DIR/remuda/$SERVER.sock ]] || { cat "$SCRATCH/daemon.log" >&2; fail "private daemon did not bind"; }

lua 'remuda._butler_argv = {"sleep", "60"}; remuda._butler_skip_relay = true; remuda.exec("butler")' >/dev/null
for _ in $(seq 50); do
  lua 'return remuda._butler_agent_builders ~= nil' | grep -qx true && break
  sleep 0.1
done
lua 'remuda._butler_agent_builders.fake = function() return {"sleep", "60"} end
     remuda._butler_launch("fake", "m1"); remuda._butler_launch("fake", "m2")' >/dev/null
ROOT=$(lua 'return remuda._butler_bus.agents.butler.id')
M1=$(lua 'return remuda._butler_bus.agents.m1.id')
M2=$(lua 'return remuda._butler_bus.agents.m2.id')

SENT=$(as "$ROOT" send m1 "the plan")
ID=$(printf '%s\n' "$SENT" | sed -E 's/^queued ([^ ]+).*/\1/')
[[ $ID == message-* ]] || fail "send did not report an id: $SENT"

as "$M1" forward "$ID" m2 see step 2 | grep -F "m2" >/dev/null || fail "forward did not report its target"
M2_INBOX=$(as "$M2" inbox)
[[ $M2_INBOX == *"[$ID from local/butler "* ]] || fail "forward lost the original sender: $M2_INBOX"
[[ $M2_INBOX == *"forwarded by m1 to m2 at "*": see step 2"* ]] || fail "no forward provenance: $M2_INBOX"
[[ $M2_INBOX == *"the plan"* ]] || fail "forward lost the body: $M2_INBOX"
echo "ok - forward keeps id, sender and body, and says who forwarded it"

if as "$M1" forward "$ID" m2 >"$SCRATCH/again.out" 2>&1; then fail "a second forward to m2 was accepted"; fi
grep -F "already delivered to m2" "$SCRATCH/again.out" >/dev/null || fail "loop guard silent: $(cat "$SCRATCH/again.out")"
echo "ok - a message is delivered to a member at most once"

as "$M2" reply "$ID" on it | grep -F "butler" >/dev/null || fail "reply did not go to the original sender"
ROOT_INBOX=$(as "$ROOT" inbox)
[[ $ROOT_INBOX == *"in reply to $ID (thread $ID)"* && $ROOT_INBOX == *"on it"* ]] || fail "reply not threaded to butler: $ROOT_INBOX"
echo "ok - a reply to forwarded mail reaches the original sender, threaded"

HELP=$("$REMUDA_BIN" -s "$SERVER" butler help 2>&1 || true)
[[ $HELP == *"reply <message-id>"* && $HELP == *"forward <message-id> <member>"* && $HELP == *"original sender"* ]] || \
  fail "help does not explain reply/forward: $HELP"
echo "ok - help says a reply goes to the original sender"

# Authorization (review of #39): no unidentified caller may reply or forward.
component() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
mcp() { printf '%s\n' "$2" | REMUDA_SESSION_CAPABILITY=$1 "$REMUDA_BIN" -s "$SERVER" mcp 2>&1; }
call() { printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2"; }
M1_ROWS="$XDG_DATA_HOME/remuda/butler/mail/inboxes/$(component "$M1").jsonl"
ID2=$(as "$ROOT" send m2 "private" | sed -E 's/^queued ([^ ]+).*/\1/')
for tool in butler_forward butler_reply; do
  OUT=$(mcp "" "$(call "$tool" "$(printf '{"message_id":"%s","to":"m1","text":"x"}' "$ID2")")")
  [[ $OUT == *"unknown caller"* ]] || fail "$tool without a capability was not refused: $OUT"
done
if grep -F "$ID2" "$M1_ROWS" >/dev/null; then fail "an unidentified MCP forward reached m1"; fi
TOK_M2=$(lua 'for t, a in pairs(remuda._butler_bus.tokens) do if a == "m2" then return t end end')
OUT=$(mcp "$TOK_M2" "$(call butler_forward "$(printf '{"message_id":"%s","to":"m1"}' "$ID2")")")
[[ $OUT == *"forwarded $ID2 to m1"* ]] || fail "m2's own MCP forward failed: $OUT"
echo "ok - MCP reply/forward need a known caller; a real member's capability works"

if as 01ZZZZZZZZZZZZZZZZZZZZZZZZ reply "$ID" stale >"$SCRATCH/stale.out" 2>&1; then fail "a stale agent id replied"; fi
grep -Ei "no live Butler agent|unknown caller" "$SCRATCH/stale.out" >/dev/null || fail "stale id not named: $(cat "$SCRATCH/stale.out")"
"$REMUDA_BIN" -s "$SERVER" butler reply "$ID" "operator note" | grep -F butler >/dev/null || fail "plain operator reply failed"
ID3=$(as "$ROOT" send m2 "only m2" | sed -E 's/^queued ([^ ]+).*/\1/')
if as "$M1" forward "$ID3" butler >"$SCRATCH/theft.out" 2>&1; then fail "m1 forwarded mail it never received"; fi
grep -F "not delivered" "$SCRATCH/theft.out" >/dev/null || fail "theft not named: $(cat "$SCRATCH/theft.out")"
echo "ok - CLI: a stale id is refused, the operator still works, members forward only their own mail"
echo PASS
