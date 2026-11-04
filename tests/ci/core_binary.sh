#!/usr/bin/env bash
# One immutable release binary for the pinned Remuda core.
#
# Source this file, then call core_binary_resolve. It sets REMUDA_BIN and
# REMUDA_BIN_SOURCE (provided|cache|build). The cache key covers the exact
# runner image/ABI, OS, architecture, core ref, Rust toolchain, profile and
# recipe version. The cache holds only remuda + meta, never daemon/home/
# config/state. Every hit and every build is validated against CORE_REF.
set -uo pipefail

CORE_BINARY_RECIPE=${CORE_BINARY_RECIPE:-1}

core_binary_repo() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P
}

core_binary_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

core_binary_identity() {
  local repo os arch image libc rustc_v cc_v
  repo=$(core_binary_repo)
  # shellcheck disable=SC1091
  source "$repo/tests/core_ref.sh"
  os=$(uname -s)
  arch=$(uname -m)
  if [[ -n ${ImageOS:-} ]]; then
    image="${ImageOS}/${ImageVersion:-unknown}"
  else
    image="$(uname -srm)"
  fi
  if command -v ldd >/dev/null 2>&1; then
    libc=$(ldd --version 2>&1 | head -1)
  else
    libc="$(uname -srm)"
  fi
  rustc_v=$(rustc -vV 2>/dev/null | tr '\n' ';')
  cc_v=$( (cc --version 2>/dev/null || clang --version 2>/dev/null || true) | head -1)
  printf 'core_ref=%s\nos=%s\narch=%s\nimage=%s\nlibc=%s\nrustc=%s\ncc=%s\nprofile=release\nrecipe=%s\n' \
    "$CORE_REF" "$os" "$arch" "$image" "$libc" "$rustc_v" "$cc_v" "$CORE_BINARY_RECIPE"
}

core_binary_key() {
  core_binary_identity | core_binary_sha256
}

core_binary_cache_root() {
  printf '%s\n' "${REMUDA_CI_CACHE_DIR:-${HOME:-/tmp}/.cache/remuda-core-bin}"
}

# A binary is usable only when it is a regular executable and reports the
# pinned core. A failed validation is never published and never reused.
core_binary_validate() {
  local bin=$1 version
  [[ -n ${bin:-} && -f $bin && -x $bin && ! -L $bin ]] || return 1
  version=$("$bin" --version 2>/dev/null | tail -1) || return 1
  [[ -n ${version:-} && $version == *"${CORE_REF:0:7}"* ]] || return 1
  return 0
}

# Build and publish one cache entry. Runs in a subshell with an EXIT/INT/TERM
# trap that removes only this build's temp tree, staging dir and lock. The lock
# holds the owner PID for diagnostics; a SIGKILL may leave it, and a waiter then
# fails after a bounded wait with the lock path (the next job has a fresh
# TMPDIR). It never deletes a lock it cannot prove dead, avoiding a stale-read
# race between two waiters.
core_binary_build_and_publish() {
  local cache=$1 key=$2 dir=$3
  local lock='' built='' rc=0 waited=0 owner=''
  CORE_BINARY_LOCK= CORE_BINARY_TMP= CORE_BINARY_STAGE=
  lock="${TMPDIR:-/tmp}/remuda-core-cache-$key.lock"
  while ! mkdir "$lock" 2>/dev/null; do
    waited=$((waited + 1))
    if ((waited > 300)); then
      owner=''
      [[ -f $lock/pid ]] && owner=$(cat "$lock/pid" 2>/dev/null || true)
      echo "core binary: timeout waiting for cache lock $lock (owner ${owner:-unknown}); remove it only if no build is active" >&2
      return 2
    fi
    sleep 0.1
  done
  if ! printf '%s\n' "$$" >"$lock/pid"; then
    rm -rf "$lock" 2>/dev/null || true
    return 2
  fi
  CORE_BINARY_LOCK=$lock

  (
    set -e
    trap 'rm -rf "${CORE_BINARY_TMP:-}" "${CORE_BINARY_STAGE:-}" 2>/dev/null || true; rm -rf "${CORE_BINARY_LOCK:-}" 2>/dev/null || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # Another process may have published while we waited for the lock.
    if core_binary_validate "$dir/remuda"; then
      exit 0
    fi

    CORE_BINARY_TMP=$(mktemp -d "${TMPDIR:-/tmp}/remuda-core-build.XXXXXX") || exit 2
    git clone --quiet "${CORE_URL:-https://github.com/warmblood-kr/remuda.git}" "$CORE_BINARY_TMP/core" || exit 2
    git -C "$CORE_BINARY_TMP/core" checkout --quiet "$CORE_REF" || exit 2
    (cd "$CORE_BINARY_TMP/core" && cargo build --quiet --locked --release --bin remuda) || exit 2

    if [[ ${CARGO_TARGET_DIR:-} == /* ]]; then
      built="$CARGO_TARGET_DIR/release/remuda"
    else
      built="$CORE_BINARY_TMP/core/${CARGO_TARGET_DIR:-target}/release/remuda"
    fi
    core_binary_validate "$built" || exit 2

    CORE_BINARY_STAGE="$cache/.stage.$$"
    rm -rf "$CORE_BINARY_STAGE"
    mkdir -p "$CORE_BINARY_STAGE" || exit 2
    cp "$built" "$CORE_BINARY_STAGE/remuda" || exit 2
    chmod 755 "$CORE_BINARY_STAGE/remuda" || exit 2
    core_binary_identity >"$CORE_BINARY_STAGE/meta" || exit 2

    # Publish the whole directory with one rename under the lock.
    rm -rf "$dir"
    mv "$CORE_BINARY_STAGE" "$dir" || exit 2
    CORE_BINARY_STAGE=
  )
  rc=$?
  rm -rf "${CORE_BINARY_LOCK:-}" 2>/dev/null || true
  CORE_BINARY_LOCK= CORE_BINARY_TMP= CORE_BINARY_STAGE=
  return $rc
}

# Sets REMUDA_BIN and REMUDA_BIN_SOURCE. Returns 2 on any setup/build failure.
core_binary_resolve() {
  local repo cache key dir
  repo=$(core_binary_repo)
  # shellcheck disable=SC1091
  source "$repo/tests/core_ref.sh"

  if [[ -n ${REMUDA_BIN:-} ]]; then
    if [[ $REMUDA_BIN != /* ]]; then
      if [[ $REMUDA_BIN == */* ]]; then
        REMUDA_BIN="$(cd "$(dirname "$REMUDA_BIN")" && pwd)/$(basename "$REMUDA_BIN")"
      else
        REMUDA_BIN=$(command -v "$REMUDA_BIN" 2>/dev/null || true)
      fi
    fi
    if ! core_binary_validate "$REMUDA_BIN"; then
      echo "core binary: REMUDA_BIN='$REMUDA_BIN' is not a regular executable reporting pinned ${CORE_REF:0:7}" >&2
      return 2
    fi
    REMUDA_BIN_SOURCE=provided
    return 0
  fi

  if ! command -v rustc >/dev/null 2>&1 || ! command -v cargo >/dev/null 2>&1; then
    echo "core binary: rustc/cargo not found; set REMUDA_BIN to a built pinned remuda" >&2
    return 2
  fi

  cache=$(core_binary_cache_root)
  key=$(core_binary_key)
  dir="$cache/$key"

  if core_binary_validate "$dir/remuda"; then
    REMUDA_BIN="$dir/remuda"
    REMUDA_BIN_SOURCE=cache
    echo "core binary: cache hit $dir/remuda" >&2
    return 0
  fi

  echo "core binary: cache miss for pinned ${CORE_REF:0:7}; building at $dir" >&2
  mkdir -p "$cache" || return 2
  if ! core_binary_build_and_publish "$cache" "$key" "$dir"; then
    # A concurrent process may have published a valid entry even if our build
    # path failed; use it only after validation.
    if ! core_binary_validate "$dir/remuda"; then
      echo "core binary: build/publish failed for $CORE_REF" >&2
      return 2
    fi
  fi
  if ! core_binary_validate "$dir/remuda"; then
    echo "core binary: published binary failed pin validation: $dir/remuda" >&2
    return 2
  fi
  REMUDA_BIN="$dir/remuda"
  REMUDA_BIN_SOURCE=build
  echo "core binary: published $dir/remuda" >&2
  return 0
}
