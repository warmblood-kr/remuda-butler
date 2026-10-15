# Decides the coordination-config test mode once, outside Lua.
#   full       native Codex present and answering `codex --version`
#   codexless  Codex not installed (a subset only; CI without Codex gets this)
# A present but broken/slow/failing Codex is a hard failure, never a subset;
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
  if ! perl -e 'alarm 10; exec @ARGV' codex --version >/dev/null 2>&1; then
    echo "FAIL: codex is installed but 'codex --version' failed or timed out" >&2
    return 1
  fi
  echo full
}
