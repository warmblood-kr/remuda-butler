#!/bin/sh
# Remaining language-boundary references are listed with their owner and TODO.
set -eu
command -v git >/dev/null 2>&1 || { echo 'required tool missing: git' >&2; exit 2; }
command -v grep >/dev/null 2>&1 || { echo 'required tool missing: grep' >&2; exit 2; }
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
blocked=py'thon'
extension_dot=.
file_suffix=${extension_dot}py
allow_name=no-${blocked}-allowlist.txt
ALLOWLIST=$ROOT/scripts/$allow_name
allow_path=scripts/$allow_name
[ -f "$ALLOWLIST" ] || { echo 'required reference allowlist missing' >&2; exit 2; }
pattern="${blocked}3?|[.]py"
BAD=$(mktemp)
FILES=$(mktemp)
MATCHES=$(mktemp)
trap 'rm -f "$BAD" "$FILES" "$MATCHES"' EXIT HUP INT TERM
(cd "$ROOT" && git ls-files) >"$FILES"

while IFS= read -r path; do
  case "$path" in
    *"$file_suffix")
      case "$path" in
        packages/butler/matrix_relay"$file_suffix"|tests/support/matrix_stub_server"$file_suffix") ;;
        *) printf 'new prohibited source file: %s\n' "$path" >>"$BAD" ;;
      esac
      ;;
  esac
done <"$FILES"

while IFS= read -r path; do
  case "$path" in *"$file_suffix") continue ;; esac
  if grep -nIiE "$pattern" "$ROOT/$path" >"$MATCHES"; then
    while IFS=: read -r line text; do
      allowed=0
      while IFS='|' read -r allowed_path expected_count owner allowed_text; do
        if [ "$path" = "$allow_path" ]; then
          entry="$allowed_path|$expected_count|$owner|$allowed_text"
          case "$owner" in *" TODO:"*) ;; *) continue ;; esac
          [ "$text" = "$entry" ] && { allowed=1; break; }
        elif [ "$path" = "$allowed_path" ] && [ "$text" = "$allowed_text" ]; then
          allowed=1
          break
        fi
      done <"$ALLOWLIST"
      [ "$allowed" -eq 1 ] || printf 'prohibited reference: %s:%s:%s\n' "$path" "$line" "$text" >>"$BAD"
    done <"$MATCHES"
  else
    status=$?
    [ "$status" -eq 1 ] || { echo "grep failed for tracked file: $path" >&2; exit "$status"; }
  fi
done <"$FILES"

valid_owner() {
  case "$1" in
    "M2 TODO:"*|"core #213 TODO:"*|"CI TODO:"*|"DOCS TODO:"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Pin exact exception text and ownership; additions need an explicit reviewed entry.
while IFS='|' read -r allowed_path expected_count owner allowed_text; do
  case "$expected_count" in ''|*[!0-9]*) printf 'invalid occurrence count for %s\n' "$allowed_path" >>"$BAD"; continue ;; esac
  valid_owner "$owner" || { printf 'missing owner/TODO for %s: %s\n' "$allowed_path" "$allowed_text" >>"$BAD"; continue; }
  if count=$(grep -Fxc -- "$allowed_text" "$ROOT/$allowed_path"); then :
  else
    status=$?
    [ "$status" -eq 1 ] || { echo "grep failed while checking an allowlist entry" >&2; exit "$status"; }
    count=0
  fi
  [ "$count" -eq "$expected_count" ] || printf 'exemption changed in %s: expected %s exact occurrence(s), found %s: %s\n' "$allowed_path" "$expected_count" "$count" "$allowed_text" >>"$BAD"
done <"$ALLOWLIST"

if [ -s "$BAD" ]; then cat "$BAD" >&2; exit 1; fi
echo 'ok - no unapproved language-boundary references'
