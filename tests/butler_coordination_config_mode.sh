#!/usr/bin/env bash
# The config test's mode decision: absent => codexless subset, present and ok
# => full, present but failing => FAIL, REQUIRE_NATIVE_CODEX=1 + absent => FAIL.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
source "$REPO/tests/lib/config_test_mode.sh"
T=$(mktemp -d /tmp/bccm.XXXXXX)
trap 'rm -rf "$T"' EXIT
unset REQUIRE_NATIVE_CODEX # ordinary cases must hold under the required-native gate
D="none ok broken empty garbage badexec slow"
for d in $D; do mkdir -p "$T/$d"; done
for tool in perl bash sh env sleep; do
  p=$(command -v "$tool") && for d in $D; do ln -s "$p" "$T/$d/$tool"; done
done
printf '#!/bin/sh\necho codex-cli 0.0.0\n' >"$T/ok/codex"
printf '#!/bin/sh\necho boom >&2\nexit 3\n' >"$T/broken/codex"
printf '#!/bin/sh\nexit 0\n' >"$T/empty/codex"
printf '#!/bin/sh\necho not a version\n' >"$T/garbage/codex"
printf '#!/nonexistent/interpreter\n' >"$T/badexec/codex"
printf '#!/bin/sh\nsleep 30\n' >"$T/slow/codex"
chmod +x "$T"/*/codex
fail() { echo "FAIL: $*" >&2; exit 1; }

got=$(PATH=$T/none config_test_mode 2>/dev/null) || fail "absent codex must select the subset"
[[ $got == codexless ]] || fail "absent codex gave '$got'"
got=$(PATH=$T/ok config_test_mode 2>/dev/null) || fail "working codex must select full"
[[ $got == full ]] || fail "working codex gave '$got'"
for d in broken empty garbage badexec; do
  if PATH=$T/$d config_test_mode >/dev/null 2>&1; then fail "$d codex must be a failure, not the subset"; fi
done
if BUTLER_CONFIG_TEST_PROBE_TIMEOUT=1 PATH=$T/slow config_test_mode >/dev/null 2>&1; then
  fail "a timing-out codex must be a failure"
fi
if REQUIRE_NATIVE_CODEX=1 PATH=$T/garbage config_test_mode >/dev/null 2>&1; then
  fail "garbage codex must fail under REQUIRE_NATIVE_CODEX=1"
fi
if REQUIRE_NATIVE_CODEX=1 PATH=$T/none config_test_mode >/dev/null 2>&1; then
  fail "REQUIRE_NATIVE_CODEX=1 with codex absent must fail"
fi
echo "ok: config test mode decision (absent=codexless, ok=full, broken/empty/garbage/bad-exec/timeout=FAIL, required+absent=FAIL)"
