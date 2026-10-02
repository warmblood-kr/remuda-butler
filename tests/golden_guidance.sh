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
# Needs: bash, git, awk, perl, and cargo when REMUDA_BIN is unset.
set -euo pipefail
export LC_ALL=C
REPO=$(cd "$(dirname "$0")/.." && pwd)
source "$REPO/tests/awk-timeout.sh"
GOLDEN=$REPO/tests/golden
CORE_URL=${CORE_URL:-https://github.com/warmblood-kr/remuda.git}
# Keep in step with tests/rust_tests.sh.
CORE_REF=${CORE_REF:-c59e04c5}
T=$(mktemp -d /tmp/bgg.XXXXXX)
T=$(cd "$T" && pwd -P)
S=bgg
DAEMON_PID=
source_home=${HOME:-/tmp}
export CARGO_HOME=${CARGO_HOME:-$source_home/.cargo}
export RUSTUP_HOME=${RUSTUP_HOME:-$source_home/.rustup}
cleanup() {
  local pid killed=0 left=0
  local descendants=()
  local fake_pids=()
  if [[ -n "$DAEMON_PID" ]]; then
    while IFS= read -r pid; do [[ -n "$pid" ]] && descendants+=("$pid"); done < <(
      ps -axo pid=,ppid= | awk -v root="$DAEMON_PID" '
        { ppid[$1]=$2; rows[NR]=$1 }
        END {
          found[root]=1
          do {
            changed=0
            for (i=1; i<=NR; i++) if (!found[rows[i]] && found[ppid[rows[i]]]) {
              found[rows[i]]=1; changed=1
            }
        } while (changed)
          for (i=1; i<=NR; i++) if (rows[i] != root && found[rows[i]]) print rows[i]
        }')
  fi
  if [[ -f $T/fake-pids ]]; then
    while IFS= read -r pid; do [[ -n "$pid" ]] && fake_pids+=("$pid"); done <"$T/fake-pids"
  fi
  if [[ ${REMUDA_RUNTIME_DIR:-} == "$T/run" ]]; then
    remuda -s "$S" stop -f >/dev/null 2>&1 || true
  else
    echo "refusing to stop golden daemon outside its scratch runtime" >&2
  fi
  for pid in "${descendants[@]}" "${fake_pids[@]}" "$DAEMON_PID"; do
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      killed=$((killed + 1))
    fi
  done
  [[ -n "$DAEMON_PID" ]] && wait "$DAEMON_PID" 2>/dev/null || true
  for _ in $(seq 20); do
    left=0
    for pid in "${descendants[@]}" "${fake_pids[@]}"; do
      [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1 && left=$((left + 1))
    done
    [[ $left == 0 ]] && break
    sleep 0.05
  done
  rm -rf "$T"
  echo "resources cleaned: $killed killed / $left left"
}
trap cleanup EXIT

if [[ -z ${REMUDA_BIN:-} ]]; then
  git clone --quiet "$CORE_URL" "$T/core"
  git -C "$T/core" checkout --quiet "$CORE_REF"
  (cd "$T/core" && cargo build --quiet --release --bin remuda)
  # cargo resolves a relative CARGO_TARGET_DIR against the clone.
  REMUDA_BIN=$(cd "$T/core" && cd "${CARGO_TARGET_DIR:-target}/release" && pwd)/remuda
  built=$(git -C "$T/core" rev-parse --short=7 HEAD)
fi

export HOME=$T/home REMUDA_RUNTIME_DIR=$T/run XDG_DATA_HOME=$T/data XDG_CONFIG_HOME=$T/config
export XDG_CACHE_HOME=$T/cache XDG_STATE_HOME=$T/state XDG_RUNTIME_DIR=$T/xdg-run
export REMUDA_BUTLER_PROJECT_HOME=$T/projects REMUDA_BUTLER_SERVER=$S REMUDA_NO_UPDATE_CHECK=1
export REMUDA_BUTLER_REPO_ROOT=$REPO
unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG REMUDA_BUTLER_AGENT_ID REMUDA_BUTLER_LEADER_ID \
  REMUDA_BUTLER_SESSION_NAME REMUDA_BUTLER_AGENT_ALIAS REMUDA_BUTLER_AGENT_KIND REMUDA_SESSION_CAPABILITY
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" \
  "$T/bin" "$T/argv" "$T/projects" "$XDG_DATA_HOME/remuda/mods/butler"
cp "$REMUDA_BIN" "$T/bin/remuda" ||
  { echo "cannot copy the core binary from $REMUDA_BIN. Next: set REMUDA_BIN to a built remuda" >&2; exit 2; }
version=$("$T/bin/remuda" --version 2>/dev/null | tail -1)
# The core built here must be the one under test, never an installed remuda.
if [[ -n ${built:-} && $version != *"$built"* ]]; then
  echo "core under test is '$version', not the pinned $built. Next: rerun; if it repeats, another build is using this CARGO_TARGET_DIR" >&2
  exit 2
fi
cp -R "$REPO/extension.toml" "$REPO/packages" "$XDG_DATA_HOME/remuda/mods/butler/"
# A fake claude: records its argv, one argument per NUL-free line, and stays up.
cat >"$T/bin/claude" <<EOF
#!/bin/sh
dest="$T/argv/\${REMUDA_BUTLER_SESSION_NAME:-x}"
: >"\$dest"
for arg do printf '%s\\n' "\$arg" >>"\$dest"; done
printf '─\\n❯\\n'
echo "\$\$" >>"$T/fake-pids"
exec sleep 3600
EOF
chmod +x "$T/bin/claude"
cat >"$T/bin/fake-root" <<EOF
#!/bin/sh
echo "\$\$" >>"$T/fake-pids"
exec /bin/sleep 3600
EOF
chmod +x "$T/bin/fake-root"
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

R daemon >"$T/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 80); do
  [[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] && break
  sleep 0.25
done
[[ -S "$REMUDA_RUNTIME_DIR/remuda/$S.sock" ]] || { cat "$T/daemon.log" >&2; echo "golden daemon failed to bind" >&2; exit 1; }
R -e "if not dofile('$REPO/scripts/check-butler-path-convention.lua') then error('path convention check failed', 0) end"

R -e "remuda._butler_argv = {'$T/bin/fake-root'}" >/dev/null   # root session: no agent
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
  bounded_awk '
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
  bounded_awk -v t="$T" -v real_t="$NORMALIZE_ROOT" -f "$REPO/tests/normalize-guidance.awk" "$file" >"$file.tmp"
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
