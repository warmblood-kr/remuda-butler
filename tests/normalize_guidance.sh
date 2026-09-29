#!/usr/bin/env bash
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
source "$REPO/tests/awk-timeout.sh"
NORMALIZER=${NORMALIZER:-$REPO/tests/normalize-guidance.awk}
T=$(mktemp -d /tmp/bng.XXXXXX)
trap 'rm -rf "$T"' EXIT

test_case() {
  local name=$1 input=$2 expected=$3 actual
  printf '%s' "$input" >"$T/input"
  bounded_awk -v t=/path/that/does/not/occur -v real_t=/another/nonmatch \
    -f "$NORMALIZER" "$T/input" >"$T/output"
  actual=$(cat "$T/output")
  if [[ $actual != "$expected" ]]; then
    printf 'FAIL %s\n  expected: <%s>\n  actual:   <%s>\n' "$name" "$expected" "$actual" >&2
    exit 1
  fi
  echo "PASS $name"
}

test_case json-empty '"REMUDA_SESSION_CAPABILITY":""' '"REMUDA_SESSION_CAPABILITY":""'
test_case shell-empty 'REMUDA_SESSION_CAPABILITY=""' 'REMUDA_SESSION_CAPABILITY=""'
test_case json-self '"REMUDA_SESSION_CAPABILITY":"REMUDA_SESSION_CAPABILITY"' '"REMUDA_SESSION_CAPABILITY":"<CAP>"'
test_case shell-self 'REMUDA_SESSION_CAPABILITY="REMUDA_SESSION_CAPABILITY"' 'REMUDA_SESSION_CAPABILITY="<CAP>"'
test_case json-duplicates '"REMUDA_SESSION_CAPABILITY":"one" "REMUDA_SESSION_CAPABILITY":"two"' '"REMUDA_SESSION_CAPABILITY":"<CAP>" "REMUDA_SESSION_CAPABILITY":"<CAP>"'
test_case shell-duplicates 'REMUDA_SESSION_CAPABILITY=one REMUDA_SESSION_CAPABILITY=two' 'REMUDA_SESSION_CAPABILITY=<CAP> REMUDA_SESSION_CAPABILITY=<CAP>'
test_case json-trailing-backslash '"REMUDA_SESSION_CAPABILITY":"secret\\"' '"REMUDA_SESSION_CAPABILITY":"<CAP>"'
test_case shell-trailing-backslash 'REMUDA_SESSION_CAPABILITY=secret\' 'REMUDA_SESSION_CAPABILITY=<CAP>\'
test_case json-crlf $'"REMUDA_SESSION_CAPABILITY":"secret"\r\n' $'"REMUDA_SESSION_CAPABILITY":"<CAP>"\r'
test_case shell-crlf $'REMUDA_SESSION_CAPABILITY="secret"\r\n' $'REMUDA_SESSION_CAPABILITY="<CAP>"\r'
