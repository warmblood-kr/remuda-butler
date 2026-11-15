#!/usr/bin/env bash
# Real-SQLite test for the shadow relay intake module.
#
# The product packages are copied to a disposable mod tree, then init.lua is
# replaced by a QA owner. The module opens distinct disposable relay DBs; no
# real relay database, Matrix event or send path is used.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
REMUDA_BIN=${REMUDA_BIN:-remuda}
CORE_REF=${REMUDA_SQL_CORE_REF:-b713e3e31a5f04e9812d19742984fe4c4c05fe1f}
source "$REPO/tests/core_ref.sh"
core_ref_check
source "$REPO/tests/lib/isolated_env.sh"
isolated_env_prepare relayintake relayintake
export REMUDA_NO_UPDATE_CHECK=1
mkdir -p "$XDG_DATA_HOME/remuda/mods/butler"
cp "$REPO/extension.toml" "$XDG_DATA_HOME/remuda/mods/butler/extension.toml"
cp -R "$REPO/packages" "$XDG_DATA_HOME/remuda/mods/butler/packages"
cp "$XDG_DATA_HOME/remuda/mods/butler/packages/butler/init.lua" "$T/product-init.lua"
cp "$REPO/tests/lib/qa_relay_intake_owner.lua" \
  "$XDG_DATA_HOME/remuda/mods/butler/packages/butler/init.lua"

cd "$REPO"
start_daemon() {
  "$REMUDA_BIN" -s "$S" daemon >"$T/daemon.log" 2>&1 &
  ISOLATED_DAEMON_PID=$!
  for _ in $(seq 50); do
    [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] && break
    sleep 0.1
  done
  [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] || { cat "$T/daemon.log" >&2; exit 1; }
  isolated_env_check_daemon
}
stop_daemon() {
  "$REMUDA_BIN" -s "$S" stop -f --yes
  wait "$ISOLATED_DAEMON_PID" || true
  ISOLATED_DAEMON_PID=
}
start_daemon

out=$("$REMUDA_BIN" -s "$S" exec butler 2>&1)
printf '%s\n' "$out"
[[ $(grep -c '^ok - ' <<<"$out") -eq 6 ]] \
  || { echo "expected 6 intake cases to pass" >&2; exit 1; }

# The QA owner replaces init.lua, so also boot the real product init and prove
# the module loads and reports shadow status without the replacement.
stop_daemon
cp "$T/product-init.lua" "$XDG_DATA_HOME/remuda/mods/butler/packages/butler/init.lua"
start_daemon
"$REMUDA_BIN" -s "$S" -e 'remuda._butler_argv={"sh","-c","sleep 60"}; remuda._butler_skip_relay=true; return remuda.exec("butler")' >/dev/null
boot=$("$REMUDA_BIN" -s "$S" -e 'local m=remuda._butler_relay_intake; local s=m and m.status(); print(s and s.available and "intake-ok" or ("intake-failed " .. tostring(s and s.reason)))')
[[ $boot == "intake-ok" ]] || { echo "product boot did not load intake: $boot" >&2; exit 1; }
echo "product boot: intake loaded (shadow)"

echo "shadow relay intake module: PASS"
