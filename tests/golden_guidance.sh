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
# Needs: bash, git, python3 (and cargo when REMUDA_BIN is unset).
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
unset REMUDA_BUTLER_TOKEN REMUDA_BUTLER_CONFIG REMUDA_BUTLER_AGENT_ID REMUDA_BUTLER_LEADER_ID \
  REMUDA_BUTLER_SESSION_NAME REMUDA_BUTLER_AGENT_ALIAS REMUDA_BUTLER_AGENT_KIND REMUDA_SESSION_CAPABILITY
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" \
  "$T/bin" "$T/argv" "$T/projects" "$XDG_DATA_HOME/remuda/mods/butler"
cp "$REMUDA_BIN" "$T/bin/remuda"
cp -R "$REPO/extension.toml" "$REPO/packages" "$XDG_DATA_HOME/remuda/mods/butler/"
# A fake claude: records its argv, one argument per NUL-free line, and stays up.
cat >"$T/bin/claude" <<EOF
#!/usr/bin/env python3
import os, sys, time
open("$T/argv/" + os.environ.get("REMUDA_BUTLER_SESSION_NAME", "x"), "w").write("\n".join(sys.argv[1:]) + "\n")
print("─\n❯", flush=True)
while True: time.sleep(1)
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
cat "$T/welcome-inbox.txt" | python3 -c '
import re, sys
text = sys.stdin.read()
m = re.search(r"^\[[^\]]*\] Welcome to Butler\n(.*?)(?=^\[message-|^\[[0-9A-HJKMNP-TV-Z]{26} from |\Z)", text, re.S | re.M)
sys.stdout.write(m.group(1) if m else "NO WELCOME MESSAGE\n" + text)' >"$OUT/welcome.txt"
cp "$T/argv/lead1" "$OUT/argv-claude.txt"

# Normalise run-specific values so only guidance text is compared.
python3 - "$OUT" "$T" <<'PY'
import os, re, sys
out, t = sys.argv[1], sys.argv[2]
subs = [
    (re.escape(os.path.realpath(t)), "<T>"), (re.escape(t), "<T>"),
    (r"/(?:private/)?(?:tmp|var/folders)/[^\s\"']*lua_[A-Za-z0-9]+[^\s\"']*", "<TMPFILE>"),
    (r"message-[0-9a-f]+-[0-9a-f]+-lua_[A-Za-z0-9]+", "<MSGID>"),
    (r"\b[0-9A-HJKMNP-TV-Z]{26}\b", "<ULID>"),
    (r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z", "<TIME>"),
    (r'("REMUDA_SESSION_CAPABILITY"\s*:\s*")[^"]+', r"\1<CAP>"),
    (r"(REMUDA_SESSION_CAPABILITY=\"?)[A-Za-z0-9_-]+", r"\1<CAP>"),
]
for name in sorted(os.listdir(out)):
    p = os.path.join(out, name); s = open(p).read()
    for pat, rep in subs: s = re.sub(pat, rep, s)
    open(p, "w").write(s)
PY

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
