#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
"${REMUDA_BIN:-remuda}" mod test "$repo"
