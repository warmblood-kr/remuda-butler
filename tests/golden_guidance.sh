#!/usr/bin/env bash
# Golden guidance: what Butler tells people and agents must not change by accident.
# Captures, from a private daemon with this checkout's Butler on a pinned core:
#   help.txt           `remuda butler help`
#   agents-topic.md    AGENTS.md written for a delegated topic member (lead1)
#   agents-launch.md   AGENTS.md written for a launched member (w1, leader butler)
#   agents-root.md     AGENTS.md written for the root Butler session
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
# The core pin is shared: tests/core_ref.sh.
source "$REPO/tests/core_ref.sh"
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
core_ref_check

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
# The live root system prompt must name the STICC parts and ask for propagation.
R -e "local p = remuda._butler_system_prompt or ''; for _, word in ipairs({ 'Situation', 'Task', 'Intent', 'Concern', 'Calibrate', 'propagate' }) do if not p:find(word, 1, true) then error('root SYSTEM_PROMPT lacks ' .. word, 0) end end"
R butler topic delegate lead1 --agent claude "golden task" >/dev/null
R butler launch claude w1 >/dev/null
wait_live lead1; wait_live w1; wait_file "$T/argv/lead1"

OUT=$T/out; mkdir -p "$OUT"
R butler help >"$OUT/help.txt"
R butler matrix thread --help >"$OUT/matrix-thread-help.txt"
cp "$T/projects/lead1/AGENTS.md" "$OUT/agents-topic.md"
cp "$XDG_DATA_HOME/remuda/butler/sessions/w1/AGENTS.md" "$OUT/agents-launch.md"
cp "$XDG_DATA_HOME/remuda/butler/sessions/butler/AGENTS.md" "$OUT/agents-root.md"
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

# Wording that must stay: members run the CLI bare (a leading VAR=1 can defeat an allow rule).
NOPREFIX='Do not prefix it with REMUDA_NO_UPDATE_CHECK=1 or other VAR=value assignments'
for f in agents-topic.md agents-launch.md; do
  grep -qF "$NOPREFIX" "$OUT/$f" || { echo "FAIL golden guidance: $f lacks the no-env-prefix line" >&2; exit 1; }
done

# Semantics, not just snapshots: every generated surface carries the durable
# guidance agents act on. Keep these checks when a deliberate golden update runs.
require_text() { # file needle description
  grep -qF "$2" "$OUT/$1" || { echo "FAIL golden guidance: $1 lacks $3" >&2; exit 1; }
}
for f in agents-root.md agents-topic.md agents-launch.md welcome.txt; do
  require_text "$f" '## Delegation: STICC' "the STICC section"
  require_text "$f" '**Calibrate:** ask the member to confirm' "the STICC calibrate step"
  require_text "$f" 'tell them to propagate it' "STICC propagation"
  require_text "$f" '### 5W1H as a planning aid' "the optional 5W1H section"
  require_text "$f" 'not a required message format' "5W1H optionality"
  require_text "$f" '### ETA and self-reminder' "the ETA self-reminder section"
  require_text "$f" 'With `--once` it delivers at the next matching time' "the one-shot schedule caveat"
  require_text "$f" 'within 24 hours' "the one-shot horizon"
  require_text "$f" 'do not pass `--to`' "self-targeted schedule ownership"
  require_text "$f" 'reserved sender `schedule`' "the standing schedule-mail warning"
  require_text "$f" 'created by your current Butler identity' "identity-based schedule ownership"
  require_text "$f" 'the add asks for confirmation' "the owner-terminal schedule path"
  require_text "$f" 'steps 5, 6, 10, 12, 15, 20 or 30' "the exact cron step list"
  require_text "$f" "request's expiry (default" "the displayed approval expiry"
  require_text "$f" 'approval_ttl_minutes' "the configurable approval TTL"
  require_text "$f" '8 KiB of normalized text' "the normalized 8 KiB limit"
  require_text "$f" 'live Matrix sync and prepared-text approval on' "the approval prerequisites"
  require_text "$f" 'typed (seen)' "the typed(seen) observation caveat"
  require_text "$f" 'does not approve prepared text' "the owner-Matrix-only approval rule"
  if grep -qF 'Adding and removing schedules require the owner at a terminal' "$OUT/$f"; then
    echo "FAIL golden guidance: $f still says schedules need the owner at a terminal" >&2; exit 1
  fi
  if grep -qF 'Requests expire after 60 minutes' "$OUT/$f"; then
    echo "FAIL golden guidance: $f hardcodes a 60-minute approval expiry" >&2; exit 1
  fi
done
for f in agents-topic.md agents-launch.md welcome.txt; do
  require_text "$f" 'add one for your own session' "scheduler self-service ownership"
  require_text "$f" 'Your session is the target' "the member's own schedule target"
done
require_text agents-root.md 'Add one for the Butler session' "the root's own schedule target"
require_text agents-root.md 'The Butler session is the target' "the root command as confirmation"
require_text agents-root.md '## Orchestrator communication' "the orchestrator communication section"
require_text agents-root.md 'Report progress and results relatively' "frequent owner reporting"
require_text agents-root.md 'never call the' "the Matrix-only communication rule"
require_text agents-root.md 'silence is not approval' "the prepared-text approval caveat"
# The member prompt is what the agent sees before it reads AGENTS.md.
require_text argv-claude.txt 'explain the assignment using STICC' "the STICC prompt cue"
require_text argv-claude.txt 'Use 5W1H as an optional planning aid' "the 5W1H prompt cue"
require_text argv-claude.txt 'self-targeted' "the ETA self-reminder prompt cue"

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
