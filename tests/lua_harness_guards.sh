#!/usr/bin/env bash
# The Lua harness guards: test-path containment, private runtime directory,
# the daemon probe, and cleanup that survives an early failure.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
REMUDA_BIN=${REMUDA_BIN:-remuda}
REMUDA_BIN=$(command -v "$REMUDA_BIN")
T=$(mktemp -d /tmp/lhg.XXXXXX)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
export REMUDA_RUNTIME_DIR=$T/run HOME=$T/home XDG_DATA_HOME=$T/data XDG_CONFIG_HOME=$T/config REMUDA_NO_UPDATE_CHECK=1
unset REMUDA_SERVER
fail() { echo "FAIL: $*" >&2; exit 1; }

source "$REPO/tests/lib/harness.sh"

# Containment is judged after resolving .. and symlinks.
H_REPO=$T/repo
mkdir -p "$H_REPO/tests/lua/sub" "$H_REPO/tests/lib" "$T/outside"
touch "$H_REPO/tests/lua/a_test.lua" "$H_REPO/tests/lua/sub/b_test.lua" "$H_REPO/tests/lib/c_test.lua" "$T/outside/d_test.lua"
ln -s ../lib "$H_REPO/tests/lua/dirlink"
ln -s ../../lib/c_test.lua "$H_REPO/tests/lua/filelink_test.lua"
ln -s "$T/outside" "$H_REPO/tests/lua/outlink"
[[ $(harness_resolve_test tests/lua/a_test.lua) == "$H_REPO/tests/lua/a_test.lua" ]] || fail "plain test refused"
harness_resolve_test tests/lua/sub/b_test.lua >/dev/null || fail "nested test refused"
harness_resolve_test tests/lua/sub/../a_test.lua >/dev/null || fail "dotdot staying under tests/lua refused"
for bad in tests/lua/../lib/c_test.lua tests/lua/dirlink/c_test.lua tests/lua/outlink/d_test.lua \
  tests/lua/filelink_test.lua tests/lua/missing_test.lua /abs/a_test.lua tests/lua/a.lua; do
  ! harness_resolve_test "$bad" >/dev/null || fail "accepted $bad"
done

# The CLI refuses an escaping argument before any daemon starts.
out=$(bash "$REPO/tests/lua_tests.sh" tests/lua/../lib/harness.lua 2>&1) && fail "escaping argument accepted"
[[ "$out" == *"test must be a file under tests/lua"* ]] || fail "no clear refusal: $out"

# The runtime directory is a fresh private directory, never a pre-planted path.
harness_private_dir "$T/priv" 2>/dev/null
[[ -n $(find "$T/priv" -maxdepth 0 -type d -perm 700) ]] || fail "mode is not 700"
! harness_private_dir "$T/priv" 2>/dev/null || fail "reused an existing directory"
ln -s "$T/outside" "$T/planted"
! harness_private_dir "$T/planted" 2>/dev/null || fail "followed a planted symlink"

# The probe reports an absent harness daemon as down and refuses other names.
! harness_daemon_up "h$$" || fail "absent daemon reported up"
! harness_daemon_up default 2>/dev/null || fail "probed a non-harness name"
[[ ! -e $REMUDA_RUNTIME_DIR/remuda/h$$.sock ]] || fail "probe left a socket"

# Cleanup is safe with no scratch directory.
H_SCRATCH= harness_cleanup 0 || fail "cleanup failed without a scratch directory"
echo "PASS"
