# Core version shared by the shell, Rust, golden guidance, and contract checks.
# Bump deliberately; a core change must not redden Butler PRs.
CORE_REF=${CORE_REF:-cc371a0df360742c01d1d1475af191d0c47e5a25}

core_ref_check() {
  local remuda_bin=${REMUDA_BIN:-remuda}
  local version
  version=$("$remuda_bin" --version 2>/dev/null | tail -1) || version=unknown
  if [[ $version != *"${CORE_REF:0:7}"* ]]; then
    echo "upgrade core: need ${CORE_REF:0:7}, have ${version:-unknown}" >&2
    return 1
  fi
}
