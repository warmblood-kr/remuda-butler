-- remuda-butler: runs one Claude Code session, optionally bridged to Matrix
-- and replying there via an MCP tool. See docs/design.md.

local HELPER_SRC = [==[
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

TOKEN_PATH, CONFIG_PATH = sys.argv[1], sys.argv[2]
TOKEN = Path(TOKEN_PATH).read_text().strip()
_lines = Path(CONFIG_PATH).read_text().splitlines()
HOMESERVER, ROOM_ID, SELF_MXID = _lines[0].strip(), _lines[1].strip(), _lines[2].strip()
ALLOWED_SENDERS = set()
if len(_lines) > 3 and _lines[3].strip():
    ALLOWED_SENDERS = {s.strip() for s in _lines[3].split(",") if s.strip()}

SYNC_TIMEOUT_MS = 30000
SINCE_FILE = Path(CONFIG_PATH + ".since")


def load_since():
    if SINCE_FILE.exists():
        try:
            return json.loads(SINCE_FILE.read_text()).get("since")
        except (ValueError, AttributeError):
            return None
    return None


def save_since(token):
    tmp = SINCE_FILE.with_name(SINCE_FILE.name + ".tmp")
    tmp.write_text(json.dumps({"since": token}))
    tmp.replace(SINCE_FILE)


def matrix_get(path, params=None):
    url = HOMESERVER + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + TOKEN})
    with urllib.request.urlopen(req, timeout=(SYNC_TIMEOUT_MS / 1000) + 10) as resp:
        return json.loads(resp.read())


def emit(sender, body):
    # Backslash escaped FIRST, then newline, so the result can never itself
    # contain a raw newline: remuda.process's pipe is strictly line-oriented,
    # so one Matrix event must become exactly one physical output line.
    escaped = body.replace("\\", "\\\\").replace("\n", "\\n")
    sys.stdout.write(sender + "\t" + escaped + "\n")
    sys.stdout.flush()


def handle_room(room):
    for ev in room.get("timeline", {}).get("events", []):
        if ev.get("type") != "m.room.message":
            continue
        sender = ev.get("sender")
        if sender == SELF_MXID:
            continue
        # Sender allowlist: only a configured human account may reach the
        # session. `--permission-mode auto` gives that session shell access
        # with no per-call confirmation, so anyone else in the room must
        # never be able to feed it input.
        if sender not in ALLOWED_SENDERS:
            continue
        content = ev.get("content", {})
        if content.get("msgtype") not in ("m.text", "m.notice", "m.emote"):
            continue
        emit(sender, content.get("body", ""))


def main():
    since = load_since()
    if since is None:
        # First run: establish a baseline without replaying room history.
        resp = matrix_get("/_matrix/client/v3/sync", {"timeout": "0"})
        since = resp["next_batch"]
        save_since(since)

    while True:
        try:
            resp = matrix_get(
                "/_matrix/client/v3/sync",
                {"since": since, "timeout": str(SYNC_TIMEOUT_MS)},
            )
        # Deliberately broad: a relay must outlive every transport failure,
        # not just urllib.error.URLError (a killed connection mid-request
        # raises ConnectionResetError/RemoteDisconnected, which is not one).
        except Exception:
            time.sleep(5)
            continue

        # Allowlist: only ever look at the one configured room. Never
        # iterate any other key of resp["rooms"]["join"].
        room = resp.get("rooms", {}).get("join", {}).get(ROOM_ID)
        if room:
            handle_room(room)

        since = resp["next_batch"]
        save_since(since)


if __name__ == "__main__":
    main()
]==]

local REPLY_SRC = [==[
set -euo pipefail

TOKEN="$(cat "$1")"
HOMESERVER="$(sed -n '1p' "$2")"
ROOM_ID="$(sed -n '2p' "$2")"
TEXT="$3"

TXN_ID="remuda-butler-$(date +%s%N)"
BODY_JSON="$(python3 -c 'import json,sys; print(json.dumps({"msgtype":"m.text","body":sys.argv[1]}))' "$TEXT")"
ENC_ROOM="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$ROOM_ID")"

# The Authorization header carries the bearer token; passing it via -H would
# put the token in this process's own argv, visible to any other user via
# `ps`. -K - reads curl's config (here, just the one header) from stdin
# instead, which never appears in argv.
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -sf -K - -X PUT \
  "$HOMESERVER/_matrix/client/v3/rooms/$ENC_ROOM/send/m.room.message/$TXN_ID" \
  -H "Content-Type: application/json" \
  -d "$BODY_JSON" >/dev/null
]==]

-- Claude calls statusLine commands with a JSON snapshot on stdin.  This
-- helper is deliberately the sole producer of Butler's telemetry: it emits a
-- fixed marker for people in the terminal and atomically publishes that exact
-- marker to a private file for `butler_status`.  Reading Claude's terminal
-- would make the latter depend on escape sequences and layout rather than the
-- protocol Claude itself supplies.
local STATUSLINE_SRC = [==[
import json
import os
import re
import sys

path = sys.argv[1]

def tag(value):
    if not isinstance(value, str) or not value:
        return "?"
    value = re.sub(r"[^A-Za-z0-9_.-]+", "-", value).strip("-")
    return value or "?"

def integer(value):
    return str(int(value)) if isinstance(value, (int, float)) else "?"

try:
    snapshot = json.load(sys.stdin)
except Exception:
    snapshot = {}

window = snapshot.get("context_window") or {}
used = window.get("total_input_tokens")
if not isinstance(used, (int, float)):
    current = window.get("current_usage") or {}
    parts = [current.get(key) for key in (
        "input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")]
    parts = [part for part in parts if isinstance(part, (int, float))]
    used = sum(parts) if parts else None

model = snapshot.get("model") or {}
line = "MODEL:{model} CTX:{used} CTXWIN:{capacity} CTXPCT:{percent}".format(
    model=tag(model.get("display_name") or model.get("id")),
    used=integer(used),
    capacity=integer(window.get("context_window_size")),
    percent=integer(window.get("used_percentage")),
)

try:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as out:
        out.write(line + "\n")
    os.replace(tmp, path)
except Exception:
    # A status line must never make Claude's UI fail merely because its
    # observer cannot write (for example a cleaned-up temporary directory).
    pass
print(line)
]==]

-- This is the one service session installed by the package, not an ordinary
-- user-created session. Its stable name is its public control surface:
-- `remuda send butler ...`, installer liveness checks, and restart recovery
-- must never depend on the directory that happened to start the daemon.
local function initial_butler_name()
  return "butler"
end

-- Exposed so tests can extract the exact embedded source without triggering
-- the side effects below (starting a real process/session needs real
-- config this test harness doesn't have, and shouldn't start one anyway).
remuda._butler_helper_src = HELPER_SRC
remuda._butler_reply_src = REPLY_SRC
remuda._butler_statusline_src = STATUSLINE_SRC
remuda._butler_initial_name = initial_butler_name()

-- The command handler runs in the daemon, so identity comes only from the
-- caller's `REMUDA_*` variables that core forwards in `caller.env` (#95) --
-- never `os.getenv`, which is whatever session happened to birth the daemon.
-- No forwarded identity (a plain shell, or an older core) is the operator.
local OPERATOR = "operator"
local function current_agent(caller)
  local env = caller and caller.env or {}
  for _, key in ipairs({ "REMUDA_BUTLER_AGENT_ID", "REMUDA_BUTLER_SESSION_NAME" }) do
    if env[key] and env[key] ~= "" then return env[key] end
  end
end
remuda._butler_current_agent = current_agent
if remuda._butler_test_mode then
  return
end

-- `os.getenv` here reads the *daemon's own* environment, fixed forever at
-- whichever moment first birthed that daemon (see docs/install-butler.sh's
-- ceiling comment) -- so a butler-specific env var as the primary source
-- means anything else that races to auto-start a daemon first leaves no
-- later `exec butler` call able to inject a corrected value (that's the bug
-- this resolves). `HOME` (or `XDG_CONFIG_HOME`) is present in essentially
-- every process's environment regardless of what happened to birth the
-- daemon (the known exception: a systemd *system* unit with `User=` set but
-- no PAM session, or a process launched via `env -i`) -- `resolve_path`
-- below fails loudly by name when it's genuinely absent, rather than
-- guessing. `REMUDA_BUTLER_TOKEN`/`REMUDA_BUTLER_CONFIG` remain a supported
-- override, checked first, for a caller who wants a different location --
-- this is also what keeps every existing test that sets them via
-- `Daemon::spawn_with_env` unchanged. Mirrors install-butler.sh's own
-- `${XDG_CONFIG_HOME:-$HOME/.config}/remuda/butler/{token,config}` exactly,
-- kept in sync with install-butler.sh's own default by
-- scripts/check-butler-path-convention.py, which fails if the two diverge.
local function default_config_home()
  local xdg = os.getenv("XDG_CONFIG_HOME")
  if xdg and xdg ~= "" then
    return xdg
  end
  local home = os.getenv("HOME")
  if not home or home == "" then
    return nil
  end
  return home .. "/.config"
end

local function default_data_home()
  local xdg = os.getenv("XDG_DATA_HOME")
  if xdg and xdg ~= "" then return xdg end
  local home = os.getenv("HOME")
  return home and home ~= "" and home .. "/.local/share" or nil
end

local function expand_home(path)
  local home = os.getenv("HOME") or ""
  return path:gsub("^~", home)
end

local topic_config = {
  project_home = expand_home(os.getenv("REMUDA_BUTLER_PROJECT_HOME") or "~/projects"),
  templates = {},
}

remuda.butler = remuda.butler or {}
function remuda.butler.project_home(path)
  topic_config.project_home = expand_home(path)
end
function remuda.butler.template(name, setup)
  topic_config.templates[name] = setup
end

local data_home = default_data_home()
local butler_session_cwd = data_home and data_home .. "/remuda/butler/sessions/butler"
local mail_root = data_home and data_home .. "/remuda/butler/mail"

-- Fails loudly when Matrix has been configured -- naming the exact path it
-- tried and mentioning the override -- rather than silently proceeding with
-- a path that doesn't resolve to a real file.
local function resolve_path(override_env, filename, what)
  local path = os.getenv(override_env)
  if not path or path == "" then
    local config_home = default_config_home()
    if not config_home then
      error(
        "remuda-butler: HOME is not set and " .. override_env .. " was not "
          .. "given -- cannot locate the " .. what,
        0
      )
    end
    path = config_home .. "/remuda/butler/" .. filename
  end
  local f = io.open(path, "r")
  if not f then
    error(
      "remuda-butler: no " .. what .. " at " .. path .. " -- create it, or "
        .. "set " .. override_env .. " to override",
      0
    )
  end
  f:close()
  return path
end

local function file_exists(path)
  if not path then
    return false
  end
  local f = io.open(path, "r")
  if not f then
    return false
  end
  f:close()
  return true
end

local function load_topic_config()
  local path = os.getenv("REMUDA_BUTLER_TOPICS")
    or (default_config_home() and default_config_home() .. "/remuda/butler/topics.lua")
  if not path or not file_exists(path) then return end
  local configured = assert(loadfile(path))()
  if configured == nil then return end
  assert(type(configured) == "table", "Butler topics config must return a table")
  if configured.project_home then remuda.butler.project_home(configured.project_home) end
  for name, setup in pairs(configured.templates or {}) do remuda.butler.template(name, setup) end
end

-- Matrix is an optional Butler integration. An explicit override means its
-- caller intended to enable it, and either conventional credential file
-- means a half-configured relay should still fail loudly. With neither,
-- Butler remains a local Claude-session manager and simply omits the relay.
local token_override = os.getenv("REMUDA_BUTLER_TOKEN")
local config_override = os.getenv("REMUDA_BUTLER_CONFIG")
local config_home = default_config_home()
local default_token_path = config_home and config_home .. "/remuda/butler/token"
local default_config_path = config_home and config_home .. "/remuda/butler/config"
local matrix_requested = (token_override and token_override ~= "")
  or (config_override and config_override ~= "")
  or file_exists(default_token_path)
  or file_exists(default_config_path)

local token_path = nil
local config_path = nil
if matrix_requested then
  token_path = resolve_path("REMUDA_BUTLER_TOKEN", "token", "token file")
  config_path = resolve_path("REMUDA_BUTLER_CONFIG", "config", "config file")
end

-- The session needs an `--mcp-config` pointing back at this same daemon, or
-- it has no way to reach `matrix_reply` at all — a bare `remuda.new(nil,
-- {"claude"})` starts a session with no MCP server configured. `claude`
-- only accepts that config as a file path, never inline JSON, so this is a
-- legitimate, unavoidable use of `io`/`os` (unlike embedding a companion
-- script, which argv already handles without touching a file).
-- `REMUDA_BUTLER_SERVER` names the running daemon's own `-s <name>`, so the
-- spawned `remuda ... mcp` reaches the exact instance running this code,
-- not some other "default" one; it defaults to "default" to match the CLI's
-- own default when no `-s` flag was given. `--permission-mode auto` skips
-- the second, tool-call permission dialog entirely (its default is "Yes",
-- the opposite framing from the trust dialog's "No, exit" — measured in
-- native/tests/claude_session.rs) since nothing here can answer it.
local server = os.getenv("REMUDA_BUTLER_SERVER") or "default"
local runtime_dir = os.getenv("REMUDA_RUNTIME_DIR")
-- Matrix-enabled installs keep this beside their relay configuration. The
-- local-only mode has no configuration directory to rely on, so use a private
-- temporary filename for the same short-lived Claude MCP configuration.
local mcp_config_path = config_path and (config_path .. ".mcp.json") or (os.tmpname() .. ".mcp.json")
local status_path = remuda._butler_status_path
  or (config_path and (config_path .. ".status") or (os.tmpname() .. ".status"))
local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\\"'\\\"'") .. "'"
end
local function json_quote(s)
  return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"')
    :gsub('\r', '\\r'):gsub('\n', '\\n'):gsub('\t', '\\t') .. '"'
end
local function status_settings(path)
  local helper_path = path .. ".py"
  local settings_path = path .. ".settings.json"
  local helper = assert(io.open(helper_path, "w"))
  helper:write(STATUSLINE_SRC)
  helper:close()
  local settings = assert(io.open(settings_path, "w"))
  settings:write('{"statusLine":{"type":"command","command":'
    .. json_quote("python3 " .. shell_quote(helper_path) .. " " .. shell_quote(path))
    .. ',"refreshInterval":2}}')
  settings:close()
  return settings_path
end
remuda._butler_status_path = status_path

remuda.tool{
  name = "butler_status",
  about = "Read Butler's latest Claude Code status-line telemetry: model, context tokens, window, and percentage.",
  run = function()
    local f = io.open(remuda._butler_status_path or "", "r")
    if not f then
      return "MODEL:? CTX:? CTXWIN:? CTXPCT:? (no status reading yet)"
    end
    local line = f:read("*l")
    f:close()
    -- The helper owns this file.  Refuse a malformed or externally replaced
    -- record instead of presenting arbitrary file contents as Claude status.
    if not line or not line:match("^MODEL:[A-Za-z0-9_.%-?]+ CTX:[0-9?]+ CTXWIN:[0-9?]+ CTXPCT:[0-9?]+$") then
      error("butler status record is malformed", 0)
    end
    return line
  end,
}

-- A small, cooperative post office for every agent Butler launches.  This is
-- deliberately live-image state, like Emacs: callers may inspect or extend it
-- through `run_script`.  `caller.capability` is attribution supplied by that
-- session's MCP child, not an access-control boundary.
remuda._butler_bus = remuda._butler_bus or {
  agents = {}, tokens = {}, inboxes = {}, messages = {}, objects = {}, next = 0,
}
local bus = remuda._butler_bus
bus.pending_tasks = bus.pending_tasks or {}

-- Contribution points (hook-design §4): core's owned registry when this core
-- has one (remuda#141), else Butler's own with the same order rules, on bus.
bus.contributions = bus.contributions or {}
function remuda._butler_contribute(point, id, entry)
  if remuda.contribute then return remuda.contribute(point, id, entry) end
  bus.contributions[point] = bus.contributions[point] or {}
  bus.contributions[point][id] = entry
end
local function contributions(point)
  if remuda.contributions then return remuda.contributions(point) end
  local rows = {}
  for id, entry in pairs(bus.contributions[point] or {}) do rows[#rows + 1] = { id = id, entry = entry } end
  table.sort(rows, function(a, b)
    local left, right = a.entry.order or 0, b.entry.order or 0
    if left ~= right then return left < right end
    return a.id < b.id
  end)
  return rows
end
bus.messages = bus.messages or {}
bus.objects = bus.objects or {}
-- ULIDs are durable public identities; session names remain the mutable,
-- human-friendly keys used by the mailbox and the in-memory team tree.
local alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
local function crockford_ulid()
  local millis = math.floor(os.time() * 1000)
  local bytes = {}
  for i = 6, 1, -1 do bytes[i] = millis % 256; millis = math.floor(millis / 256) end
  local random = io.open("/dev/urandom", "rb")
  local entropy = random and random:read(10)
  if random then random:close() end
  if not entropy or #entropy ~= 10 then
    math.randomseed(os.time() + math.floor(os.clock() * 1000000))
    local out = {}
    for i = 1, 10 do out[i] = string.char(math.random(0, 255)) end
    entropy = table.concat(out)
  end
  for i = 1, 10 do bytes[i + 6] = entropy:byte(i) end
  local bits, out = { 0, 0 }, {}
  for _, byte in ipairs(bytes) do
    for bit = 7, 0, -1 do bits[#bits + 1] = math.floor(byte / (2 ^ bit)) % 2 end
  end
  -- ULIDs have two zero padding bits before the 128-bit payload.
  for group = 0, 25 do
    local n = 0
    for j = 1, 5 do n = n * 2 + bits[group * 5 + j] end
    out[#out + 1] = alphabet:sub(n + 1, n + 1)
  end
  return table.concat(out)
end
local function is_ulid(value)
  return type(value) == "string" and #value == 26
    and value:match("^[0-9A-HJKMNP-TV-Z]+$") ~= nil
end
local identity_path = data_home and data_home .. "/remuda/butler/agents.jsonl"
bus.identities = bus.identities or {}
bus.identity_ids = bus.identity_ids or {}
-- Loaded before identity_record so agents.jsonl shares mail.lua's append.
remuda._butler_mail_config = { bus = bus, root = mail_root, json_quote = json_quote }
remuda.exec("butler/mail")
local function identity_record(id, alias, kind, leader_id, ended)
  if not identity_path then return end
  local dir = identity_path:match("^(.*)/[^/]+$")
  if dir then os.execute("mkdir -p " .. shell_quote(dir)) end
  local row = '{"id":' .. json_quote(id) .. ',"alias":' .. json_quote(alias)
    .. ',"kind":' .. json_quote(kind or "") .. ',"leader_id":' .. json_quote(leader_id or "")
    .. ',"created_at":' .. json_quote(os.date("!%Y-%m-%dT%H:%M:%SZ"))
  if ended then row = row .. ',"ended_at":' .. json_quote(os.date("!%Y-%m-%dT%H:%M:%SZ")) end
  remuda._butler_mail.append(identity_path, row .. "}\n")
end
local function json_field(line, key)
  local quoted = line:match('"' .. key .. '":(".-")')
  if not quoted then return nil end
  local value = quoted:sub(2, -2)
  return (value:gsub('\\(.)', function(c)
    if c == "n" then return "\n" elseif c == "r" then return "\r"
    elseif c == "t" then return "\t" else return c end
  end))
end
if identity_path and not bus.identities_loaded then
  local f = io.open(identity_path, "r")
  if f then
    for line in f:lines() do
      local id, alias = json_field(line, "id"), json_field(line, "alias")
      if id and alias then
        local record = { id = id, alias = alias, kind = json_field(line, "kind"),
          leader_id = json_field(line, "leader_id"), ended_at = json_field(line, "ended_at") }
        bus.identity_ids[id] = record
        bus.identities[alias] = record
      end
    end
    f:close()
  end
  -- A fresh image after `stop -f`: its agents died with the daemon and no
  -- `session_exited` recorded them, so end each identity with no live session
  -- (#24). The root keeps its identity across daemons and is never ended.
  local live = {}
  for _, session in ipairs(remuda.ls()) do
    if session.alive then live[session.name] = true end
  end
  for id, record in pairs(bus.identity_ids) do
    if not record.ended_at and record.alias ~= "butler" and not live[record.alias] then
      identity_record(id, record.alias, record.kind, record.leader_id, true)
      record.ended_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    end
  end
  bus.identities_loaded = true
end
local function register_identity(alias, kind, leader_id, id)
  id = id or crockford_ulid()
  local record = { id = id, alias = alias, kind = kind, leader_id = leader_id or "" }
  bus.identities[alias], bus.identity_ids[id] = record, record
  identity_record(id, alias, kind, leader_id)
  return record
end
local function resolve(ref)
  if is_ulid(ref) then
    local record = bus.identity_ids[ref]
    if record and bus.agents[record.alias] and bus.agents[record.alias].id == ref then return record.alias end
    error("no live Butler agent with id " .. ref, 0)
  end
  local live = bus.agents[ref]
  if live then return ref end
  local last = bus.identities[ref]
  error("alias " .. tostring(ref) .. " has no live agent; last was " .. (last and last.id or "unknown"), 0)
end
local function mail_address(alias)
  local agent = bus.agents[alias]
  if not agent then
    return { host = "local", id = "", alias = alias or "outside", session = alias or "outside", kind = "", leader = "" }
  end
  local parent = agent.parent and bus.agents[agent.parent]
  return { host = "local", id = agent.id or "", alias = agent.alias or alias,
    session = agent.alias or alias, kind = agent.kind or "", leader = parent and parent.id or "" }
end
local function mail_id(ref, allow_ended)
  if is_ulid(ref) then
    local record = bus.identity_ids[ref]
    if not record then error("no Butler agent with id " .. tostring(ref), 0) end
    local live = bus.agents[record.alias]
    if live and live.id == ref then return ref, live end
    if allow_ended then return ref, nil end
    error("agent " .. ref .. " (alias " .. tostring(record.alias) .. ") has ended", 0)
  end
  -- An ended alias's mail is still worth reading (#23): an inbox read falls
  -- back to the alias's last identity instead of demanding its ULID.
  local last = bus.identities[ref]
  if allow_ended and not bus.agents[ref] and last then return last.id, nil end
  local alias = resolve(ref)
  local agent = bus.agents[alias]
  return agent.id, agent
end
remuda._butler_resolve = resolve
remuda._butler_new_ulid = crockford_ulid
local function next_token(name)
  bus.next = bus.next + 1
  return name .. "-" .. os.time() .. "-" .. bus.next
end
local function caller_name(caller)
  local current = current_agent(caller)
  if current then
    local ok, alias = pcall(resolve, current)
    if ok then return alias end
  end
  local token = caller and caller.capability
  return (token and bus.tokens[token]) or "outside"
end
-- An MCP caller that acts on mail must be a known agent: an unknown or garbage
-- capability is refused, never treated as the operator (review of #39).
local function caller_agent(caller)
  local name = caller_name(caller)
  if not bus.agents[name] then
    error("unknown caller: run from a Butler session (its MCP config carries the capability)", 0)
  end
  return name
end
-- A child's leader is the calling agent, never a guess: an unidentified
-- caller silently became `butler`'s child and reported to root (#24).
local function caller_leader(caller)
  local parent = caller_name(caller)
  if not bus.agents[parent] then
    error("unknown caller: run from a Butler session, or pass an explicit leader"
      .. " with `remuda butler topic delegate --leader NAME`", 0)
  end
  return parent
end
local mail = assert(remuda._butler_mail)
local mailbox = mail.mailbox
local queue_message = mail.queue
local migrate_legacy_mail = mail.migrate_legacy
remuda._butler_migrate_legacy_mail = migrate_legacy_mail
local delivery_events = type(remuda.emit_until_success) == "function"
local function inbox_delivery(message)
  local delivered, why
  if message.kind == "forward" then
    delivered, why = mail.forward_delivery(message)
  else
    delivered, why = queue_message(message.from, message.to, message.text, message.subject,
      message.in_reply_to, message.references)
  end
  if not delivered then
    message.delivery_error = why
    return nil
  end
  return delivered
end
local function deliver_message(message)
  if delivery_events then
    local delivered = remuda.emit_until_success("butler/deliver", message)
    if delivered == nil then
      error(message.delivery_error or "no Butler channel installed (try remuda-butler-inbox)", 0)
    end
    return delivered
  end
  local delivered, why
  if message.kind == "forward" then
    delivered, why = mail.forward_delivery(message)
  else
    delivered, why = queue_message(message.from, message.to, message.text, message.subject,
      message.in_reply_to, message.references)
  end
  if not delivered then error(why or "no Butler channel installed (try remuda-butler-inbox)", 0) end
  return delivered
end
local function agent_mcp_json(token)
  local env = '"REMUDA_SESSION_CAPABILITY":"' .. token .. '"'
  if runtime_dir then env = env .. ',"REMUDA_RUNTIME_DIR":"' .. runtime_dir .. '"' end
  return '{"mcpServers":{"remuda":{"command":"remuda","args":["-s","'
    .. server .. '","mcp"],"env":{' .. env .. '}}}}'
end
local function agent_mcp_path(name, token)
  local path = os.tmpname() .. "." .. name .. ".mcp.json"
  local f = assert(io.open(path, "w"))
  f:write(agent_mcp_json(token))
  f:close()
  return path
end
local function agent_mcp_flags(token)
  local env = 'REMUDA_SESSION_CAPABILITY="' .. token .. '"'
  if runtime_dir then env = env .. ',REMUDA_RUNTIME_DIR="' .. runtime_dir .. '"' end
  return {
    "-c", 'mcp_servers.remuda.command="remuda"',
    "-c", 'mcp_servers.remuda.args=["-s","' .. server .. '","mcp"]',
    "-c", "mcp_servers.remuda.env={" .. env .. "}",
  }
end
local function agent_mcp_config(token)
  local env = '"REMUDA_SESSION_CAPABILITY":"' .. token .. '"'
  if runtime_dir then env = env .. ',"REMUDA_RUNTIME_DIR":"' .. runtime_dir .. '"' end
  return '{"mcp_servers":{"remuda":{"command":"remuda","args":["-s","'
    .. server .. '","mcp"],"env":{' .. env .. '}}}}'
end
remuda._butler_agent_builders = remuda._butler_agent_builders or {}
remuda._butler_agent_startup = remuda._butler_agent_startup or {}
remuda._butler_agent_support = {
  mcp_config_path = agent_mcp_path,
  mcp_flags = agent_mcp_flags,
  mcp_config = agent_mcp_config,
  status_settings = status_settings,
}
remuda.exec("butler/telemetry")
remuda.exec("butler/agents/claudecode")
remuda.exec("butler/agents/codex")
local AGENT_BUILDERS = remuda._butler_agent_builders
local TELEMETRY_ADAPTERS = remuda._butler_telemetry_adapters
local function build_agent_argv(kind, spec)
  local builder = AGENT_BUILDERS[kind]
  if not builder then error("unknown agent kind: " .. tostring(kind), 0) end
  return builder(spec)
end
local function setup_telemetry(kind, spec)
  local adapter = TELEMETRY_ADAPTERS[kind]
  return adapter and adapter.setup and adapter.setup(spec) or {}
end
-- A member's AGENTS.md and prompt are `butler.guidance` sections joined in
-- order, so an extension adds its own section (hook-design §4.2).
remuda._butler_contribute("butler.guidance", "header", { order = 10,
  agents_md = function(ctx)
    return [[# Butler team member

You are a Butler team member. Your leader is ]] .. ctx.parent .. [[. Work on the
task sent to this terminal. Your Butler identity is already in
`REMUDA_BUTLER_AGENT_ID`, and your leader is in `REMUDA_BUTLER_LEADER_ID`.
Start by running `remuda butler inbox` to read your welcome message.

]]
  end,
  prompt = function()
    return "You are a Butler team member. Start by running `remuda butler inbox` to read "
      .. "your welcome message, then read AGENTS.md in your working directory. "
  end })
remuda._butler_contribute("butler.guidance", "cli", { order = 20,
  agents_md = function()
    return [[Use Butler's CLI for communication:

- `remuda butler inbox` reads your own queued messages.
- `remuda butler send MEMBER "MESSAGE"` sends a message; your sender is inferred.
  Quote the message: a second unquoted word makes it `send FROM TO ...`.
- `remuda butler send-to-leader RESULT...` reports a completed work loop.
- `remuda butler sessions` shows the household.

]]
  end,
  prompt = function()
    return "Use `remuda butler inbox`, `remuda butler send MEMBER \"MESSAGE\"`, and "
      .. "`remuda butler send-to-leader RESULT...` for coordination. "
  end })
remuda._butler_contribute("butler.guidance", "old-core", { order = 30,
  agents_md = function()
    return [[If `inbox` says "no Butler identity in your env", your Remuda core predates
caller-env forwarding: pass your id (`remuda butler inbox
$REMUDA_BUTLER_AGENT_ID`) or use the MCP `butler_*` tools. On such a core,
`send` is attributed to "operator" rather than to you.

]]
  end })
remuda._butler_contribute("butler.guidance", "delegation", { order = 40,
  agents_md = function()
    return [[You may create a Remuda-managed child team with `remuda butler topic delegate
NAME TASK...` when useful. Internal agent subagents are separate from Butler
team members. `remuda butler send FROM TO MESSAGE...` is an operator form, not
the normal way for a member to communicate.
]]
  end })
remuda._butler_contribute("butler.guidance", "leader", { order = 90,
  prompt = function(ctx) return "Your leader is " .. ctx.parent .. "." end })
local function guidance(part, parent)
  local out = {}
  for _, item in ipairs(contributions("butler.guidance")) do
    local render = item.entry[part]
    if render then out[#out + 1] = render({ parent = parent }) or "" end
  end
  return table.concat(out)
end
local function team_member_guidance(parent) return guidance("agents_md", parent) end
local function team_member_prompt(parent) return guidance("prompt", parent) end
local function write_agent_guidance(root, text, replace)
  local path = root .. "/AGENTS.md"
  if not replace and file_exists(path) then return end
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end
local _butler_session_trace -- defined below; the task poke fires later
local function launch_agent(kind, requested_name, cwd, model, parent, task)
  local name = requested_name or kind
  if bus.agents[name] then
    error("alias " .. name .. " is live as " .. tostring(bus.agents[name].id) .. "; pick another alias", 0)
  end
  local parent_identity = parent and bus.agents[parent]
  local identity = register_identity(name, kind, parent_identity and parent_identity.id or "")
  if not cwd and data_home then
    cwd = data_home .. "/remuda/butler/sessions/" .. name
    remuda.mkdir(cwd)
  end
  if cwd and parent then write_agent_guidance(cwd, team_member_guidance(parent)) end
  local token = next_token(name)
  local agent_telemetry = setup_telemetry(kind, { name = name, model = model })
  local argv = build_agent_argv(kind, {
    name = name, token = token, model = model,
    settings_path = agent_telemetry.settings_path,
    telemetry = agent_telemetry,
    system_prompt = parent and team_member_prompt(parent) or nil,
  })
  local actual = remuda.new(name, argv, cwd, {
    REMUDA_BUTLER_SESSION_NAME = name,
    REMUDA_BUTLER_AGENT_ID = identity.id,
    REMUDA_BUTLER_AGENT_ALIAS = name,
    REMUDA_BUTLER_LEADER_ID = parent_identity and parent_identity.id or "",
    REMUDA_BUTLER_AGENT_KIND = kind,
    -- A daemon started from inside Claude Code inherits CLAUDE_CODE_CHILD_SESSION,
    -- which turns off transcript saving and so makes a crashed agent unresumable.
    CLAUDE_CODE_FORCE_SESSION_PERSISTENCE = "1",
  })
  bus.tokens[token] = actual
  bus.agents[actual] = {
    kind = kind, token = token, model = model, telemetry = agent_telemetry,
    parent = parent, children = {}, id = identity.id, alias = actual, session_name = actual,
  }
  if parent and bus.agents[parent] then
    local children = bus.agents[parent].children
    children[#children + 1] = actual
  end
  local migrated, migration_error = migrate_legacy_mail(actual, identity.id)
  if not migrated then error("cannot migrate legacy Butler mail: " .. tostring(migration_error), 0) end
  mailbox(identity.id)
  -- A failed welcome write must not prevent the agent from starting.
  pcall(queue_message, mail_address(parent or "butler"), mail_address(actual),
    team_member_guidance(parent or "butler"), "Welcome to Butler")
  if task and task ~= "" then
    -- Keep an immediate mail notice out of the child's first prompt until the
    -- delegated task has been submitted.
    bus.pending_tasks[actual] = true
    -- Answer known startup modals (agents/*.lua) and type the task only once
    -- the composer is ready; never blind-type into an unknown dialog.
    local startup = remuda._butler_agent_startup[kind] or {}
    local poke, confirm, attempts, settle, deferred = nil, nil, 0, 0, 0
    -- Either timeout means the task never reached the agent: say so to its
    -- leader rather than only in the trace (#29).
    local function give_up(detail)
      remuda.cancel(poke)
      if confirm then remuda.cancel(confirm) end
      bus.pending_tasks[actual] = nil
      _butler_session_trace("task_poke_timeout", actual .. detail)
      pcall(remuda._butler_send, "butler", parent or "butler", "Task for " .. actual
        .. " was not delivered: its pane never became ready or free to type into."
        .. " Resend it with `remuda butler send " .. actual .. " TASK` once it is.")
    end
    poke = remuda.schedule({ every = 0.5, run = function()
      attempts = attempts + 1
      -- A short-lived launcher (or a failed executable) can disappear before
      -- the agent has painted its composer. A deferred poke is best-effort; it
      -- must not leave a throwing callback in the daemon's shared Lua image.
      local captured, screen = pcall(remuda.capture, actual)
      if not captured then
        remuda.cancel(poke)
        bus.pending_tasks[actual] = nil
        return
      end
      if attempts < settle then return end -- let an answered modal repaint
      if not startup.ready or startup.ready(screen) then
        -- #29: never type the task over a human's line. Waiting is bounded
        -- separately (default 600 ticks = 300s); then the leader is told.
        if not remuda._butler_notify_policy(actual) then
          attempts, deferred = attempts - 1, deferred + 1
          if deferred >= (remuda._butler_task_poke_deferrals or 600) then give_up(" deferred") end
          return
        end
        remuda.cancel(poke)
        local typed = pcall(remuda.type_text, actual, task)
        if not typed then
          give_up(" type failed")
          return
        end

        -- A terminal write succeeding does not mean the agent accepted its
        -- Return. Keep notices out until the composer releases the task, and
        -- retry Return if the same task remains in the composer.
        bus.pending_tasks[actual] = task
        local task_line = task:gsub("^%s+", ""):match("^[^\n]*") or ""
        local checks, observed_task = 0, false
        confirm = remuda.schedule({ every = 0.5, run = function()
          checks = checks + 1
          local seen, latest = pcall(remuda.capture, actual)
          if not seen then
            remuda.cancel(confirm)
            bus.pending_tasks[actual] = nil
            return
          end
          local decision, text = remuda._butler_prompt_is_empty(kind, latest)
          local busy = remuda.session(actual).is_busy == true
          local task_in_composer = #task_line > 0 and (text == task_line
            or (#text > 0 and task_line:sub(1, #text) == text))
          if decision == "NON-EMPTY" and task_in_composer then observed_task = true end
          if observed_task and not task_in_composer and (decision == "EMPTY" or busy) then
            remuda.cancel(confirm)
            bus.pending_tasks[actual] = nil
            return
          end
          -- Give the UI time to consume the first Return before retrying.
          if decision == "NON-EMPTY" and task_in_composer and checks >= 4 and checks % 4 == 0 then
            pcall(remuda.key, actual, "RET")
          end
          if checks >= (remuda._butler_task_poke_deferrals or 600) then
            give_up(" submit")
          end
        end })
        return
      end
      for _, modal in ipairs(startup.modals or {}) do
        if screen:find(modal.match, 1, true) then
          _butler_session_trace("startup_modal", actual .. " " .. modal.match)
          for _, key in ipairs(modal.keys) do pcall(remuda.key, actual, key) end
          settle = attempts + 3
          return
        end
      end
      if attempts >= (remuda._butler_task_poke_attempts or 60) then give_up("") end
    end })
  end
  return actual
end

local function make_topic(name, template, kind, parent, task, model)
  load_topic_config()
  local root = topic_config.project_home .. "/" .. name
  remuda.mkdir(root)
  local topic = { name = name, root = root }
  function topic.write(relative_path, contents)
    local f = assert(io.open(root .. "/" .. relative_path, "w"))
    f:write(contents)
    f:close()
  end
  function topic.run(argv)
    local words = { "cd", shell_quote(root), "&&" }
    for _, word in ipairs(argv) do words[#words + 1] = shell_quote(word) end
    local ok, why, code = os.execute(table.concat(words, " "))
    if not ok then
      error("Butler topic command failed (" .. tostring(why) .. " " .. tostring(code) .. "): " .. argv[1], 0)
    end
  end
  if template then
    local setup = topic_config.templates[template]
    assert(setup, "unknown Butler topic template: " .. template)
    assert(type(setup) == "function", "Butler topic template must be a function: " .. template)
    setup(topic)
  end
  write_agent_guidance(root, team_member_guidance(parent or "butler"))
  return launch_agent(kind or "claude", name, root, model, parent, task)
end

-- Shell-facing doors into the same deliberately mutable bus.  These are not
-- capability checks: Butler is a workshop, and the `from` name is simply the
-- attribution a human (or an agent using the CLI) chose to leave on a note.
-- Keeping them on `remuda` also makes the post office pleasant to explore from
-- a REPL without having to know this chunk's private locals.
function remuda._butler_launch(kind, name, model, parent)
  return launch_agent(kind, name, nil, model, resolve(parent or "butler"))
end
function remuda._butler_topic_new(name, template, kind, model)
  return make_topic(name, template, kind, "butler", nil, model)
end
function remuda._butler_topic_delegate(name, task, template, kind, parent, model)
  parent = resolve(parent or "butler")
  local leader = bus.agents[parent]
  if not leader then error("no Butler leader named " .. tostring(parent), 0) end
  return make_topic(name, template, kind or leader.kind, parent, task, model)
end
-- #29: a mail notice must never land on a human's half-typed line. Notices
-- wait per recipient, coalesce, and are typed only when the policy allows;
-- the declared `butler-notices` schedule (init.lua) retries every second.
bus.notices = bus.notices or {}
bus.notice_screens = bus.notice_screens or {}
local NOTICE_STABLE_SECONDS = 3

-- The composer's text: the last line led (after an optional box edge) by a
-- prompt glyph. Returns "EMPTY" (nothing, or exactly one of the kind's
-- `placeholders`), "NON-EMPTY" or "UNPARSEABLE", plus the text. Capture is
-- plain text, so a dim ghost suggestion reads as NON-EMPTY and defers (#137).
local PROMPT_GLYPHS = { "❯", ">", "›" }
function remuda._butler_prompt_is_empty(kind, screen)
  local text
  -- Claude draws its empty composer as '❯' + NO-BREAK SPACE; Lua's %s
  -- misses U+00A0, so fold it to a space before parsing (every kind).
  screen = screen:gsub("\194\160", " ")
  for line in (screen .. "\n"):gmatch("(.-)\n") do
    local rest = line:gsub("^%s+", "")
    if rest:sub(1, 3) == "│" then rest = rest:sub(4):gsub("^%s+", "") end
    for _, glyph in ipairs(PROMPT_GLYPHS) do
      if rest:sub(1, #glyph) == glyph then text = rest:sub(#glyph + 1) break end
    end
  end
  if not text then return "UNPARSEABLE", "" end
  text = text:gsub("│%s*$", ""):match("^%s*(.-)%s*$")
  if text == "" then return "EMPTY", text end
  local startup = remuda._butler_agent_startup[kind] or {}
  for _, placeholder in ipairs(startup.placeholders or {}) do
    if text == placeholder then return "EMPTY", text end
  end
  return "NON-EMPTY", text
end

-- The one delivery policy: may Butler type into SESSION now? Every pane needs
-- a known empty prompt. An attached pane also needs the human to pause
-- (human_idle >= remuda._butler_notice_human_idle, default 10s) or, on a core
-- without human_idle, a screen unchanged for NOTICE_STABLE_SECONDS. Anything
-- unrecognised defers.
function remuda._butler_notify_policy(session, now)
  now = now or os.time()
  local row
  for _, candidate in ipairs(remuda.ls()) do
    if candidate.name == session then row = candidate end
  end
  if not row or not row.alive then return false end
  local attached = row.attached
  local seen = bus.notice_screens[session] or {}
  bus.notice_screens[session] = seen
  local screen
  if attached and row.human_idle ~= nil then
    -- A core with remuda#136 says when the human last typed (math.huge if
    -- never); wait for them to pause instead of guessing from the screen.
    if row.human_idle < (remuda._butler_notice_human_idle or 10) then return false end
  elseif attached then
    -- Older core: a screen unchanged for NOTICE_STABLE_SECONDS stands in.
    local captured
    captured, screen = pcall(remuda.capture, session)
    if not captured then return false end
    if seen.screen ~= screen then
      seen.screen, seen.since = screen, now
      return false
    end
    if now - seen.since < NOTICE_STABLE_SECONDS then return false end
  end
  if remuda.capture_styled then
    -- A core with remuda#137 marks dim text: parse only the cursor row, and
    -- drop a TUI's dim ghost suggestion so it reads as the empty prompt it is.
    local captured, styled = pcall(remuda.capture_styled, session)
    if not captured then return false end
    local parts = {}
    for _, span in ipairs(styled.rows[styled.cursor.row] or {}) do
      if not span.dim then parts[#parts + 1] = span.text end
    end
    screen = table.concat(parts)
  elseif not screen then
    local captured
    captured, screen = pcall(remuda.capture, session)
    if not captured then return false end
  end
  local agent = bus.agents[session]
  local kind = agent and agent.kind or ""
  local decision, text = remuda._butler_prompt_is_empty(kind, screen)
  if seen.decision ~= decision then -- once per change, not every retry
    seen.decision = decision
    _butler_session_trace("notice_prompt", session .. " " .. kind .. " " .. decision .. " " .. text)
  end
  return decision == "EMPTY"
end

-- `_butler_notify` is the seam: queue NOTICE for ALIAS and type it (with any
-- still pending) if the policy allows. Returns delivered, type_text error.
local function deliver_notice(session)
  local pending = bus.notices[session]
  if not pending then return true end
  if bus.pending_tasks[session] then return false end
  if not remuda._butler_notify_policy(session) then return false end
  local text = pending.count == 1 and pending.text
    or (pending.count .. " new Butler messages arrived. Read them: remuda butler inbox")
  local typed, why = pcall(remuda.type_text, session, text)
  -- Keep a notice that failed to type for the next retry; the exit hook
  -- drops it if the session is gone.
  if typed then bus.notices[session] = nil end
  return typed, why
end
function remuda._butler_notify(alias, notice)
  local pending = bus.notices[alias] or { count = 0 }
  pending.count, pending.text = pending.count + 1, notice
  bus.notices[alias] = pending
  return deliver_notice(alias)
end
function remuda._butler_deliver_notices()
  local sessions = {}
  for session in pairs(bus.notices) do sessions[#sessions + 1] = session end
  for _, session in ipairs(sessions) do
    if bus.agents[session] then deliver_notice(session) else bus.notices[session] = nil end
  end
end
-- init.lua declares the schedule; a core before remuda#116 ignores declared
-- schedules, so keep exactly one imperative stand-in there.
if remuda._butler_notice_schedule then remuda.cancel(remuda._butler_notice_schedule) end
remuda._butler_notice_schedule = nil
local declared_notices = false
for _, schedule in pairs(remuda.schedules) do
  if schedule.name == "butler-notices" then declared_notices = true end
end
if not declared_notices then
  remuda._butler_notice_schedule = remuda.schedule({ name = "butler-notices", every = 1,
    run = function() remuda._butler_deliver_notices() end })
end

function remuda._butler_send(from, to, text)
  local _, recipient = mail_id(to, false)
  local sender = (from == "operator" or from == "outside") and mail_address(from)
    or mail_address(resolve(from))
  local message = deliver_message({ from = sender, to = mail_address(recipient.alias), text = text })
  local notice = "Butler message " .. message.id .. " from " .. sender.session
    .. " arrived. Read it: remuda butler inbox"
  local delivered, why = remuda._butler_notify(recipient.alias, notice)
  if delivered then return "queued " .. message.id .. " and notified " .. recipient.alias end
  if why then
    return "queued " .. message.id .. " for " .. recipient.alias .. "; terminal delivery deferred: " .. tostring(why)
  end
  return "queued " .. message.id .. " for " .. recipient.alias .. "; notice deferred until its pane is free"
end
-- Reply and forward live in mail.lua; this adds the caller's identity and the
-- terminal notice. A recipient that has ended still gets the mail, unnotified.
local function sender_address(from)
  if from == OPERATOR then return mail_address(OPERATOR) end
  if from == "outside" then error("unknown caller: run from a Butler session", 0) end
  return mail_address(resolve(from))
end
local function notify_queued(message, alias, what)
  local live = pcall(mail_id, alias, false)
  if not live then return "queued " .. message.id .. " for " .. alias .. "; it is not live, so no notice" end
  local delivered, why = remuda._butler_notify(alias, "Butler message " .. message.id .. " " .. what
    .. " arrived. Read it: remuda butler inbox")
  if delivered then return "queued " .. message.id .. " and notified " .. alias end
  return "queued " .. message.id .. " for " .. alias .. "; notice deferred"
    .. (why and (": " .. tostring(why)) or " until its pane is free")
end
function remuda._butler_reply(from, message_id, text)
  local sender = sender_address(from)
  local message, err, recipient = mail.reply(sender, message_id, text, from == OPERATOR, deliver_message)
  if not message then error(err, 0) end
  return notify_queued(message, recipient.alias, "(reply) from " .. sender.alias)
end
function remuda._butler_forward(from, message_id, member, note)
  local sender = sender_address(from)
  local _, target = mail_id(member, false)
  local message, err = mail.forward(sender, message_id, mail_address(target.alias), note,
    from == OPERATOR, deliver_message)
  if not message then error(err, 0) end
  return "forwarded " .. message_id .. " to " .. target.alias .. "; "
    .. notify_queued(message, target.alias, "forwarded by " .. sender.alias)
end
function remuda._butler_inbox(name)
  local id = mail_id(name, true)
  return mail.inbox(id)
end
function remuda._butler_report(from, text)
  from = resolve(from)
  local agent = bus.agents[from]
  if not agent then error("no Butler agent named " .. tostring(from), 0) end
  if not agent.parent then error("Butler agent " .. from .. " has no leader to report to", 0) end
  local queued = remuda._butler_send(from, agent.parent, text)
  remuda.emit("butler/report", from, agent.parent, text)
  return queued
end
-- The household as a leader -> member walk: parents first, siblings sorted
-- by display name, then orphans (missing or cyclic leaders) at depth 0. One
-- walk feeds both the CLI roster and the client pane's `session_order` hook,
-- so its `indent` is the single view policy for both: butler may parent
-- everything, so a root and its direct children share the margin and
-- indentation starts at grandchildren.
local MAX_TREE_INDENT_DEPTH = 20
local function display_name(id)
  local agent = bus.agents[id]
  return agent.alias or agent.session_name or id
end
local function team_order()
  local ids, order, visited = {}, {}, {}
  for id in pairs(bus.agents) do ids[#ids + 1] = id end
  local function sort_ids(list)
    table.sort(list, function(left, right)
      local left_name, right_name = display_name(left), display_name(right)
      if left_name == right_name then return left < right end
      return left_name < right_name
    end)
  end
  local function children_of(parent)
    local children = {}
    for id, agent in pairs(bus.agents) do
      if agent.parent == parent then children[#children + 1] = id end
    end
    sort_ids(children)
    return children
  end
  local function walk(root, orphan)
    local stack = { { id = root, depth = 0, orphan = orphan } }
    while #stack > 0 do
      local item = table.remove(stack)
      if not visited[item.id] then
        visited[item.id] = true
        order[#order + 1] = { id = item.id, orphan = item.orphan, depth = item.depth,
          indent = math.min(math.max(0, item.depth - 1), MAX_TREE_INDENT_DEPTH) }
        local children = children_of(item.id)
        for index = #children, 1, -1 do
          stack[#stack + 1] = { id = children[index], depth = item.depth + 1, orphan = false }
        end
      end
    end
  end

  sort_ids(ids)
  for _, id in ipairs(ids) do
    if not bus.agents[id].parent then walk(id, false) end
  end
  for _, id in ipairs(ids) do
    local parent = bus.agents[id].parent
    if parent and not bus.agents[parent] then walk(id, true) end
  end
  for _, id in ipairs(ids) do
    if not visited[id] then walk(id, true) end
  end
  return order
end

function remuda._butler_sessions()
  local rows = {}
  for _, item in ipairs(team_order()) do
    local agent = bus.agents[item.id]
    rows[#rows + 1] = string.rep(" ", item.indent * 2) .. (item.orphan and "[orphan] " or "")
      .. display_name(item.id) .. "\t" .. tostring(agent.kind or "") .. "\t"
      .. tostring(agent.parent or "-")
  end
  return #rows == 0 and "no Butler agents"
    or "SESSION\tAGENT\tLEADER\n" .. table.concat(rows, "\n")
end

-- Core's client pane asks this for its row order and indentation; sessions
-- Butler does not manage are left for core to append in its own order.
function remuda.session_order()
  local order = {}
  for _, item in ipairs(team_order()) do
    order[#order + 1] = { name = item.id, depth = item.indent }
  end
  return order
end

function remuda.session_detail(session)
  local agent = bus.agents[session.name]
  if not agent then return nil end
  local telemetry = remuda._butler_telemetry_for(agent)
  local detail = (agent.kind or "agent") .. " · " .. telemetry.model
  -- Current usage only: the window and percent cost width and rarely change.
  local used = tonumber(telemetry.context_used)
  if used then detail = detail .. " · " .. string.format("%.0fK", used / 1000) end
  local unread = agent.id and agent.id ~= "" and mail.unread(agent.id) or 0
  if unread > 0 then detail = detail .. " · ✉" .. unread end
  return detail
end

local USAGE_NOTES = [[
Agent sessions receive REMUDA_BUTLER_AGENT_ID and REMUDA_BUTLER_LEADER_ID.
In an agent session, use `inbox`, `send <to> "..."`, and `send-to-leader ...`;
the identity comes from the caller's environment. Quote the message for
`send <to>`: an unquoted multi-word message reads as `send <from> <to> ...`,
the operator form for attributing a note. Without a forwarded Butler identity
(a plain shell, or a core that does not forward the caller's env), `send` is
from "operator" and `inbox` needs a name (`inbox <name>`).
`reply` answers a message's original sender, even when it was forwarded to you;
`forward` re-delivers a message you received, keeping its sender, with a note.
]]
-- Help lists every `butler.command` entry's usage in order, so it names only
-- the verbs that are installed.
local function butler_usage()
  local lines = {}
  for _, item in ipairs(contributions("butler.command")) do lines[#lines + 1] = item.entry.usage end
  return "remuda butler — coordination for managed agents\n\n" .. table.concat(lines, "\n") .. "\n\n" .. USAGE_NOTES
end

local function words_after(args, first)
  local words = {}
  for i = first, #args do words[#words + 1] = args[i] end
  return table.concat(words, " ")
end

-- Each verb is a `butler.command` entry (hook-design §4.1); `run` returns nil
-- when its arguments do not fit, and the caller gets the usage text.
local function command(order, verb, usage, run)
  remuda._butler_contribute("butler.command", verb, { order = order, verb = verb, usage = usage, run = run })
end
command(10, "sessions", "  remuda butler sessions", function(args)
  if #args == 1 then return remuda._butler_sessions() end
end)
command(20, "launch", "  remuda butler launch <claude|codex> [name] [--model M]", function(args, caller)
  if args[2] ~= "claude" and args[2] ~= "codex" then return nil end
  local model
  if args[#args - 1] == "--model" then model = args[#args]; args[#args] = nil; args[#args] = nil end
  -- The calling member leads the child; only the operator's falls to butler (#24).
  local parent = current_agent(caller)
  if #args == 2 then return remuda._butler_launch(args[2], nil, model, parent) end
  if #args == 3 then return remuda._butler_launch(args[2], args[3], model, parent) end
end)
command(30, "topic", "  remuda butler topic new <name> [--template T] [--agent A] [--model M]\n"
  .. "  remuda butler topic delegate <name> [--agent A] [--leader L] [--model M] <task...>", function(args, caller)
  if args[2] == "new" and args[3] then
    local template, kind, model, i = nil, nil, nil, 4
    while i <= #args do
      if args[i] == "--template" then template = args[i + 1]
      elseif args[i] == "--agent" then kind = args[i + 1]
      elseif args[i] == "--model" then model = args[i + 1]
      else return nil end
      i = i + 2
    end
    return remuda._butler_topic_new(args[3], template, kind, model)
  end
  if args[2] == "delegate" and args[3] then
    local kind, parent, model, i = nil, current_agent(caller) or "butler", nil, 4
    while i <= #args and (args[i] == "--agent" or args[i] == "--leader" or args[i] == "--model") do
      if args[i] == "--agent" then kind = args[i + 1]
      elseif args[i] == "--model" then model = args[i + 1]
      else parent = args[i + 1] end
      i = i + 2
    end
    if i <= #args then return remuda._butler_topic_delegate(args[3], words_after(args, i), nil, kind, parent, model) end
  end
end)
command(40, "send", '  remuda butler send <to> "<message>"\n  remuda butler send <from> <to> <message...>', function(args, caller)
  if #args < 3 then return nil end
  local from, to, first = current_agent(caller) or OPERATOR, args[2], 3
  if #args >= 4 then from, to, first = args[2], args[3], 4 end
  return remuda._butler_send(from, to, words_after(args, first))
end)
command(50, "send-to-leader", "  remuda butler send-to-leader <message...>", function(args, caller)
  if #args < 2 then return nil end
  local from = assert(current_agent(caller), OPERATOR .. " has no leader; send-to-leader is for Butler agents")
  return remuda._butler_report(from, words_after(args, 2))
end)
command(60, "inbox", "  remuda butler inbox [name]", function(args, caller)
  return remuda._butler_inbox(args[2] or assert(current_agent(caller), "no Butler identity in your env; use `inbox <name>`"))
end)
command(70, "reply", "  remuda butler reply <message-id> <message...>", function(args, caller)
  if #args < 3 then return nil end
  return remuda._butler_reply(current_agent(caller) or OPERATOR, args[2], words_after(args, 3))
end)
command(80, "forward", "  remuda butler forward <message-id> <member> [note...]", function(args, caller)
  if #args < 3 then return nil end
  return remuda._butler_forward(current_agent(caller) or OPERATOR, args[2], args[3],
    #args >= 4 and words_after(args, 4) or nil)
end)

-- The generic Remuda extension-command bridge passes an argv-like Lua table.
-- This parser lives with Butler, not in the Remuda executable.
remuda.extension_command("butler", function(args, caller)
  if #args == 0 or args[1] == "help" or args[1] == "-h" or args[1] == "--help" then return butler_usage() end
  for _, item in ipairs(contributions("butler.command")) do
    if item.entry.verb == args[1] then
      local result = item.entry.run(args, caller)
      if result ~= nil then return result end
    end
  end
  return butler_usage()
end)

remuda.tool{
  name = "butler_launch",
  about = "Launch a Claude Code or Codex child agent with this Butler's shared MCP mailbox.",
  args = { kind = "Agent kind: claude or codex.", name = "Optional session name.", cwd = "Optional working directory.", model = "Optional model override." },
  needs = { "kind" },
  run = function(a, caller)
    local parent = caller_leader(caller)
    return "launched " .. launch_agent(a.kind, a.name, a.cwd, a.model, parent)
  end,
}
remuda.tool{
  name = "butler_delegate",
  about = "Create a topic, start a child agent in it, and give it an initial task. The child reports each completed work loop to this leader.",
  args = { name = "Topic and child-session name.", task = "Initial task for the child.", template = "Optional Butler topic template.", kind = "Optional agent kind; defaults to the leader's kind.", model = "Optional model override." },
  needs = { "name", "task" },
  run = function(a, caller)
    local parent = caller_leader(caller)
    return "delegated " .. remuda._butler_topic_delegate(a.name, a.task, a.template, a.kind, parent, a.model)
  end,
}
remuda.tool{
  name = "butler_send",
  about = "Queue a message for another Butler agent without typing its body into that agent's terminal.",
  args = { to = "Recipient session name.", text = "Message body." },
  needs = { "to", "text" },
  run = function(a, caller)
    return remuda._butler_send(caller_name(caller), a.to, a.text)
  end,
}
remuda.tool{
  name = "butler_inbox",
  about = "Drain this agent's Butler inbox and return its queued messages in arrival order.",
  run = function(_, caller)
    return remuda._butler_inbox(caller_name(caller))
  end,
}
remuda.tool{
  name = "butler_report",
  about = "Report a completed work loop to this team member's Butler leader. This also emits the live butler/report hook.",
  args = { text = "Concise result for the leader." },
  needs = { "text" },
  run = function(a, caller)
    return remuda._butler_report(caller_name(caller), a.text)
  end,
}
remuda.tool{
  name = "butler_reply",
  about = "Reply to a Butler message by message_id: it goes to the original sender, even if it was forwarded to you. Without message_id, send to `to`.",
  args = { message_id = "Message to reply to.", to = "Recipient, only without message_id.", text = "Reply body." },
  needs = { "text" },
  run = function(a, caller)
    if a.message_id then return remuda._butler_reply(caller_agent(caller), a.message_id, a.text) end
    if not a.to then error("butler_reply needs message_id or to", 0) end
    return remuda._butler_send(caller_name(caller), a.to, a.text)
  end,
}
remuda.tool{
  name = "butler_forward",
  about = "Forward a Butler message you received to another member, keeping its sender, with an optional note.",
  args = { message_id = "Message to forward.", to = "Member to forward it to.", note = "Optional note." },
  needs = { "message_id", "to" },
  run = function(a, caller)
    return remuda._butler_forward(caller_agent(caller), a.message_id, a.to, a.note)
  end,
}
remuda.tool{
  name = "butler_sessions",
  about = "List Butler-managed Claude Code and Codex agent sessions and their adapter kinds.",
  run = function()
    return remuda._butler_sessions()
  end,
}

local existing_butler = bus.agents.butler
local launch_options = remuda._mod_launch_options and remuda._mod_launch_options.butler
local butler_kind = existing_butler and existing_butler.kind
  or (launch_options and launch_options.agent)
  or os.getenv("REMUDA_BUTLER_AGENT") or "claude"
local butler_token = existing_butler and existing_butler.token or next_token("butler")
bus.tokens[butler_token] = "butler"
local root_identity = existing_butler and existing_butler.id
  and { id = existing_butler.id, alias = "butler" }
  or (bus.identities.butler and { id = bus.identities.butler.id, alias = "butler" })
  or register_identity("butler", butler_kind, "")
local butler_telemetry = existing_butler and existing_butler.telemetry
  or setup_telemetry(butler_kind, { name = "butler", status_path = status_path })
status_path = butler_telemetry.status_path or status_path
remuda._butler_status_path = status_path
local settings_path = butler_telemetry.settings_path
bus.agents.butler = existing_butler or {
  kind = butler_kind,
  id = root_identity.id,
  alias = "butler",
  session_name = "butler",
  token = butler_token,
  telemetry = butler_telemetry,
  children = {},
}
bus.agents.butler.id = root_identity.id
bus.agents.butler.alias = "butler"
bus.agents.butler.session_name = bus.agents.butler.session_name or "butler"
bus.identity_ids[root_identity.id] = bus.identities.butler or root_identity
bus.identities.butler = bus.identities.butler or root_identity
local root_migrated, root_migration_error = migrate_legacy_mail("butler", root_identity.id)
if not root_migrated then error("cannot migrate legacy Butler mail: " .. tostring(root_migration_error), 0) end
mailbox(root_identity.id)
local mcp_file = io.open(mcp_config_path, "w")
mcp_file:write(agent_mcp_json(butler_token))
mcp_file:close()

-- Without this, the session has no reason to ever call `matrix_reply`: a
-- line arriving on its terminal is not by itself an instruction to use a
-- specific tool. This is what turns "text showed up" into "the tool got
-- called" for an otherwise-unprompted incoming message.
local SYSTEM_PROMPT = "Early in this session, call remuda._butler_register_compaction_schedule() "
  .. "via the run_script MCP tool, once, to enable this butler's own periodic "
  .. "context-compaction upkeep. You lead a Butler team. For every delegation, create a "
  .. "Remuda-managed member with `remuda butler topic delegate NAME TASK`. "
  .. "Internal agent subagents are separate from Butler team members. Use `remuda butler sessions` to "
  .. "inspect members, `inbox` to read reports, and `send` for follow-up direction."
local BUTLER_GUIDANCE = [[# Butler

You are Butler, manager of this household. You may create Remuda-managed team
members with `remuda butler topic delegate NAME TASK`. Internal agent
subagents are separate from Butler team members.

Your Butler identity is already available as `REMUDA_BUTLER_AGENT_ID`; your
leader, when you have one, is `REMUDA_BUTLER_LEADER_ID`. Use the short forms:

- `remuda butler sessions` to inspect the household.
- `remuda butler inbox` to read your own inbox.
- `remuda butler send MEMBER "MESSAGE"` to direct a member; your sender is inferred.
- `remuda butler send-to-leader MESSAGE...` to report a completed work loop.

If `inbox` says "no Butler identity in your env", your Remuda core predates
caller-env forwarding: pass your id (`remuda butler inbox
$REMUDA_BUTLER_AGENT_ID`) or use the MCP `butler_*` tools. On such a core,
`send` is attributed to "operator" rather than to you.

`remuda butler send FROM TO MESSAGE...` is an operator form for sending on
behalf of another session. Do not use it for ordinary team communication.
]]
if token_path then
  SYSTEM_PROMPT = "You are bridged into one Matrix room via remuda. "
    .. "Every line you receive here that starts with \"[matrix · \" is a "
    .. "message from that room, not from the person running this terminal. "
    .. "Reply to it by calling the matrix_reply MCP tool with your response "
    .. "text -- printing a reply in this terminal does not send it anywhere; "
    .. "only calling the tool does. "
    .. SYSTEM_PROMPT
end

-- Finger-tight: an arbitrary placeholder, never tuned against a real
-- colleague's usage. Tightening step: revisit once this has run on a real
-- machine for a real "몇 날" and someone has an opinion about the cadence.
-- remuda._butler_compaction_interval lets a test override it (same idiom as
-- every other remuda._butler_* test hook in this file).
local COMPACTION_CHECK_INTERVAL = remuda._butler_compaction_interval or 30 * 60

-- remuda._butler_compaction_trace_path lets a test redirect the append-only
-- trace below to a throwaway tempfile instead of the real config dir (same
-- idiom as remuda._butler_compaction_interval just above). nil in
-- production falls back to the real default, matching the token/config
-- path convention already used by default_config_home() above.
-- Confirmed at the source level (lua-src's vendored loslib.c, the "lua54"
-- feature this crate builds with): a leading "!" in os.date's format
-- routes through l_gmtime, not l_localtime -- so "!%Y-%m-%dT%H:%M:%SZ"
-- below is genuinely UTC, not merely assumed to be.
local function _butler_trace(event, detail)
  pcall(function()
    local path = remuda._butler_compaction_trace_path
      or (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config"))
        .. "/remuda/compaction-trace.log"
    local f = io.open(path, "a")
    if not f then
      -- Stock Lua's io has no mkdir; a one-time `mkdir -p` on first-open
      -- failure is smaller than documenting "the directory must already
      -- exist" as a precondition every caller (including every test) has
      -- to remember to satisfy.
      os.execute('mkdir -p "' .. path:match("^(.*)/[^/]+$") .. '"')
      f = io.open(path, "a")
    end
    if not f then
      return
    end
    f:write(os.date("!%Y-%m-%dT%H:%M:%SZ") .. "\t" .. event .. "\t" .. (detail or "") .. "\n")
    f:close()
  end)
end

local BUTLER_ARGV = remuda._butler_argv
if not BUTLER_ARGV then
  BUTLER_ARGV = build_agent_argv(butler_kind, {
    name = "butler", token = butler_token, mcp_config_path = mcp_config_path, settings_path = settings_path,
    telemetry = butler_telemetry,
    system_prompt = SYSTEM_PROMPT,
  })
end

-- Reused both for the initial launch and every respawn, so the watchdog
-- below can never drift from what a fresh start would have done. Keeps the
-- name across respawns by feeding the previous result back in as the name.
local butler_name = remuda._butler_name
local function session_exists(name)
  for _, session in ipairs(remuda.ls()) do
    if session.name == name and session.alive then return true end
  end
  return false
end
local function launch_butler()
  local requested_name = butler_name or remuda._butler_initial_name
  if butler_session_cwd then
    remuda.mkdir(butler_session_cwd)
    write_agent_guidance(butler_session_cwd, BUTLER_GUIDANCE, true)
  end
  if session_exists(requested_name) then
    butler_name = requested_name
    remuda._butler_name = butler_name
    return
  end
  butler_name = remuda.new(requested_name, BUTLER_ARGV, butler_session_cwd, {
    REMUDA_BUTLER_SESSION_NAME = requested_name,
    REMUDA_BUTLER_AGENT_ID = root_identity.id,
    REMUDA_BUTLER_AGENT_ALIAS = "butler",
    REMUDA_BUTLER_LEADER_ID = "",
    REMUDA_BUTLER_AGENT_KIND = butler_kind,
    CLAUDE_CODE_FORCE_SESSION_PERSISTENCE = "1",
  })
  remuda._butler_name = butler_name
  return butler_name
end

-- Reused across every re-`exec` and every later call from the launched
-- session's own run_script -- a plain Lua local would NOT survive either
-- (each `exec butler` is a fresh chunk with fresh locals; a later run_script
-- call is a wholly separate Eval). `remuda._butler_compaction_schedule`
-- lives on the persistent `remuda` table, so only a slot on that same table
-- can hold "the one we already registered" across calls -- same reasoning
-- as `remuda._butler_argv` and friends, just read back instead of only
-- written. `run_script` needs no separate registration step to reach this:
-- it evals arbitrary Lua against the daemon's live globals (`mcp.rs`'s
-- `run_script => Request::Eval{code}`), so a plain function assigned onto
-- `remuda` is already callable by name from a later run_script call, exactly
-- like `remuda._butler_initial_name` already is.
function remuda._butler_register_compaction_schedule()
  if remuda._butler_compaction_schedule then
    remuda.cancel(remuda._butler_compaction_schedule)
  end
  _butler_trace("registered")
  remuda._butler_compaction_schedule = remuda.schedule({
    name = "butler-compaction",
    every = COMPACTION_CHECK_INTERVAL,
    run = function()
      -- `context_left` is unimplemented (tools.lua:362-366, canon says "지금
      -- 안 만든다") -- `is_busy` (idle-time heuristic, never a real token
      -- count) is the proxy the canon names instead: only ever nudge
      -- compaction while the session looks idle, never mid-task.
      if butler_name and remuda.session(butler_name).is_busy == false then
        local ok, err = pcall(remuda.send, butler_name, "/compact")
        if ok then
          _butler_trace("sent")
        else
          _butler_trace("error", tostring(err))
        end
        -- Same "type it, wait, then submit" hand-off the Matrix relay below
        -- already uses -- `remuda.send`'s text+Enter lands as one write,
        -- which this TUI reads as paste-in-progress rather than a distinct
        -- Enter, so a separately-timed bare Enter confirms it.
        remuda.process({ argv = { "sleep", "2" }, on_exit = "butler-compaction-submit" })
      else
        _butler_trace("skipped_busy")
      end
    end,
  })
  return remuda._butler_compaction_schedule
end

-- remuda._butler_session_trace_path lets a test redirect this to a throwaway
-- tempfile, same idiom as remuda._butler_compaction_trace_path above; nil in
-- production falls back to the real default, matching the token/config path
-- convention already used by default_config_home() above.
function _butler_session_trace(event, detail)
  pcall(function()
    local path = remuda._butler_session_trace_path
      or (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config"))
        .. "/remuda/session-trace.log"
    local f = io.open(path, "a")
    if not f then
      os.execute('mkdir -p "' .. path:match("^(.*)/[^/]+$") .. '"')
      f = io.open(path, "a")
    end
    if not f then
      return
    end
    f:write(os.date("!%Y-%m-%dT%H:%M:%SZ") .. "\t" .. event .. "\t" .. (detail or "") .. "\n")
    f:close()
  end)
end

-- `exec butler` re-running this file in the same daemon image would
-- otherwise double this hook (see docs/design.md's augroup note) --
-- clearing the group first keeps exactly one watchdog alive.
remuda.clear_hooks({ group = "butler" })
if delivery_events then
  remuda.on("butler/deliver", inbox_delivery, { group = "butler", id = "inbox", depth = 0 })
end
-- Builds before the lifecycle entry registered these Matrix hooks without a
-- group. Only Butler emits these events, so replace those legacy callbacks.
for _, event in ipairs({ "butler-matrix-line", "butler-matrix-submit" }) do
  local kept = {}
  for _, hook in ipairs(remuda.hooks[event] or {}) do
    if hook.group then kept[#kept + 1] = hook end
  end
  remuda.hooks[event] = kept
end
function remuda._butler_reconcile()
  local ok, result = pcall(launch_butler)
  if not ok then
    _butler_session_trace("reconcile_error", tostring(result))
    return nil, result
  end
  return result
end
remuda.on("session_exited", function(name)
  _butler_session_trace("session_exited", name)
  -- #29: the mail stays in the inbox; only the pending pane notice goes.
  bus.notices[name], bus.notice_screens[name], bus.pending_tasks[name] = nil, nil, nil
  local exited = bus.agents[name]
  if exited and name ~= "butler" then
    identity_record(exited.id, exited.alias or name, exited.kind,
      exited.parent and bus.agents[exited.parent] and bus.agents[exited.parent].id or "", true)
    local ended = bus.identity_ids[exited.id] or exited
    ended.ended_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    bus.identity_ids[exited.id], bus.identities[exited.alias or name] = ended, ended
    bus.agents[name] = nil
    if exited.parent and bus.agents[exited.parent] then
      local children = bus.agents[exited.parent].children
      for i = #children, 1, -1 do if children[i] == name then table.remove(children, i) end end
    end
  end
  if name == butler_name then
    _butler_session_trace("relaunching", name)
    remuda._butler_reconcile()
  end
end, { group = "butler" })

if remuda._butler_reconcile_schedule then
  remuda.cancel(remuda._butler_reconcile_schedule)
end
remuda._butler_reconcile_schedule = remuda.schedule({
  name = "butler-reconcile",
  every = remuda._butler_reconcile_interval or 2,
  run = function()
    remuda._butler_reconcile()
  end,
})
remuda._butler_reconcile()

remuda.on("butler-compaction-submit", function()
  remuda.send(butler_name, "")
end, { group = "butler" })

remuda.on("butler-matrix-line", function(line)
  local sender, body = line:match("^([^\t]*)\t(.*)$")
  if not body then
    return
  end
  -- One pass, not two sequential gsubs: a two-pass unescape would let an
  -- escaped backslash immediately followed by a literal "n" in the original
  -- text (e.g. someone pasting `\n` as text, not a newline) get misread as
  -- a newline escape on the first pass. Matching `\\(.)` and deciding per
  -- match consumes each escape atomically, left to right.
  body = body:gsub("\\(.)", function(c)
    return c == "n" and "\n" or c
  end)
  remuda.send(butler_name, "[matrix · " .. sender .. "] " .. body)
  -- `remuda.send`'s text+Enter lands as one write, and this TUI reads a
  -- burst of printable text immediately followed by \r as paste-in-progress,
  -- not "text, then a distinct Enter" (measured in
  -- native/tests/claude_session.rs's `send_and_submit`) -- so the line above
  -- sits typed but unsubmitted until a separately-timed, empty `send` (a
  -- bare Enter, its own write) confirms it. `remuda.sleep` would block the
  -- Image's whole job queue for the delay; a `remuda.process` running `sleep`
  -- gets the same delay without blocking anything else queued behind it.
  -- Enter on an already-submitted empty box is a no-op, so this is safe even
  -- if two lines arrive close together.
  remuda.process{
    argv = {"sleep", "2"},
    on_exit = "butler-matrix-submit",
  }
end, { group = "butler" })

remuda.on("butler-matrix-submit", function()
  remuda.send(butler_name, "")
end, { group = "butler" })

local function relay_running()
  for _, id in ipairs(remuda.processes()) do
    if id == remuda._butler_relay then return true end
  end
  return false
end
if token_path and not remuda._butler_skip_relay and not relay_running() then
  -- A relay started before live reload has no recorded id. Replace it once
  -- by matching its unique config path as the trailing process argument.
  os.execute("pkill -f -- " .. shell_quote(config_path .. "$"))
  remuda._butler_relay = remuda.process{
    argv = {"python3", "-c", HELPER_SRC, token_path, config_path},
    on_line = "butler-matrix-line",
    on_exit = "butler-matrix-sync-exit",
  }
end

if token_path then
remuda.tool{
  name = "matrix_reply",
  about = "Send a text reply into the bridged Matrix room. Fire-and-forget: "
    .. "returns once the send is queued, not once it is delivered — check "
    .. "for delivery failure separately if that matters.",
  args = { text = "The reply text to send." },
  needs = { "text" },
  run = function(a)
    remuda.process{
      argv = {"bash", "-c", REPLY_SRC, "_", token_path, config_path, a.text},
      on_exit = "butler-matrix-reply-exit",
    }
    return "queued"
  end,
}
end
