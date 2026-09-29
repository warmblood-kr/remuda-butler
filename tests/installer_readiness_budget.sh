#!/usr/bin/env bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=$(cd "$(mktemp -d /tmp/butler-installer-budget.XXXXXX)" && pwd -P)
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin" "$SCRATCH/home/.config/remuda/butler"
printf token >"$SCRATCH/home/.config/remuda/butler/token"
printf config >"$SCRATCH/home/.config/remuda/butler/config"
cat >"$SCRATCH/bin/remuda" <<'SH'
#!/bin/sh
case "$1" in
  mod|exec) exit 0 ;;
  butler)
    count_file=${REMUDA_TEST_STATUS_COUNT:?}
    count=0
    [ ! -f "$count_file" ] || read -r count <"$count_file"
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$count" -le 60 ]; then
      printf 'launching\nreadiness budget: 45\n' >&2
      exit 75
    fi
    printf 'failed\nclaude: timeout\ncodex: timeout\n' >&2
    exit 1
    ;;
  *) exit 0 ;;
esac
SH
cat >"$SCRATCH/bin/sleep" <<'SH'
#!/bin/sh
exit 0
SH
cat >"$SCRATCH/bin/uname" <<'SH'
#!/bin/sh
printf 'Linux\n'
SH
chmod +x "$SCRATCH/bin/"*
export HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/home/.config"
export PATH="$SCRATCH/bin:/usr/bin:/bin"
export REMUDA_TEST_STATUS_COUNT="$SCRATCH/status-count"
export REMUDA_BUTLER_AGENT_ORDER=claude,codex REMUDA_BUTLER_READINESS_TIMEOUT=15
if sh "$REPO/install/install-butler.sh" >"$SCRATCH/out" 2>&1; then
  echo "FAIL: installer unexpectedly accepted a failed two-candidate chain" >&2
  exit 1
fi
grep -F 'claude: timeout' "$SCRATCH/out" >/dev/null || {
  cat "$SCRATCH/out" >&2
  echo "FAIL: installer stopped before reporting the first candidate timeout" >&2
  exit 1
}
grep -F 'codex: timeout' "$SCRATCH/out" >/dev/null || {
  cat "$SCRATCH/out" >&2
  echo "FAIL: installer stopped before reporting the second candidate timeout" >&2
  exit 1
}
if grep -F 'did not become ready within 30 seconds' "$SCRATCH/out" >/dev/null; then
  cat "$SCRATCH/out" >&2
  echo "FAIL: installer used its old fixed 30-second deadline" >&2
  exit 1
fi
count=$(cat "$REMUDA_TEST_STATUS_COUNT")
[[ "$count" -gt 60 ]] || { echo "FAIL: installer polled only $count times" >&2; exit 1; }
echo "PASS installer waited for both readiness timeouts ($count status polls)"
