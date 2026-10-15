#!/usr/bin/env bash
# The config test's mode decision: absent => codexless subset, present and ok
# => full, present but failing => FAIL, REQUIRE_NATIVE_CODEX=1 + absent => FAIL.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
source "$REPO/tests/lib/config_test_mode.sh"
T=$(mktemp -d /tmp/bccm.XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/none" "$T/ok" "$T/broken"
for tool in perl bash sh env; do
  p=$(command -v "$tool") && for d in none ok broken; do ln -s "$p" "$T/$d/$tool"; done
done
printf '#!/bin/sh\necho codex-cli 0.0.0\n' >"$T/ok/codex"
printf '#!/bin/sh\necho boom >&2\nexit 3\n' >"$T/broken/codex"
chmod +x "$T/ok/codex" "$T/broken/codex"
fail() { echo "FAIL: $*" >&2; exit 1; }

got=$(PATH=$T/none config_test_mode 2>/dev/null) || fail "absent codex must select the subset"
[[ $got == codexless ]] || fail "absent codex gave '$got'"
got=$(PATH=$T/ok config_test_mode 2>/dev/null) || fail "working codex must select full"
[[ $got == full ]] || fail "working codex gave '$got'"
if PATH=$T/broken config_test_mode >/dev/null 2>&1; then fail "a failing codex must be a failure, not the subset"; fi
if REQUIRE_NATIVE_CODEX=1 PATH=$T/none config_test_mode >/dev/null 2>&1; then
  fail "REQUIRE_NATIVE_CODEX=1 with codex absent must fail"
fi
echo "ok: config test mode decision (absent=codexless, ok=full, broken=FAIL, required+absent=FAIL)"
