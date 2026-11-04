#!/usr/bin/env bash
# Regenerate the shell-suite task manifest from the current working tree.
#
# TSV columns: id <TAB> duration_hint_seconds <TAB> kind <TAB> argument
#   lua              tests/*.lua basename
#   shell            tests/*.sh basename
#   embedded         tests/lua/*_test.lua basename (fresh controller + child)
#   embedded-nochild tests/lua/*_test.lua basename (fresh controller, no child)
#   direct-lua       tests/lua/*_test.lua path (LuaJIT, no harness/daemon)
#
# --list prints only the sorted task ids, for coverage parity review.
#
# Mirrors the current shell_tests.sh discovery rules, with the agreed
# consolidation: remove two definition-only shell entries, run the pure path
# table directly, and give five controller-only files an explicit no-child
# mode. Keep the lua_tests.sh aggregate replaced by individual files.
set -uo pipefail
export LC_ALL=C

REPO=$(cd "$(dirname "$0")/../.." && pwd -P)
MODE=tsv
case ${1:-} in
  --list) MODE=list ;;
  --tsv|"") MODE=tsv ;;
  *)
    echo "usage: tests/ci/manifest.sh [--list|--tsv]" >&2
    exit 2
    ;;
esac

# Measured main run 41566792890. Only hints: they order long tasks first.
duration_for() {
  case $1 in
    agent_identity.sh) echo 153 ;;
    mail_by_ulid.sh) echo 156 ;;
    butler_permissions.sh) echo 101 ;;
    butler_single_instance.sh) echo 22 ;;
    butler_coordination_config_mode.sh) echo 30 ;;
    butler_launch_fallback.sh) echo 30 ;;
    live_reload.sh) echo 11 ;;
    session_tree.sh) echo 11 ;;
    butler_matrix_relay.sh) echo 5 ;;
    butler_matrix_follow_cli.sh) echo 5 ;;
    *) echo 1 ;;
  esac
}

# Explicit consolidation lists. Each no-child file was manually audited to
# use only T.test/T.eq/T.ok/T.expect plus the controller's real fs/json/parser;
# harness.lua fails closed on every child helper in this mode.
NOCHILD='
butler_cli_unit_test.lua
butler_input_queue_test.lua
butler_opencode_readiness_test.lua
butler_owner_input_test.lua
butler_schedule_delivery_test.lua
'
# Pure host-independent table test: same 68 cases/11 tables directly with LuaJIT.
DIRECT='
butler_path_test.lua
'

in_list() { # value, newline list
  local value=$1 list=$2 item
  for item in $list; do
    [[ $value == "$item" ]] && return 0
  done
  return 1
}

ROWS=()
add_row() { ROWS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"); }
shopt -s nullglob

# Standalone Lua: the current shell_tests.sh exclusions, exactly.
for path in "$REPO"/tests/*.lua; do
  base=${path##*/}
  case $base in
    session_tree.lua|butler_matrix_relay.lua|butler_diagnostics_matrix.lua|butler_coordination_config.lua) continue ;;
    butler_approve_text.lua|butler_status_hook.lua|butler_guard.lua|butler_adopt.lua|butler_approval_retry.lua|butler_schedule_cli.lua|butler_typed_lines_cli.lua) continue ;;
  esac
  add_row "standalone-lua/$base" "$(duration_for "$base")" lua "$base"
done

# Shell tasks: current exclusions, minus two definition-only helpers whose
# functions are exercised by their callers. Replace only lua_tests.sh with the
# individual embedded files.
for path in "$REPO"/tests/*.sh; do
  base=${path##*/}
  case $base in
    rust_tests.sh|golden_guidance.sh|shell_tests.sh|awk-timeout.sh|core_ref.sh) continue ;;
    lua_tests.sh)
      for lpath in "$REPO"/tests/lua/*_test.lua; do
        lbase=${lpath##*/}
        if in_list "$lbase" "$DIRECT"; then
          add_row "direct-lua/$lbase" 1 direct-lua "tests/lua/$lbase"
        elif in_list "$lbase" "$NOCHILD"; then
          add_row "embedded-lua/$lbase" 1 embedded-nochild "$lbase"
        else
          add_row "embedded-lua/$lbase" 1 embedded "$lbase"
        fi
      done
      continue
      ;;
  esac
  add_row "shell/$base" "$(duration_for "$base")" shell "$base"
done

if ((${#ROWS[@]} == 0)); then
  echo "manifest: no tasks discovered" >&2
  exit 2
fi

ids=$(printf '%s\n' "${ROWS[@]}" | cut -f1)
dupes=$(printf '%s\n' "$ids" | sort | uniq -d)
if [[ -n $dupes ]]; then
  echo "manifest: duplicate task ids:" >&2
  printf '%s\n' "$dupes" >&2
  exit 2
fi

if [[ $MODE == list ]]; then
  printf '%s\n' "$ids" | sort
else
  printf '%s\n' "${ROWS[@]}"
fi
