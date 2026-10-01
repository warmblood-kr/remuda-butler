#!/usr/bin/env bash
# #201: a real Codex TUI member reads and reports its Butler mail over the
# remuda MCP server (butler_inbox, butler_report) on a throwaway daemon; the
# `remuda butler` CLI cannot reach the daemon from inside Codex's sandbox.
# Opt-in: it needs a Codex login and spends model tokens, and the core must
# forward `-c KEY=VALUE`. Checked on Linux only (it reads /proc). Run:
#   REMUDA_BUTLER_LIVE_CODEX=1 REMUDA_BIN=/path/to/remuda bash tests/codex_mcp_mail.sh
set -euo pipefail
[[ ${REMUDA_BUTLER_LIVE_CODEX:-} == 1 ]] || { echo "SKIP: REMUDA_BUTLER_LIVE_CODEX=1 is not set"; exit 0; }
command -v codex >/dev/null || { echo "SKIP: codex is not on PATH"; exit 0; }

REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=$(command -v "${REMUDA_BIN:-remuda}") || { echo "SKIP: no remuda binary"; exit 0; }
T=$(mktemp -d /tmp/bcm.XXXXXX)
T=$(cd "$T" && pwd -P); S=bcm
export CODEX_HOME=${CODEX_HOME:-$HOME/.codex} # the real login, resolved before HOME moves
# Isolate before the first remuda call: nothing here may reach a live daemon.
unset $(compgen -e | grep '^REMUDA_' | grep -vx REMUDA_BIN)
export HOME=$T/home XDG_CONFIG_HOME=$T/config XDG_DATA_HOME=$T/data REMUDA_RUNTIME_DIR=$T/run
export REMUDA_BUTLER_PROJECT_HOME=$T/projects REMUDA_BUTLER_SERVER=$S REMUDA_NO_UPDATE_CHECK=1
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$REMUDA_RUNTIME_DIR" "$T/bin" "$T/projects" "$XDG_DATA_HOME/remuda/mods/butler"
trap 'remuda -s $S stop -f >/dev/null 2>&1 || true; rm -rf "$T"' EXIT
# The member, the mod's probe and the MCP server all run this one binary.
cp "$REMUDA_BIN" "$T/bin/remuda"
export PATH=$T/bin:$PATH
[[ $(remuda _codex_tui --help 2>&1 || true) == *'-c KEY=VALUE'* ]] ||
  { echo "SKIP: this core's _codex_tui does not forward -c KEY=VALUE"; exit 0; }
tar -c -C "$REPO" extension.toml packages | tar -x -C "$XDG_DATA_HOME/remuda/mods/butler"

R() { remuda -s "$S" "$@"; }
screen() { R -e "return remuda.capture('cm1')" 2>/dev/null || true; }
fail() { echo "FAIL: $*"; screen | grep -v '^[[:space:]]*$' | tail -25; exit 1; }
wait_for() { # seconds command...
  for _ in $(seq "$1"); do "${@:2}" && return 0; sleep 1; done
  return 1
}
shows() { screen | grep -qF "$1"; }
# The member's `codex app-server`: a child of the scratch daemon carrying the MCP config.
has_mcp_argv() {
  local pid
  for pid in $(pgrep -f 'codex.*app-server' || true); do
    grep -qzxF "REMUDA_RUNTIME_DIR=$T/run" "/proc/$pid/environ" 2>/dev/null &&
      grep -qaF 'mcp_servers.remuda.command' "/proc/$pid/cmdline" && return 0
  done
  return 1
}
# Envelopes live in mail/messages; the body text is a file in mail/objects.
reported() { grep -rqF codex-mcp-ok "$XDG_DATA_HOME/remuda/butler/mail/objects" 2>/dev/null; }

R daemon </dev/null >"$T/daemon.log" 2>&1 &
wait_for 10 test -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" || { cat "$T/daemon.log"; echo "FAIL: scratch daemon did not bind"; exit 1; }
R -e "remuda._butler_argv = {'sleep', '100000'}; remuda.exec('butler')" >/dev/null
wait_for 10 eval "R -e 'return remuda._butler_agent_builders ~= nil' | grep -qx true" || fail "butler mod did not load"
R -e "return remuda._butler_launch('codex', 'cm1')" >/dev/null

wait_for 30 has_mcp_argv || fail "codex app-server was not launched with mcp_servers.remuda.command"
# The welcome notice arrives by itself and names MCP butler_inbox.
wait_for 120 shows 'Called remuda.butler_inbox' || fail "member did not call butler_inbox over MCP"
R send cm1 'Report "codex-mcp-ok" to your leader.'
wait_for 120 reported || fail "no mail with codex-mcp-ok reached the scratch mail store"
wait_for 20 shows 'Called remuda.butler_report' || fail "screen does not show the butler_report MCP call"
echo PASS
