#!/usr/bin/env bash
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
source "$REPO/tests/core_ref.sh"
T=$(mktemp -d /tmp/bmr-core-ref.XXXXXX)
trap 'rm -rf "$T"' EXIT

cat >"$T/remuda" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then
  printf 'remuda %s\n' "$FAKE_REMUDA_VERSION"
  exit 0
fi
echo 'fake remuda reached runtime' >&2
exit 42
EOF
chmod +x "$T/remuda"

out=$(
  FAKE_REMUDA_VERSION=old REMUDA_BIN="$T/remuda" bash "$REPO/tests/butler_matrix_relay.sh" 2>&1
) && { echo 'expected stale core to fail' >&2; exit 1; }
[[ $out == *"upgrade core: need ${CORE_REF:0:7}, have remuda old"* ]] || {
  echo "stale core was not rejected clearly: $out" >&2
  exit 1
}
[[ $out != *'fake remuda reached runtime'* ]] || {
  echo 'stale core reached daemon startup' >&2
  exit 1
}

out=$(
  FAKE_REMUDA_VERSION="${CORE_REF:0:7}" REMUDA_BIN="$T/remuda" \
    bash "$REPO/tests/butler_matrix_relay.sh" 2>&1
) && { echo 'expected fake runtime to stop the matching-core case' >&2; exit 1; }
[[ $out == *'fake remuda reached runtime'* ]] || {
  echo "matching core version was rejected before runtime: $out" >&2
  exit 1
}

echo 'ok - Matrix relay core pin guard'
