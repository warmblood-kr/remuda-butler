#!/usr/bin/env bash
# DESIGN §7 step 2: verbs and member guidance are contribution points, so an
# extension adds a verb or a guidance section without patching main.lua. Uses
# core's registry when it has remuda.contribute (remuda#141), else Butler's own.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
SCRATCH=$(mktemp -d /tmp/bsm.XXXXXX)
SCRATCH=$(cd "$SCRATCH" && pwd -P)
SERVER=bsm
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

"$REMUDA_BIN" -s "$SERVER" daemon >"$SCRATCH/daemon.log" 2>&1 &
for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$SERVER.sock ]] && break; sleep 0.1; done
lua 'remuda._butler_argv = {"sleep", "60"}; remuda._butler_skip_relay = true; remuda.exec("butler")' >/dev/null
for _ in $(seq 50); do lua 'return remuda._butler_agent_builders ~= nil' | grep -qx true && break; sleep 0.1; done
echo "registry: $(lua 'return remuda.contribute and "core" or "butler-local"')"

lua 'remuda._butler_contribute("butler.command", "hello", { verb = "hello", order = 85,
       usage = "  remuda butler hello <name>", run = function(args) return "hello " .. args[2] end })
     remuda._butler_contribute("butler.guidance", "extra", { order = 35,
       agents_md = function(ctx) return "EXTRA for " .. ctx.parent .. "\n\n" end,
       prompt = function(ctx) return "" end })' >/dev/null

[[ $("$REMUDA_BIN" -s "$SERVER" butler hello pat) == "hello pat" ]] || fail "a contributed verb did not dispatch"
HELP=$("$REMUDA_BIN" -s "$SERVER" butler help)
printf '%s\n' "$HELP" | grep -A1 -F 'remuda butler forward <message-id>' | grep -F 'remuda butler hello <name>' >/dev/null ||
  fail "help does not list the contributed verb by its order: $HELP"
echo "ok - a contributed verb dispatches and is listed in help by its order"

lua 'remuda._butler_agent_builders.fake = function() return {"sleep", "60"} end; remuda._butler_launch("fake", "w1")' >/dev/null
AGENTS=$(cat "$XDG_DATA_HOME/remuda/butler/sessions/w1/AGENTS.md")
[[ $AGENTS == *"On such a core,"*"EXTRA for butler"*"You may create a Remuda-managed child team"* ]] ||
  fail "the contributed guidance section is missing or out of order: $AGENTS"
echo "ok - a contributed guidance section lands in a new member's AGENTS.md by its order"
echo PASS
