#!/usr/bin/env bash
# Replays OpenCode session events against the shipped completion-nudge source.
# The plugin lives inside packages/butler/opencode_nudge.lua, so extract it and
# run tests/opencode_nudge_events.mjs with node (CI) or jsc (macOS).
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
SOURCE="$REPO/packages/butler/opencode_nudge.lua"

if command -v node >/dev/null 2>&1; then
  RUNTIME=(node)
  MODE=node
elif [ -x /System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc ]; then
  RUNTIME=(/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc -m)
  MODE=jsc
else
  echo "SKIP opencode nudge events: no node or jsc to run JavaScript"
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/opencode-nudge-events.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Everything between the SOURCE sentinel and its terminator is the plugin file.
awk '/^local SOURCE = \[==\[/{copy=1;next} /^\]==\]$/{copy=0} copy' "$SOURCE" >"$WORK/nudge.mjs"
if ! grep -q "remuda.completion-nudge" "$WORK/nudge.mjs"; then
  echo "FAIL could not extract the plugin source from $SOURCE" >&2
  exit 1
fi
cp "$REPO/tests/opencode_nudge_events.mjs" "$WORK/events.mjs"

echo "opencode nudge events via $MODE"
"${RUNTIME[@]}" "$WORK/events.mjs"
