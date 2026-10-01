#!/usr/bin/env bash
# The root Butler's permission rule against a private daemon and a stub claude:
# written at launch, respawn and once per mod load, never on the reconcile tick,
# and never for a member.
#   REMUDA_BIN=~/.local/bin/remuda tests/butler_permissions.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
REMUDA_BIN=${REMUDA_BIN:-remuda}
REMUDA_BIN=$(command -v "$REMUDA_BIN")
# /tmp, not $TMPDIR: the daemon socket path must stay under the 103-byte sun_path limit (#163).
SCRATCH=$(mktemp -d /tmp/bp.XXXXXX)
SCRATCH=$(cd "$SCRATCH" && pwd -P)
SERVER=butler-perm
export HOME=$SCRATCH/home XDG_CONFIG_HOME=$SCRATCH/config XDG_DATA_HOME=$SCRATCH/data
export REMUDA_RUNTIME_DIR=$SCRATCH/r REMUDA_NO_UPDATE_CHECK=1 REMUDA_BUTLER_PROJECT_HOME=$SCRATCH/projects
export REMUDA_BUTLER_AGENT_ORDER=claude
unset REMUDA_SERVER REMUDA_BUTLER_AGENT_ID REMUDA_BUTLER_LEADER_ID REMUDA_BUTLER_SESSION_NAME \
  REMUDA_BUTLER_AGENT_ALIAS REMUDA_BUTLER_AGENT_KIND REMUDA_SESSION_CAPABILITY
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/remuda/mods/butler" "$REMUDA_RUNTIME_DIR" "$SCRATCH/bin"
tar -c -C "$REPO" extension.toml packages | tar -x -C "$XDG_DATA_HOME/remuda/mods/butler"
cleanup() {
  if [[ ${REMUDA_RUNTIME_DIR:-} == "$SCRATCH/r" ]]; then
    "$REMUDA_BIN" -s "$SERVER" stop -f >/dev/null 2>&1 || true
  fi
  chmod -R u+rwx "$SCRATCH" 2>/dev/null || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
cat > "$SCRATCH/bin/claude" <<'STUB'
#!/bin/sh
printf '─\n❯\n'
sleep 300
STUB
chmod +x "$SCRATCH/bin/claude"
export PATH="$SCRATCH/bin:/usr/bin:/bin"

RULE='Bash(remuda butler:*)'
ROOT=$XDG_DATA_HOME/remuda/butler/sessions/butler
FILE=$ROOT/.claude/settings.local.json
lua() { "$REMUDA_BIN" -s "$SERVER" -e "$1"; }
mtime() { perl -e 'print((stat shift)[9])' "$1"; }
mode() { perl -e 'printf "%o", (stat shift)[2] & 0777' "$1"; }
wait_up() {
  for _ in $(seq 150); do
    "$REMUDA_BIN" -s "$SERVER" butler status 2>/dev/null | grep -qF 'butler: up (claude)' && return 0
    sleep 0.1
  done
  fail "Butler did not come up: $("$REMUDA_BIN" -s "$SERVER" butler status 2>&1)"
}
wait_for() { # description, command...
  for _ in $(seq 100); do "${@:2}" >/dev/null 2>&1 && return 0; sleep 0.1; done
  fail "$1"
}
has_rule() { grep -qF "\"$RULE\"" "$FILE"; }
respawn() {
  lua 'pcall(remuda.close, remuda._butler_name or "butler")' >/dev/null
  sleep 0.5
  wait_up
}

echo "core $("$REMUDA_BIN" --version 2>/dev/null | tail -1) ($REMUDA_BIN)"
"$REMUDA_BIN" -s "$SERVER" daemon >"$SCRATCH/daemon.log" 2>&1 &
for _ in $(seq 50); do [[ -S $REMUDA_RUNTIME_DIR/remuda/$SERVER.sock ]] && break; sleep 0.1; done
"$REMUDA_BIN" -s "$SERVER" exec butler >/dev/null
wait_up

echo "== root_launch_writes_rule, file_is_private"
wait_for "the root launch did not write $FILE" has_rule
[[ $(mode "$FILE") == 600 ]] || fail "settings.local.json is not private: $(mode "$FILE")"
# The mod makes .claude with remuda.fs.mkdir_new; the pinned core (0651664) gives it mode 700.
[[ $(mode "$ROOT/.claude") == 700 ]] || fail "the created .claude directory is not private: $(mode "$ROOT/.claude")"
DOCTOR=$("$REMUDA_BIN" -s "$SERVER" butler doctor 2>&1 || true)
grep -qF "Permissions butler (claude): added 1 rule to $FILE: $RULE (file rewritten: private, mode 600)" <<<"$DOCTOR" \
  || fail "doctor does not show the added rule: $DOCTOR"
[[ $(tail -1 <<<"$DOCTOR") == Next:* ]] || fail "doctor does not end with Next: $DOCTOR"

echo "== tick_does_not_rewrite (3 reconcile ticks)"
BEFORE_FILE=$(mtime "$FILE") BEFORE_AGENTS=$(mtime "$ROOT/AGENTS.md")
sleep 7
[[ $(mtime "$FILE") == "$BEFORE_FILE" ]] || fail "settings.local.json was rewritten on the tick"
[[ $(mtime "$ROOT/AGENTS.md") == "$BEFORE_AGENTS" ]] || fail "AGENTS.md was rewritten on the tick (issue 236)"
rm "$ROOT/AGENTS.md"
wait_for "a deleted AGENTS.md was not written again" test -s "$ROOT/AGENTS.md"

echo "== respawn_readds_removed_rule; the real remuda.json keeps the meaning of everything else"
# The one write goes through remuda.json: keys come back sorted and pretty-printed;
# {} and [] stay distinct, null stays null, allow keeps its order and gains the rule last.
printf '%s' '{"z":{"empty":{},"none":[],"v":null,"n":[1,2.5,9007199254740993],"s":"caf\u00e9"},"permissions":{"deny":["Bash(curl:*)"],"allow":["Bash(ls:*)","Bash(git status:*)"],"ask":[]},"model":"opus"}' >"$FILE"
respawn
wait_for "the respawn did not add the rule again" has_rule
cat >"$SCRATCH/want.json" <<WANT
{
  "model": "opus",
  "permissions": {
    "allow": [
      "Bash(ls:*)",
      "Bash(git status:*)",
      "$RULE"
    ],
    "ask": [],
    "deny": [
      "Bash(curl:*)"
    ]
  },
  "z": {
    "empty": {},
    "n": [
      1,
      2.5,
      9007199254740993
    ],
    "none": [],
    "s": "café",
    "v": null
  }
}
WANT
diff "$SCRATCH/want.json" "$FILE" >"$SCRATCH/diff.out" || fail "the user's settings did not come back with the same meaning: $(cat "$SCRATCH/diff.out")"
BEFORE_FILE=$(mtime "$FILE")
respawn
sleep 1
[[ $(mtime "$FILE") == "$BEFORE_FILE" ]] || fail "a file that already holds the rule was written again"

echo "== malformed and wrong-typed files are left alone"
for content in '{"permissions":' '{"permissions":{"allow":[]},"permissions":{}}' '[]' '{"permissions":{"allow":{}}}' '{"permissions":null}'; do
  printf '%s' "$content" >"$FILE"
  respawn
  sleep 1
  [[ $(cat "$FILE") == "$content" ]] || fail "a file the mod must not edit was changed: $content -> $(cat "$FILE")"
  "$REMUDA_BIN" -s "$SERVER" butler doctor 2>&1 | grep -qE "Permissions butler \(claude\): not written: (not valid JSON|wrong type) — " \
    || fail "doctor does not say why $content was not written"
done

echo "== live_session_gets_rule_once_per_load"
printf '{}' >"$FILE"
sleep 5
has_rule && fail "the rule came back on a tick without a load or a launch"
lua 'remuda.reload("butler")' >/dev/null
wait_up
wait_for "a mod reload with a live Butler did not add the rule" has_rule
printf '{}' >"$FILE"
sleep 5
has_rule && fail "the rule was written more than once per load"

echo "== a rule under deny is withheld"
printf '{"permissions":{"deny":["%s"]}}' "$RULE" >"$FILE"
respawn
sleep 1
[[ $(cat "$FILE") == '{"permissions":{"deny":["'"$RULE"'"]}}' ]] || fail "a file with the rule under deny was changed: $(cat "$FILE")"
"$REMUDA_BIN" -s "$SERVER" butler doctor 2>&1 | grep -qF "withheld $RULE — listed under deny in $FILE" \
  || fail "doctor does not say the rule is withheld"

echo "== symlink_is_not_written"
rm "$FILE"
printf '{}' >"$SCRATCH/elsewhere.json"
ln -s "$SCRATCH/elsewhere.json" "$FILE"
respawn
sleep 1
[[ -L $FILE && $(cat "$SCRATCH/elsewhere.json") == '{}' ]] || fail "the mod wrote through or over a symlink"
"$REMUDA_BIN" -s "$SERVER" butler doctor 2>&1 | grep -qF "not written: is a symlink — $FILE" \
  || fail "doctor does not name the symlink"

echo "== launch_survives_unwritable_dir"
rm "$FILE"
chmod 500 "$ROOT/.claude"
respawn
[[ ! -e $FILE ]] || fail "a file appeared in a read-only directory"
"$REMUDA_BIN" -s "$SERVER" butler doctor 2>&1 | grep -qF "Permissions butler (claude): not written: " \
  || fail "doctor does not report the failed write"
chmod 700 "$ROOT/.claude"

echo "== member_launch_writes_nothing"
"$REMUDA_BIN" -s "$SERVER" butler launch claude w1 >/dev/null
wait_for "member w1 did not start" test -d "$XDG_DATA_HOME/remuda/butler/sessions/w1"
sleep 2
[[ ! -e $XDG_DATA_HOME/remuda/butler/sessions/w1/.claude ]] || fail "a member got a .claude directory"

echo "== traced"
grep -qE 'permissions_added' -r "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" 2>/dev/null || fail "the write was not traced"
echo "butler_permissions.sh ok"
