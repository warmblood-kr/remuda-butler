#!/usr/bin/env bash
# The shadow inbox index must not open a missing active database from mod code,
# even after the marker disappears or the marker state is unknown. The QA owner
# replaces init.lua in a disposable tree, so remuda.db.open runs in mod context.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
REMUDA_BIN=${REMUDA_BIN:-remuda}
CORE_REF=${REMUDA_SQL_CORE_REF:-8dc35489db53c6aebfdf3f5aa1fbd91614b2c281}
source "$REPO/tests/core_ref.sh"
core_ref_check
source "$REPO/tests/lib/isolated_env.sh"
isolated_env_prepare inboxshadow inboxshadow
export REMUDA_NO_UPDATE_CHECK=1
export XDG_STATE_HOME="$T/state"
mkdir -m 700 "$XDG_STATE_HOME"
MOD="$XDG_DATA_HOME/remuda/mods/butler"
mkdir -p "$MOD"
cp "$REPO/extension.toml" "$MOD/extension.toml"
cp -R "$REPO/packages" "$MOD/packages"
cp "$REPO/tests/lib/qa_inbox_shadow_open.lua" "$MOD/packages/butler/init.lua"
root="$XDG_DATA_HOME/remuda/butler/mail"
mkdir -p "$root"
printf 'active\n' > "$root/sqlite-active"
db="$XDG_STATE_HOME/remuda/db/butler/inbox.db"
rm -f "$db" "$db-wal" "$db-shm"
export QA_MAIL_ROOT="$root"

cd "$REPO"
"$REMUDA_BIN" -s "$S" daemon >"$T/daemon.log" 2>&1 &
ISOLATED_DAEMON_PID=$!
for _ in $(seq 50); do
  [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] && break
  sleep 0.1
done
[[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] || { cat "$T/daemon.log" >&2; exit 1; }
isolated_env_check_daemon

out=$("$REMUDA_BIN" -s "$S" exec butler 2>&1 || true)
printf '%s\n' "$out"
for label in active vanished; do
  grep -q "^$label REFUSED " <<<"$out" \
    || { echo "$label: the shadow index did not refuse" >&2; exit 1; }
done
grep -q '^unknown REFUSED ' <<<"$out" \
  || { echo "unknown marker state was not refused" >&2; exit 1; }
grep -Eq 'missing|refusing to create' <<<"$out" \
  || { echo "the refusals do not come from the no-create open" >&2; exit 1; }
[[ ! -e "$db" && ! -e "$db-wal" && ! -e "$db-shm" ]] \
  || { echo "the shadow index created the database" >&2; exit 1; }

"$REMUDA_BIN" -s "$S" stop -f --yes >/dev/null
wait "$ISOLATED_DAEMON_PID" 2>/dev/null || true
ISOLATED_DAEMON_PID=
echo "shadow inbox open after activation/removal: PASS"
