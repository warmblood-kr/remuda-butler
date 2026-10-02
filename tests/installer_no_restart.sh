#!/usr/bin/env bash
# The installer must finish on a core that has no `restart` verb, and must
# never stop or restart the daemon: that ends every session on the machine.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=$(mktemp -d /tmp/butler-installer-no-restart.XXXXXX)
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin" "$SCRATCH/home/.config/remuda/butler"
printf token >"$SCRATCH/home/.config/remuda/butler/token"
printf config >"$SCRATCH/home/.config/remuda/butler/config"
cat >"$SCRATCH/bin/remuda" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$REMUDA_TEST_CALLS"
case "$1" in
  mod|exec|ls) exit 0 ;;
  butler) printf 'ready\n'; exit 0 ;;
  *) printf 'remuda: unknown command: %s\n' "$1" >&2; exit 2 ;;
esac
SH
cat >"$SCRATCH/bin/uname" <<'SH'
#!/bin/sh
printf 'Darwin\n'
SH
for name in launchctl systemctl; do
  cat >"$SCRATCH/bin/$name" <<'SH'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >>"$REMUDA_TEST_CALLS"
SH
done
chmod +x "$SCRATCH/bin/"*
export HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/home/.config"
export PATH="$SCRATCH/bin:/usr/bin:/bin"
export REMUDA_TEST_CALLS="$SCRATCH/calls"
fail() {
  cat "$SCRATCH/out" >&2
  echo "calls:" >&2
  cat "$REMUDA_TEST_CALLS" >&2
  echo "FAIL: $*" >&2
  exit 1
}
sh "$REPO/install/install-butler.sh" >"$SCRATCH/out" 2>&1 || fail "installer exited $?"
if grep -E '^(restart|stop)( |$)' "$REMUDA_TEST_CALLS" >/dev/null; then
  fail "installer stopped or restarted the daemon"
fi
for file in "$HOME/.config/remuda/init.lua" "$HOME/.config/remuda/butler-poll.sh" \
  "$HOME/Library/LaunchAgents"/*.plist; do
  [ -f "$file" ] || fail "installer did not write $file"
done
if grep -F 'after a daemon restart' "$SCRATCH/out" >/dev/null; then
  fail "installer claims a restart check it did not run"
fi
echo "PASS installer finished without stopping or restarting the daemon"
last_line=$(tail -n 1 "$SCRATCH/out")
case "$last_line" in
  Next:*) ;;
  *) fail "installer output does not end with a Next: line" ;;
esac
