#!/usr/bin/env bash
# Golden guidance: what Butler tells people and agents must not change by accident.
# Captures, from a private daemon with this checkout's Butler on a pinned core:
#   help.txt           `remuda butler help`
#   agents-topic.md    AGENTS.md written for a delegated topic member (lead1)
#   agents-launch.md   AGENTS.md written for a launched member (w1, leader butler)
#   welcome.txt        the "Welcome to Butler" mail body in lead1's inbox
#   argv-claude.txt    the argv Butler starts a claude member with (the prompt text)
# normalises run-specific values (paths, ULIDs, message ids, times, tokens), and
# compares byte-for-byte with tests/golden/. hook-design migration steps (DESIGN.md
# §7) must keep these identical.
#
#   tests/golden_guidance.sh                  # clone + build core at CORE_REF
#   REMUDA_BIN=~/.local/bin/remuda tests/golden_guidance.sh
#   GOLDEN_UPDATE=1 tests/golden_guidance.sh  # a DELIBERATE guidance change: rewrite
#                                             # tests/golden/ and commit the diff with it
# Needs: bash, git, awk, and cargo when REMUDA_BIN is unset.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
GOLDEN=$REPO/tests/golden
CORE_URL=${CORE_URL:-https://github.com/warmblood-kr/remuda.git}
# Keep in step with tests/rust_tests.sh.
CORE_REF=${CORE_REF:-7247c45}
T=$(mktemp -d /tmp/bgg.XXXXXX) S=bgg
source_home=${HOME:-/tmp}
export CARGO_HOME=${CARGO_HOME:-$source_home/.cargo}
export RUSTUP_HOME=${RUSTUP_HOME:-$source_home/.rustup}
cleanup() {
  if [[ ${REMUDA_RUNTIME_DIR:-} == "$T/run" ]]; then
    remuda -s "$S" stop -f >/dev/null 2>&1 || true
  else
    echo "refusing to stop golden daemon outside its scratch runtime" >&2
  fi
  pkill -f "$T/" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

if [[ -z ${REMUDA_BIN:-} ]]; then
  git clone --quiet "$CORE_URL" "$T/core"
  git -C "$T/core" checkout --quiet "$CORE_REF"
  (cd "$T/core" && cargo build --quiet --release --bin remuda)
  REMUDA_BIN=$T/core/target/release/remuda
fi

export HOME=$T/home REMUDA_RUNTIME_DIR=$T/run XDG_DATA_HOME=$T/data XDG_CONFIG_HOME=$T/config
export XDG_CACHE_HOME=$T/cache XDG_STATE_HOME=$T/state XDG_RUNTIME_DIR=$T/xdg-run
export REMUDA_BUTLER_PROJECT_HOME=$T/projects REMUDA_BUTLER_SERVER=$S REMUDA_NO_UPDATE_CHECK=1
export REMUDA_BUTLER_REPO_ROOT=$REPO
unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG REMUDA_BUTLER_AGENT_ID REMUDA_BUTLER_LEADER_ID \
  REMUDA_BUTLER_SESSION_NAME REMUDA_BUTLER_AGENT_ALIAS REMUDA_BUTLER_AGENT_KIND REMUDA_SESSION_CAPABILITY
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" \
  "$T/bin" "$T/argv" "$T/projects" "$XDG_DATA_HOME/remuda/mods/butler"
cp "$REMUDA_BIN" "$T/bin/remuda"
cp -R "$REPO/extension.toml" "$REPO/packages" "$XDG_DATA_HOME/remuda/mods/butler/"
# A fake claude: records its argv, one argument per NUL-free line, and stays up.
cat >"$T/bin/claude" <<EOF
#!/bin/sh
dest="$T/argv/\${REMUDA_BUTLER_SESSION_NAME:-x}"
: >"\$dest"
for arg do printf '%s\\n' "\$arg" >>"\$dest"; done
printf '─\\n❯\\n'
while :; do sleep 1; done
EOF
chmod +x "$T/bin/claude"
export PATH=$T/bin:$PATH
R() { remuda -s "$S" "$@"; }
wait_live() { for _ in $(seq 80); do R ls 2>/dev/null | grep -q "^$1 .*live" && return 0; sleep 0.25; done; echo "never came up: $1" >&2; return 1; }
wait_file() { for _ in $(seq 80); do [[ -s $1 ]] && return 0; sleep 0.25; done; echo "never written: $1" >&2; return 1; }
wait_welcome() {
  for _ in $(seq 40); do
    R butler inbox lead1 >"$T/welcome-inbox.txt"
    grep -F 'Welcome to Butler' "$T/welcome-inbox.txt" >/dev/null && return 0
    sleep 0.25
  done
  echo "welcome was not queued for lead1" >&2
  return 1
}

R -e "if not dofile('$REPO/scripts/check-butler-path-convention.lua') then error('path convention check failed', 0) end"

R -e 'remuda._butler_argv = {"sh", "-c", "while :; do sleep 1; done"}' >/dev/null   # root session: no agent
R butler --headless >/dev/null
wait_live butler
R butler topic delegate lead1 --agent claude "golden task" >/dev/null
R butler launch claude w1 >/dev/null
wait_live lead1; wait_live w1; wait_file "$T/argv/lead1"

OUT=$T/out; mkdir -p "$OUT"
R butler help >"$OUT/help.txt"
cp "$T/projects/lead1/AGENTS.md" "$OUT/agents-topic.md"
cp "$XDG_DATA_HOME/remuda/butler/sessions/w1/AGENTS.md" "$OUT/agents-launch.md"
wait_welcome
WELCOME_COUNT=$(grep -c 'Welcome to Butler' "$T/welcome-inbox.txt" || true)
[[ "$WELCOME_COUNT" == 1 ]] || { echo "expected one welcome, got $WELCOME_COUNT" >&2; exit 1; }
R butler inbox lead1 >"$T/welcome-second-inbox.txt"
if grep -F 'Welcome to Butler' "$T/welcome-second-inbox.txt" >/dev/null; then
  echo "duplicate welcome queued for lead1" >&2
  exit 1
fi
if grep -F 'Welcome to Butler' "$T/welcome-inbox.txt" >/dev/null; then
  awk '
    /^\[[^]]+\] Welcome to Butler$/ { body=1; found=1; next }
    body && /^\[message-/ { exit }
    body && /^\[[^]]+ from / { exit }
    body { print }
  ' "$T/welcome-inbox.txt" >"$OUT/welcome.txt"
else
  { printf '%s\n' 'NO WELCOME MESSAGE'; cat "$T/welcome-inbox.txt"; } >"$OUT/welcome.txt"
fi
cp "$T/argv/lead1" "$OUT/argv-claude.txt"

# Normalise run-specific values so only guidance text is compared.
NORMALIZE_ROOT=$(cd "$T" && pwd -P)
for file in "$OUT"/*; do
  awk -v t="$T" -v real_t="$NORMALIZE_ROOT" -f "$REPO/tests/normalize-guidance.awk" "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
done

if [[ ${GOLDEN_UPDATE:-} == 1 ]]; then
  mkdir -p "$GOLDEN"
  diff -ru "$GOLDEN" "$OUT" || true
  rm -rf "$GOLDEN"; cp -R "$OUT" "$GOLDEN"
  echo "golden updated: commit tests/golden/ WITH the guidance change and paste the diff above into the PR"
  exit 0
fi
if diff -ru "$GOLDEN" "$OUT"; then
  echo "PASS golden guidance ($(ls "$GOLDEN" | tr '\n' ' ')) core $("$REMUDA_BIN" --version 2>/dev/null | tail -1)"
else
  echo "FAIL golden guidance: the diff above is a guidance change. If it is deliberate, rerun with GOLDEN_UPDATE=1 and commit tests/golden/ in the same PR."
  exit 1
fi
