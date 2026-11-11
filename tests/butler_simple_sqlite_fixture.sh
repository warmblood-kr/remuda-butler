#!/usr/bin/env bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
REMUDA_BIN=${REMUDA_BIN:-remuda}
source "$REPO/tests/lib/isolated_env.sh"
isolated_env_prepare bis bis
export REMUDA_NO_UPDATE_CHECK=1
export SIMPLE_MAIL_ROOT="$T/mail"
mkdir -p "$XDG_DATA_HOME/remuda/mods/butler" "$SIMPLE_MAIL_ROOT"/{inboxes,read,messages,objects}
cp "$REPO/extension.toml" "$XDG_DATA_HOME/remuda/mods/butler/extension.toml"
cp -R "$REPO/packages" "$XDG_DATA_HOME/remuda/mods/butler/packages"
cp "$REPO/tests/lib/qa_simple_inbox_owner.lua" "$XDG_DATA_HOME/remuda/mods/butler/packages/butler/init.lua"
printf '%s\n' '{"message_id":"B"}' '{"message_id":"A"}' > "$SIMPLE_MAIL_ROOT/inboxes/6161.jsonl"
printf '%s\n' B > "$SIMPLE_MAIL_ROOT/read/6161.jsonl"
printf '%s\n' '{"id":"A","body":{"object_id":"object-A"}}' > "$SIMPLE_MAIL_ROOT/messages/A.json"
printf '%s\n' '{"id":"B","body":{"object_id":"object-B"}}' > "$SIMPLE_MAIL_ROOT/messages/B.json"
printf 'body A' > "$SIMPLE_MAIL_ROOT/objects/object-A"
printf 'body B' > "$SIMPLE_MAIL_ROOT/objects/object-B"
cd "$REPO"
"$REMUDA_BIN" -s "$S" daemon >"$T/daemon.log" 2>&1 &
ISOLATED_DAEMON_PID=$!
for _ in $(seq 50); do [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] && break; sleep 0.1; done
[[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] || { cat "$T/daemon.log" >&2; exit 1; }
isolated_env_check_daemon
"$REMUDA_BIN" -s "$S" exec butler
