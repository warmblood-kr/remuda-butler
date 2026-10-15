# Decides the coordination-config test mode once, outside Lua.
#   full       native Codex present, `codex --version` exits 0 and prints
#              `codex[-cli] X.Y.Z` (a version string cannot authenticate a
#              hostile PATH shim; trusted PATH + native assertions are the check)
#   codexless  Codex not installed (a subset only; CI without Codex gets this)
# A present but broken/slow/failing/garbage-printing Codex is a hard failure, never a subset;
# REQUIRE_NATIVE_CODEX=1 also makes an absent Codex a failure.
config_test_mode() {
  if ! command -v codex >/dev/null 2>&1; then
    if [[ ${REQUIRE_NATIVE_CODEX:-} == 1 ]]; then
      echo "FAIL: codex not installed but REQUIRE_NATIVE_CODEX=1" >&2
      return 1
    fi
    echo "codexless subset: codex not installed" >&2
    echo codexless
    return 0
  fi
  local out to=${BUTLER_CONFIG_TEST_PROBE_TIMEOUT-10} line
  if ! [[ $to =~ ^[1-9][0-9]?$ ]] || ((10#$to > 60)); then
    echo "FAIL: BUTLER_CONFIG_TEST_PROBE_TIMEOUT must be an integer 1-60 (got '$to')" >&2
    return 1
  fi
  if ! out=$(perl -e 'alarm shift; exec @ARGV; exit 127' "$to" codex --version 2>/dev/null); then
    echo "FAIL: codex is installed but 'codex --version' failed or timed out" >&2
    return 1
  fi
  line=${out%%$'\n'*}
  line=${line%$'\r'}
  if ! [[ $line =~ ^codex(-cli)?\ [0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]]; then
    echo "FAIL: codex is installed but 'codex --version' printed no supported version" >&2
    return 1
  fi
  echo full
}
