#!/usr/bin/env bash
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
source "$REPO/tests/lib/harness.sh"
harness_prepare
harness_run "${1:-tests/lua/spike_test.lua}"

