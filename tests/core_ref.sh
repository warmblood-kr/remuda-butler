# Core version shared by the shell, Rust, golden guidance, and contract checks.
# Bump deliberately; a core change must not redden Butler PRs.
# Merged core #739 adds remuda.daemon.socket_publication, on top of #726 (the
# version-1 instance-bound text/key provider).
CORE_REF=${CORE_REF:-6ec89cd3cfd2390588c1c5cdc1b63e87babaa740}

core_ref_check() {
  local remuda_bin=${REMUDA_BIN:-remuda}
  local version
  version=$("$remuda_bin" --version 2>/dev/null | tail -1) || version=unknown
  if [[ $version != *"${CORE_REF:0:7}"* ]]; then
    echo "upgrade core: need ${CORE_REF:0:7}, have ${version:-unknown}" >&2
    return 1
  fi
}
