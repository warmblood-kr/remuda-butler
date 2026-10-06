#!/usr/bin/env bash
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
ALLOWLIST=${HAND_PARSED_ALLOWLIST:-$REPO/tests/hand_parsed_verbs.txt}
MATRIX=$REPO/packages/butler/matrix_cli.lua
COMMANDS=${1:-$REPO/packages/butler/commands.lua}
INIT=$REPO/packages/butler/init.lua

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
approvals
approve
approve-text
close
compact
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
matrix mark-all
matrix quarantine
matrix react
matrix redact
matrix reply
matrix rooms
matrix send
matrix setup
matrix status
matrix thread
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
status-commands
status-hook
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

  # Matrix leaves: bare keys (`status = true`) and quoted keys (`["mark-all"] = true`).
  while IFS= read -r leaf; do
    [[ -z $leaf ]] || discovered+=("matrix $leaf")
  done < <(awk '
    /local VERBS = \{/ { in_verbs=1 }
    in_verbs && / = true/ {
      line=$0
      while (match(line, /(\["[a-z-]+"\]|[a-z-]+) = true/)) {
        item=substr(line, RSTART, RLENGTH); sub(/ = true$/, "", item); gsub(/[\["\]]/, "", item); print item
        line=substr(line, RSTART + RLENGTH)
      }
    }
    in_verbs && /^}/ { exit }
  ' "$MATRIX")
  # Contribution entries in init.lua (`verb = "compact"`) that commands.lua does not declare.
  while IFS= read -r verb; do
    [[ -z $verb || $verb == matrix || $verb == topic ]] || discovered+=("$verb")
  done < <(sed -nE 's/.*[{ ,]verb = "([^"]+)".*/\1/p' "$INIT")
  discovered+=("matrix setup" statusline status-hook help)
  printf '%s\n' "${discovered[@]}" | sort -u > "$tmp/discovered"

  # A verb counts as migrated only when its body calls remuda.cli.parse and keeps no hand-parsed
  # remnant: no `type(cli...)` capability gate (the old-core fallback) and no `args[N]` read.
  # One cli.parse call is not enough. Rows are "verb<TAB>yes|no"; helpers between commands are
  # outside a body (a body runs from `command(` to the next line that starts with `end)`).
  awk '
    function flush() {
      if (verb != "") print verb "\t" ((parsed && !hand) ? "yes" : "no")
      if (verb == "topic") print "topic new\t" ((topic_new && !hand) ? "yes" : "no")
      verb=""
    }
    /^command\(/ {
      flush(); parsed=0; uses_cli=0; topic_new=0; hand=0
      if (match($0, /"[^"]+"/)) { verb=substr($0, RSTART+1, RLENGTH-2) }
    }
    verb != "" && /remuda\.cli/ { uses_cli=1 }
    verb != "" && /cli\.parse/ && uses_cli { parsed=1 }
    verb != "" && /type\(cli/ { hand=1 }
    verb != "" && $0 !~ /^command\(/ && /args\[[0-9a-z]/ { hand=1 }
    verb == "topic" && /cli\.parse\(TOPIC_NEW_CLI_SPEC/ { topic_new=1 }
    /^end\)/ { flush() }
    END { flush() }
  ' "$commands" > "$tmp/status_commands"
  awk '
    function flush() { if (verb != "" && !(verb in seen)) print verb "\t" ((parsed && !hand) ? "yes" : "no"); verb="" }
    NR == FNR { split($0, row, "\t"); seen[row[1]]=1; next }
    /[{ ,]verb = "/ { flush(); parsed=0; hand=0; uses_cli=0
      if (match($0, /verb = "[^"]+"/)) { verb=substr($0, RSTART+8, RLENGTH-9) } }
    verb != "" && /remuda\.cli/ { uses_cli=1 }
    verb != "" && /cli\.parse/ && uses_cli { parsed=1 }
    verb != "" && /type\(cli/ { hand=1 }
    verb != "" && !/verb = "/ && /args\[[0-9a-z]/ { hand=1 }
    verb != "" && /args\[[0-9a-z]/ && /verb = "/ { hand=1 }
    END { flush() }
  ' "$tmp/status_commands" "$INIT" | grep -vE '^(matrix|topic)	' > "$tmp/status_init" || true
  cat "$tmp/status_commands" "$tmp/status_init" > "$tmp/status"
  awk -F'\t' '$2 == "yes" { print $1 }' "$tmp/status" > "$tmp/migrated"
  while IFS=$'\t' read -r verb parsed; do
    [[ -z $verb || $verb == matrix || $verb == topic ]] && continue
    if grep -Fqx -- "$verb" "$ALLOWLIST"; then
      if [[ $parsed == yes ]]; then
        echo "allowlist entry '$verb' is migrated; remove it (the list may only shrink)" >&2
        return 1
      fi
    elif [[ $parsed != yes ]]; then
      echo "new verbs must use remuda.cli.parse; see docs: '$verb' is not allowlisted" >&2
      return 1
    fi
  done < "$tmp/status"

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
# Honest baseline: verbs declared only in init.lua (compact), quoted Matrix keys (mark-all) and
# families that still carry a hand-parsed fallback (close: cli.parse behind a capability gate and args[N]
# reads) are hand-parsed, so they must be allowlisted.
for verb in compact "matrix mark-all" "matrix thread" close send send-to-leader reply forward "topic new"; do
  grep -Fvx "$verb" "$ALLOWLIST" > "$tmp/allowlist.txt"
  expect_failure "new verbs must use remuda.cli.parse; see docs: '$verb'" "$REPO/packages/butler/commands.lua" "$tmp/allowlist.txt"
done
cp "$REPO/packages/butler/commands.lua" "$tmp/commands.lua"
printf '\ncommand(999, "fake-gated", "usage", function(args) local cli = remuda.cli; if type(cli.parse) == "function" then return cli.parse({}, args) end; return args[2] end)\n' >> "$tmp/commands.lua"
expect_failure "new verbs must use remuda.cli.parse; see docs: 'fake-gated'" "$tmp/commands.lua"
echo "hand-parsed verb freeze: PASS (four coverage cases, honest-baseline cases)"
