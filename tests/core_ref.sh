# Core version shared by the shell, Rust, golden guidance, and contract checks.
# Bump deliberately; a core change must not redden Butler PRs.
# Merged core #726 supplies the version-1 instance-bound text/key provider.
CORE_REF=${CORE_REF:-ae9ce9513941cd71e3f9ddb71b7f39adab79a63f}

core_ref_check() {
  local remuda_bin=${REMUDA_BIN:-remuda}
  local version
  version=$("$remuda_bin" --version 2>/dev/null | tail -1) || version=unknown
  if [[ $version != *"${CORE_REF:0:7}"* ]]; then
    echo "upgrade core: need ${CORE_REF:0:7}, have ${version:-unknown}" >&2
    return 1
  fi
}
