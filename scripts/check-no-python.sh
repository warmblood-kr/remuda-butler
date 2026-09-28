#!/bin/sh
# Butler is Rust and Lua. Python references below are temporary Matrix/core boundaries.
set -eu
command -v git >/dev/null 2>&1 || { echo 'required tool missing: git' >&2; exit 2; }
command -v grep >/dev/null 2>&1 || { echo 'required tool missing: grep' >&2; exit 2; }
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ALLOWLIST=$ROOT/scripts/no-python-allowlist.txt
[ -f "$ALLOWLIST" ] || { echo 'required allowlist missing: scripts/no-python-allowlist.txt' >&2; exit 2; }
BAD=$(mktemp)
FILES=$(mktemp)
MATCHES=$(mktemp)
trap 'rm -f "$BAD" "$FILES" "$MATCHES"' EXIT HUP INT TERM
(cd "$ROOT" && git ls-files) >"$FILES"

while IFS= read -r path; do
  case "$path" in
    *.py)
      case "$path" in
        packages/butler/matrix_relay.py|tests/support/matrix_stub_server.py) ;;
        *) printf 'new Python file: %s\n' "$path" >>"$BAD" ;;
      esac
      ;;
  esac
done <"$FILES"

while IFS= read -r path; do
  case "$path" in *.py) continue ;; esac
  case "$path" in scripts/check-no-python.sh|scripts/no-python-allowlist.txt) continue ;; esac
  if grep -nIE '(python3?|\.py)' "$ROOT/$path" >"$MATCHES"; then
    while IFS=: read -r line text; do
      allowed=0
      while IFS='|' read -r allowed_path expected_count allowed_text; do
        if [ "$path" = "$allowed_path" ] && [ "$text" = "$allowed_text" ]; then allowed=1; break; fi
      done <"$ALLOWLIST"
      [ "$allowed" -eq 1 ] || printf 'Python reference: %s:%s:%s\n' "$path" "$line" "$text" >>"$BAD"
    done <"$MATCHES"
  else
    status=$?
    [ "$status" -eq 1 ] || { echo "grep failed for tracked file: $path" >&2; exit "$status"; }
  fi
done <"$FILES"

# Keep every exact exemption occurrence pinned, so additions fail closed.
while IFS='|' read -r allowed_path expected_count allowed_text; do
  if count=$(grep -Fxc -- "$allowed_text" "$ROOT/$allowed_path"); then :
  else
    status=$?
    [ "$status" -eq 1 ] || { echo "grep failed while checking $allowed_path" >&2; exit "$status"; }
    count=0
  fi
  [ "$count" -eq "$expected_count" ] || printf 'exemption changed in %s: expected %s exact occurrence(s), found %s: %s\n' "$allowed_path" "$expected_count" "$count" "$allowed_text" >>"$BAD"
done <"$ALLOWLIST"

if [ -s "$BAD" ]; then cat "$BAD" >&2; exit 1; fi
echo 'ok - no non-exempt Python files or invocations'
