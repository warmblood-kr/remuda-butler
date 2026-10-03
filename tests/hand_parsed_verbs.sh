#!/usr/bin/env bash
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
ALLOWLIST=${HAND_PARSED_ALLOWLIST:-$REPO/tests/hand_parsed_verbs.txt}
MATRIX=$REPO/packages/butler/matrix_cli.lua
COMMANDS=${1:-$REPO/packages/butler/commands.lua}

check() {
  local commands=$1 tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  local -a discovered=()
  local verb
  while IFS= read -r verb; do
    [[ -z $verb || $verb == \#* ]] && continue
    if ! grep -Fqx -- "$verb" <<'SEED'
agents
approve
approve-text
approvals
close
deny
doctor
forward
guard
help
inbox
launch
matrix download
matrix event
matrix follow
matrix get
matrix history
matrix join
matrix leave
matrix quarantine
matrix react
matrix redact
matrix reply
matrix rooms
matrix send
matrix setup
matrix status
matrix unfollow
matrix upload
quota
reply
schedule
send
send-to-leader
sessions
shell-lines
status
status-hook
status-commands
statusline
topic delegate
topic new
typed-lines
SEED
    then
      echo "allowlist entry '$verb' was not in the initial set; the list may only shrink" >&2
      return 1
    fi
  done < "$ALLOWLIST"

  while IFS= read -r verb; do
    [[ -z $verb ]] && continue
    case $verb in
      matrix) continue ;;
      topic)
        while IFS= read -r leaf; do
          [[ -z $leaf ]] || discovered+=("topic $leaf")
        done < <(awk '
          index($0, "command(") == 1 && index($0, "\"topic\"") { in_topic=1 }
          in_topic && index($0, "command(") == 1 && !index($0, "\"topic\"") { exit }
          in_topic && $0 ~ /args\[2\] ==/ {
            value=$0; sub(/^.*== "/, "", value); sub(/".*$/, "", value); print value
          }
        ' "$commands")
        ;;
      *) discovered+=("$verb") ;;
    esac
  done < <(sed -nE 's/^command\([^,]+, "([^"]+)".*/\1/p' "$commands")

  while IFS= read -r leaf; do
    [[ -z $leaf || $leaf == thread ]] || discovered+=("matrix $leaf")
  done < <(awk '
    /local VERBS = \{/ { in_verbs=1 }
    in_verbs && / = true/ {
      line=$0
      while (match(line, /[a-z-]+ = true/)) {
        item=substr(line, RSTART, RLENGTH); sub(/ = true$/, "", item); print item
        line=substr(line, RSTART + RLENGTH)
      }
    }
    in_verbs && /^}/ { exit }
  ' "$MATRIX")
  discovered+=("matrix setup" statusline status-hook help)
  printf '%s\n' "${discovered[@]}" > "$tmp/discovered"

  # A new command declaration is accepted only when it opts into the core parser itself.
  awk '
    /^command\(/ {
      if (verb != "" && parsed) print verb
      verb=""; parsed=0; uses_cli=0
      if (match($0, /"[^"]+"/)) { verb=substr($0, RSTART+1, RLENGTH-2) }
    }
    verb != "" && /remuda\.cli/ { uses_cli=1 }
    verb != "" && /cli\.parse/ && uses_cli { parsed=1 }
    END { if (verb != "" && parsed) print verb }
  ' "$commands" > "$tmp/migrated"
  while IFS=$'\t' read -r verb parsed; do
    [[ -z $verb || $verb == matrix ]] && continue
    if [[ $verb == topic ]]; then continue; fi
    if grep -Fqx -- "$verb" "$ALLOWLIST"; then
      if [[ $parsed == yes ]]; then
        echo "allowlist entry '$verb' is migrated; remove it (the list may only shrink)" >&2
        return 1
      fi
    elif [[ $parsed != yes ]]; then
      echo "new verbs must use remuda.cli.parse; see docs: '$verb' is not allowlisted" >&2
      return 1
    fi
  done < <(awk '
    /^command\(/ {
      if (verb != "") print verb "\t" (parsed ? "yes" : "no")
      verb=""; parsed=0; uses_cli=0
      if (match($0, /"[^"]+"/)) { verb=substr($0, RSTART+1, RLENGTH-2) }
    }
    verb != "" && /remuda\.cli/ { uses_cli=1 }
    verb != "" && /cli\.parse/ && uses_cli { parsed=1 }
    END { if (verb != "") print verb "\t" (parsed ? "yes" : "no") }
  ' "$commands")

  for verb in "${discovered[@]}"; do
    if ! grep -Fqx -- "$verb" "$ALLOWLIST" && ! grep -Fqx -- "$verb" "$tmp/migrated"; then
      echo "new verbs must use remuda.cli.parse; see docs: '$verb' is not allowlisted" >&2
      return 1
    fi
  done
  while IFS= read -r verb; do
    [[ -z $verb || $verb == \#* ]] && continue
    if ! grep -Fqx -- "$verb" "$tmp/discovered"; then
      echo "allowlist entry '$verb' no longer names a hand-parsed verb; remove it (the list may only shrink)" >&2
      return 1
    fi
  done < "$ALLOWLIST"
}

if [[ ${1:-} == --check ]]; then
  check "${2:-$REPO/packages/butler/commands.lua}"
  exit
fi

check "$COMMANDS"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$REPO/packages/butler/commands.lua" "$tmp/commands.lua"

expect_failure() {
  local expected=$1 commands=$2 allowlist=${3:-$ALLOWLIST}
  if HAND_PARSED_ALLOWLIST="$allowlist" bash "$0" --check "$commands" >"$tmp/out" 2>&1; then
    echo "freeze check unexpectedly passed: $expected" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" "$tmp/out"; then
    cat "$tmp/out" >&2
    echo "freeze check failed without '$expected'" >&2
    exit 1
  fi
}

printf '\ncommand(999, "fake-hand", "usage", function() end)\n' >> "$tmp/commands.lua"
expect_failure 'new verbs must use remuda.cli.parse; see docs' "$tmp/commands.lua"
cp "$REPO/packages/butler/commands.lua" "$tmp/commands.lua"
printf '\ncommand(999, "fake-migrated", "usage", function() local cli = remuda.cli; cli.parse({}, {}) end)\n' >> "$tmp/commands.lua"
HAND_PARSED_ALLOWLIST="$ALLOWLIST" bash "$0" --check "$tmp/commands.lua"

cp "$REPO/packages/butler/commands.lua" "$tmp/commands.lua"
awk '
  /^command\(5, "doctor"/ { doctor=1 }
  doctor && /^end\)/ { print "  local cli = remuda.cli; cli.parse({}, {})"; doctor=0 }
  { print }
' "$tmp/commands.lua" > "$tmp/edited.lua"
expect_failure "allowlist entry 'doctor' is migrated" "$tmp/edited.lua"
grep -Fvx 'doctor' "$ALLOWLIST" > "$tmp/allowlist.txt"
expect_failure "new verbs must use remuda.cli.parse; see docs: 'doctor'" "$REPO/packages/butler/commands.lua" "$tmp/allowlist.txt"
echo "hand-parsed verb freeze: PASS (four coverage cases)"
