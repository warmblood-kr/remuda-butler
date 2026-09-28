#!/bin/sh
# Butler is Rust and Lua. Exact exceptions are the M2 Matrix files/references
# and the pending Claude statusLine/core #213 boundary decision.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BAD=$(mktemp)
MATCHES=$(mktemp)
trap 'rm -f "$BAD" "$MATCHES"' EXIT HUP INT TERM

(cd "$ROOT" && rg --no-config --files --hidden -g '*.py' -g '!/.git/**' || true) >"$MATCHES"
while IFS= read -r path; do
  case "$path" in
    packages/butler/matrix_relay.py|tests/support/matrix_stub_server.py) ;;
    *) printf 'new Python file: %s\n' "$path" >>"$BAD" ;;
  esac
done <"$MATCHES"

(cd "$ROOT" && rg --no-config --files --hidden -g '!/.git/**' -g '!*.py' | while IFS= read -r path; do
  case "$path" in scripts/check-no-python.sh) continue ;; esac
  rg --no-config -nI '(python3?|\.py)' "$path" 2>/dev/null | sed "s#^#$path:#" || true
done) >"$MATCHES"

while IFS=: read -r path line text; do
  case "$path:$line:$text" in
    # TODO M2: remove Matrix relay files and all direct Matrix references.
    README.md:*matrix_relay.py*|README.md:*check-no-python.sh*|packages/butler/matrix.lua:*matrix_relay.py*|packages/butler/matrix.lua:*python3*|tests/rust_tests.sh:*matrix_stub_server.py*|tests/rust_tests.sh:*Python\ exception*|tests/butler_daemon.rs:*matrix_relay.py*|tests/butler_daemon.rs:*_butler_helper_src*|tests/butler_daemon.rs:*tests/support/matrix_stub_server.py*|.github/workflows/tests.yml:*check-no-python.sh*) ;;
    tests/butler_daemon.rs:2029:*Command*new*python3*|tests/butler_daemon.rs:2648:*Command*new*python3*|tests/butler_daemon.rs:2683:*Command*new*python3*) ;;
    # Matrix's Bash reply helper remains in M2 scope.
    packages/butler/main.lua:*BODY_JSON*python3*|packages/butler/main.lua:*ENC_ROOM*python3*) ;;
    # TODO core #213: remove the statusLine helper exemption after its boundary decision.
    packages/butler/main.lua:*TODO\ core\ #213*|packages/butler/main.lua:*helper_path*\.py*|packages/butler/main.lua:*python3*shell_quote\(helper_path\)*) ;;
    # TODO core #213: these two tests exercise the pending statusLine helper.
    tests/butler_mcp.rs:111:*python3*|tests/butler_mcp.rs:147:*python3*) ;;
    tests/support/matrix_stub_server.py:*) ;;
    *) printf 'Python reference: %s:%s:%s\n' "$path" "$line" "$text" >>"$BAD" ;;
  esac
done <"$MATCHES"

if [ -s "$BAD" ]; then
  cat "$BAD" >&2
  exit 1
fi
echo 'ok - no non-exempt Python files or invocations'
