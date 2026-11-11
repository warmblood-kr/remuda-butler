#!/usr/bin/env bash
# Run every standalone test against one pinned core: each tests/*.sh (each
# makes its own private daemon and scratch dirs) and the luajit unit tests.
#
#   tests/shell_tests.sh                     # clone + build core at CORE_REF
#   REMUDA_BIN=~/.local/bin/remuda tests/shell_tests.sh
#
# Needs: bash, git (full history: live_reload.sh archives an old ref),
# awk, perl, luajit, and cargo when REMUDA_BIN is unset.
set -uo pipefail

# Default remains the complete local suite. CI can request its PR policy/unit
# subset; unknown scripts fail closed so a new security gate is not lost.
mode=${BUTLER_SHELL_MODE:-all}
case "$mode" in all|policy|classify) ;; *) echo "unknown BUTLER_SHELL_MODE: $mode" >&2; exit 2 ;; esac

REPO=$(cd "$(dirname "$0")/.." && pwd)
classify_shell_test() {
  local sh=$1
  case $(basename "$sh") in
    rust_tests.sh | golden_guidance.sh | shell_tests.sh | fast_tests.sh | butler_simple_inbox_acceptance.sh | butler_simple_sqlite_fixture.sh) return 1 ;;
    awk-timeout.sh | core_ref.sh | hand_parsed_verbs.sh | installer_no_restart.sh | installer_readiness_budget.sh | lua_harness_guards.sh | butler_file_args.sh | butler_permissions.sh | caller_identity.sh | butler_single_instance.sh | agent_identity.sh | butler_adopt.sh | delegate_leader_id.sh | mail_by_ulid.sh | reply_forward.sh | butler_unknown_verb.sh | opencode_nudge_events.sh | inbox_db_upgrade.sh | mod_package_assets.sh | isolated_env_cleanup_test.sh | isolated_env_admission_test.sh)
      # Policy tests and identity, file-boundary, isolation and harness
      # security controls stay on PRs, even when they need a private daemon.
      ;;
    butler_coordination_config_mode.sh | butler_matrix_relay_core_ref.sh | normalize_guidance.sh | lua_tests.sh | butler_coordination_config.sh | butler_diagnostics_matrix.sh | butler_launch_fallback.sh | butler_matrix_follow_cli.sh | butler_matrix_relay.sh | butler_reload_real.sh | butler_seams.sh | close_emits_exit.sh | codex_mcp_mail.sh | live_reload.sh | member_env.sh | old_core_boot.sh | session_tree.sh)
      [[ $mode == policy ]] && return 1 ;;
    *) echo "unclassified shell test: $(basename "$sh")" >&2; exit 2 ;;
  esac
  return 0
}
for sh in "$REPO"/tests/*.sh; do classify_shell_test "$sh" || :; done
if [[ $mode == classify ]]; then echo 'shell classification: PASS'; exit 0; fi
CORE_URL=${CORE_URL:-https://github.com/warmblood-kr/remuda.git}
# The core pin is shared: tests/core_ref.sh.
source "$REPO/tests/core_ref.sh"
T=$(mktemp -d /tmp/bst.XXXXXX)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT

if [[ -z ${REMUDA_BIN:-} ]]; then
  git clone --quiet "$CORE_URL" "$T/core" && git -C "$T/core" checkout --quiet "$CORE_REF" &&
    (cd "$T/core" && cargo build --quiet --release --bin remuda) || { echo "core build failed" >&2; exit 2; }
  # cargo resolves a relative CARGO_TARGET_DIR against the clone.
  REMUDA_BIN=$(cd "$T/core" && cd "${CARGO_TARGET_DIR:-target}/release" && pwd)/remuda
  built=$(git -C "$T/core" rev-parse --short=7 HEAD)
fi
core_ref_check
mkdir -p "$T/bin" && cp "$REMUDA_BIN" "$T/bin/remuda" ||
  { echo "cannot copy the core binary from $REMUDA_BIN. Next: set REMUDA_BIN to a built remuda" >&2; exit 2; }
export PATH="$T/bin:$PATH" REMUDA_BIN="$T/bin/remuda" REMUDA_NO_UPDATE_CHECK=1
unset REMUDA_SERVER
version=$("$REMUDA_BIN" --version 2>/dev/null | tail -1)
# The core built here must be the one under test, never an installed remuda.
if [[ -n ${built:-} && $version != *"$built"* ]]; then
  echo "core under test is '$version', not the pinned $built. Next: rerun; if it repeats, another build is using this CARGO_TARGET_DIR" >&2
  exit 2
fi
echo "core $version, butler $(git -C "$REPO" rev-parse --short HEAD)"

failed=()
run() { # name command...
  local log="$T/$1.log"
  if (cd "$REPO" && "${@:2}") >"$log" 2>&1; then echo "PASS $1"; grep -E "^(codexless subset|NOTE)" "$log" || true; else echo "FAIL $1"; tail -20 "$log"; failed+=("$1"); fi
}
if [[ $mode == policy ]]; then
  # Pure-Lua unit tests stay on pull requests even though the broader Lua
  # corpus needs a pinned daemon. The inbox shadow is new code; a policy run
  # that never executes it would report green without testing it.
  run butler_inbox_db.lua luajit "tests/butler_inbox_db.lua"
  run relay_receipts_db.lua luajit "tests/relay_receipts_db.lua"
  run matrix_request_queue.lua luajit "tests/matrix_request_queue.lua"
  # Lifecycle reload rollback is pure Lua; keep it on PRs so a policy run
  # cannot report green without exercising the recovery contract.
  run butler_lifecycle_reload.lua luajit "tests/butler_lifecycle_reload.lua"
  # The private-envelope guard is pure Lua and must run on PRs even though the
  # mutation-heavy wrappers it protects are skipped there.
  run isolated_test_guard_test.lua luajit "tests/isolated_test_guard_test.lua"
fi
if [[ $mode == all ]]; then
for lua in "$REPO"/tests/*.lua; do
  # session_tree.lua needs a live daemon's _butler_bus; session_tree.sh runs it.
  # The Matrix relay state tests need core's remuda.json; its shell wrapper
  # runs them inside the pinned daemon instead of standalone LuaJIT.
  [[ $(basename "$lua") == session_tree.lua || $(basename "$lua") == butler_matrix_relay.lua || $(basename "$lua") == butler_diagnostics_matrix.lua || $(basename "$lua") == butler_coordination_config.lua || $(basename "$lua") == butler_simple_inbox_acceptance.lua ]] && continue
  case $(basename "$lua") in butler_approve_text.lua|butler_status_hook.lua|butler_guard.lua|butler_adopt.lua|butler_approval_retry.lua|butler_schedule_cli.lua|butler_typed_lines_cli.lua) continue ;; esac # real-parser coverage: lua/butler_cli_unit_test.lua
  run "$(basename "$lua")" luajit "tests/$(basename "$lua")"
done
fi
for sh in "$REPO"/tests/*.sh; do
  classify_shell_test "$sh" || continue
  run "$(basename "$sh")" bash "$sh"
done

if ((${#failed[@]})); then echo "shell tests FAILED: ${failed[*]}" >&2; exit 1; fi
echo "shell tests: PASS"
