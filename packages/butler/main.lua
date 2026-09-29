-- remuda-butler: runs one Claude Code session, optionally bridged to Matrix.
-- Matrix commands and the MCP reply tool share the Lua async request vocabulary.

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

-- Exposed so tests can inspect the daemon-local MCP helper without starting a
-- real process/session (this harness does not have a real agent CLI).
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
local function call_callback(fn, ...)
  local args, unpack_args = {...}, table.unpack or unpack
  local ok, value = pcall(fn, remuda, unpack_args(args, 1, #args))
  if ok then return true, value end
  return pcall(fn, unpack_args(args, 1, #args))
end
local function registered_agent_kind(kind)
  if remuda.contributions then
    for _, row in ipairs(remuda.contributions("butler.agent")) do
      if row.id == kind then return row.entry end
    end
  end
  local bus = remuda._butler_bus
  for id, entry in pairs(bus and bus.contributions and bus.contributions["butler.agent"] or {}) do
    if id == kind then return entry end
  end
end
local function registered_agent_working(entry, screen)
  if not entry or type(entry.working) ~= "function" then return true, false end
  return call_callback(entry.working, screen)
end
remuda._butler_current_agent = current_agent

local DEFAULT_COMPACTION_CONFIG = {
  watch = 400000, warn = 600000, critical = 800000, critical_pct = 90,
  cooldown_ticks = 4, capture_gap = 3, dialog_timeout = 30,
  completion_timeout = 45, verification_timeout = 45, input_settle = 0.15,
  idle_wait_timeout = 12, restore_attempts = 2, failure_cooldown_ticks = 12,
}
local function compaction_config()
  local configured = remuda._butler_compaction_config or {}
  local out = {}
  for key, fallback in pairs(DEFAULT_COMPACTION_CONFIG) do
    out[key] = tonumber(configured[key]) or fallback
  end
  return out
end

-- Public compaction units. These stay above the test-mode return so the
-- standalone Lua acceptance test exercises the same policy primitives.
remuda.butler = remuda.butler or {}
function remuda.butler.ctx_level(name)
  local agent = (remuda._butler_bus and remuda._butler_bus.agents[name]) or {}
  local telemetry = remuda._butler_telemetry_for(agent) or {}
  local used = tonumber(telemetry.context_used)
  local pct = tonumber(telemetry.context_pct or telemetry.context_percent)
  local config = compaction_config()
  local level = "ok"
  if (used and used >= config.critical) or (pct and pct >= config.critical_pct) then level = "critical"
  elseif used and used >= config.warn then level = "warn"
  elseif used and used >= config.watch then level = "watch" end
  return { level = level, used = used, pct = pct }
end
function remuda.butler.is_idle(name)
  local ok, session = pcall(remuda.session, name)
  if not ok or not session then return false, "session unavailable" end
  if session.is_busy ~= false then return false, "busy" end
  if session.attached == true then return false, "human attached" end
  if type(remuda.ls) == "function" then
    local listed, rows = pcall(remuda.ls)
    if not listed then return false, "session list unavailable" end
    for _, row in ipairs(rows or {}) do
      if row.name == name and row.attached then return false, "human attached" end
    end
  end
  local bus = remuda._butler_bus or {}
  if (remuda._butler_compaction_has_queued_mail and remuda._butler_compaction_has_queued_mail(name))
    or ((bus.pending_tasks or {})[name]) or ((bus.notices or {})[name]) then
    return false, "queued work"
  end
  local captured, screen = pcall(remuda.capture, name)
  if not captured or type(screen) ~= "string" then return false, "capture unavailable" end
  local agent = (bus.agents and bus.agents[name]) or {}
  local registered = registered_agent_kind(agent.kind)
  if registered and registered.working then
    local checked, working = registered_agent_working(registered, screen)
    if not checked then return false, "working state unknown" end
    if working then return false, "working" end
  end
  local empty, decision = pcall(remuda._butler_prompt_is_empty, agent.kind or "", screen)
  if not empty or decision ~= "EMPTY" then return false, "composer not empty" end
  return true, "idle"
end
function remuda.butler.compact(name)
  if not remuda._butler_compaction_execute then return "compaction procedure unavailable" end
  local result = remuda._butler_compaction_execute(name)
  return result or "started"
end
function remuda._butler_compaction_has_session(name)
  if type(name) ~= "string" or name == "" then return false end
  local agents = (remuda._butler_bus or {}).agents or {}
  for key, agent in pairs(agents) do
    if (agent.session_name or key) == name then return true end
  end
  return false
end
function remuda.butler.compaction_policy(name, state, dry_run)
  state = state or {}
  local current = state
  if dry_run then
    current = {}
    for key, value in pairs(state) do current[key] = value end
  end
  current.idle_ticks = current.idle_ticks or 0
  local level = remuda.butler.ctx_level(name)
  if level.level == "ok" then
    current.idle_ticks, current.cooldown_ticks, current.last_idle_capture_at = 0, 0, nil
    return false, "skipped_small", level.used or "?"
  end
  if (current.cooldown_ticks or 0) > 0 then
    current.cooldown_ticks = current.cooldown_ticks - 1
    current.idle_ticks, current.last_idle_capture_at = 0, nil
    return false, "skipped_cooldown", level.used or "?"
  end
  local idle, reason = remuda.butler.is_idle(name)
  if not idle then
    current.idle_ticks, current.last_idle_capture_at = 0, nil
    local reasons = {
      busy = "skipped_busy", working = "skipped_busy", ["human attached"] = "skipped_attached",
      ["queued work"] = "skipped_queued", ["composer not empty"] = "skipped_composer",
      ["working state unknown"] = "skipped_unknown", ["capture unavailable"] = "skipped_composer",
    }
    return false, reasons[reason] or "skipped_unknown", level.used or "?"
  end
  local now = (remuda._butler_compaction_now or os.time)()
  local config = compaction_config()
  if current.last_idle_capture_at and now - current.last_idle_capture_at < config.capture_gap then
    return false, "skipped_idle", level.used or "?"
  end
  current.last_idle_capture_at = now
  current.idle_ticks = current.idle_ticks + 1
  local required = level.level == "watch" and 2 or 1
  if current.idle_ticks < required then return false, "skipped_idle", level.used or "?" end
  current.idle_ticks, current.last_idle_capture_at = 0, nil
  current.cooldown_ticks = config.cooldown_ticks
  return true, "sent", level.used or "?"
end

function remuda._butler_compaction_reset_idle(st)
  st.idle_ticks = 0
end

function remuda._butler_compaction_action_guard(session_name)
  local found, session = pcall(remuda.session, session_name)
  if not found or not session then return "session unavailable" end
  if session.attached then return "human attached" end
  if type(remuda.ls) == "function" then
    local listed, rows = pcall(remuda.ls)
    if not listed then return "session list unavailable" end
    for _, row in ipairs(rows or {}) do
      if row.name == session_name and row.attached then return "human attached" end
    end
  end
  return nil
end

function remuda._butler_compaction_preflight(session_name)
  local found, session = pcall(remuda.session, session_name)
  if not found or not session then return "session unavailable" end
  local attached = session.attached == true
  if type(remuda.ls) == "function" then
    local listed, rows = pcall(remuda.ls)
    if listed then
      for _, row in ipairs(rows or {}) do
        if row.name == session_name and row.attached then attached = true end
      end
    end
  end
  if attached then return "human attached" end
  if session.is_busy ~= false then return "busy" end
  if remuda._butler_compaction_has_queued_mail and remuda._butler_compaction_has_queued_mail(session_name) then
    return "queued mail"
  end
  local captured, screen = pcall(remuda.capture, session_name)
  if not captured then return "session unavailable" end
  local agent = remuda._butler_bus.agents[session_name] or {}
  local registered = registered_agent_kind(agent.kind)
  if registered and registered.working then
    local checked, working = registered_agent_working(registered, screen)
    if not checked then return "busy state unknown" end
    if working then return "busy" end
  end
  return nil
end

function remuda._butler_compaction_submit_matches(decision, text)
  return decision == "NON-EMPTY" and text == "/compact"
end

local function compaction_model(screen)
  if type(screen) ~= "string" then return nil end
  local model = screen:match("MODEL:(.-)%s+CTX:") or screen:match("MODEL:([^\r\n]+)")
  return model and model:gsub("%s+$", "") or nil
end
local function compaction_family(value)
  if type(value) ~= "string" then return nil end
  local lower = value:lower()
  for _, family in ipairs({ "opus", "sonnet", "haiku" }) do
    if lower == family or lower:match("^" .. family .. "[%s%-%d]")
      or lower:match("^claude%-" .. family .. "%-") then return family end
  end
end
local function numbered_option(line)
  local trimmed = line:gsub("^%s+", "")
  for _, marker in ipairs({ "❯", "›", ">" }) do
    if trimmed:sub(1, #marker) == marker then
      trimmed = trimmed:sub(#marker + 1):gsub("^%s+", "")
      break
    end
  end
  return trimmed:match("^(%d+)[%.)]%s*(.-)%s*$"), trimmed:match("^%d+[%.)]%s*(.-)%s*$")
end
local function compaction_yes_option(screen)
  local matches = {}
  for line in (screen .. "\n"):gmatch("(.-)\n") do
    local number, label = numbered_option(line)
    local lower = label and label:lower() or ""
    if lower:find("yes", 1, true) and lower:find("switch", 1, true) then
      matches[#matches + 1] = number
    end
  end
  if #matches == 1 then return matches[1] end
end
remuda._butler_compaction_yes_option = compaction_yes_option
local function compaction_is_switch_dialog(screen)
  if type(screen) ~= "string" then return false end
  local lines = {}
  for line in (screen .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  for i, line in ipairs(lines) do
    if line:gsub("^%s+", ""):gsub("%s+$", ""):lower() == "switch model?" then
      for j = i + 1, math.min(#lines, i + 4) do
        if numbered_option(lines[j]) then return true end
      end
    end
  end
  return false
end
function remuda._butler_compaction_is_unknown_dialog(screen)
  if type(screen) ~= "string" then return false end
  if compaction_is_switch_dialog(screen) then return false end
  local lines = {}
  for line in (screen .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
    if #lines > 8 then table.remove(lines, 1) end
  end
  local top_border, bottom_border, selected_option, option_line, prompt_line = false, false, false, nil, nil
  for i, line in ipairs(lines) do
    local trimmed = line:gsub("^%s+", "")
    local prompt = trimmed:gsub("%s+$", "")
    local first, last = trimmed:sub(1, 3), trimmed:sub(-3)
    if (first == "╭" or first == "┌" or first == "╔")
      and (last == "╮" or last == "┐" or last == "╗") then top_border = true end
    if (first == "╰" or first == "└" or first == "╚")
      and (last == "╯" or last == "┘" or last == "╝") then bottom_border = true end
    if numbered_option(line) then
      option_line = i
      if trimmed:sub(1, #"❯") == "❯" or trimmed:sub(1, #"›") == "›" then selected_option = true end
    end
    if prompt == "❯" or prompt == "›" or prompt == ">" then prompt_line = i end
  end
  return (top_border and bottom_border) or selected_option
    or (option_line and prompt_line and prompt_line > option_line and prompt_line - option_line <= 2)
    or false
end
function remuda._butler_compaction_visible_answer(kind, screen, target)
  if kind == "claude" and compaction_is_switch_dialog(screen) then
    local option = remuda.expect_option and remuda.expect_option(screen, function(label)
      local lower = label:lower()
      return lower:find("yes", 1, true) and lower:find("switch", 1, true)
    end) or compaction_yes_option(screen)
    if option then return option, "dialog" end
    return nil, "unknown"
  end
  local model = compaction_model(screen)
  if model and target and model:lower():find(target:lower(), 1, true) then return nil, "ready" end
  if remuda._butler_compaction_is_unknown_dialog(screen) then return nil, "unknown" end
  return nil, "waiting"
end
function remuda._butler_compaction_sequence(kind, prior, low)
  if kind == "codex" then return { "/compact" } end
  return { "/model " .. low, "/compact", "/model " .. prior }
end

if remuda._butler_test_mode == true then
  return
end

-- Cancel the existing Matrix relay before resolving new config;
-- matrix.lua will start exactly one relay after the new config is installed.
local old_matrix = remuda.butler and remuda.butler.matrix
local old_relay = old_matrix and old_matrix.relay
if old_relay and old_relay.stop then pcall(old_relay.stop)
end

-- Replace handles created imperatively by the previous Butler version. The
-- lifecycle declaration owns these schedules from this activation onward.
local legacy_compaction_schedule = remuda._butler_compaction_schedule
for _, key in ipairs({ "_butler_notice_schedule", "_butler_reconcile_schedule", "_butler_compaction_schedule" }) do
  if remuda[key] then
    remuda.cancel(remuda[key])
    remuda[key] = nil
  end
end
if legacy_compaction_schedule and remuda._butler_state then
  remuda._butler_state.compaction_enabled = true
end
if not remuda._butler_state then
  remuda._butler_compaction_state = remuda._butler_compaction_state or {}
end
remuda._butler_compaction_reset_idle(remuda._butler_state or remuda._butler_compaction_state)

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
-- scripts/check-butler-path-convention.lua, which fails if the two diverge.
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
  remuda._butler_matrix_config = { token_path = token_path, config_path = config_path }
else
  remuda._butler_matrix_config = nil
end
-- This internal module is the single inbound Matrix entry point. It registers
-- only the optional relay and remains inert when credentials are absent.
remuda.exec("butler/matrix_request")
remuda.exec("butler/matrix")

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
local function valid_child_name(name, what)
  if type(name) ~= "string" or name == "" or name:sub(1, 1) == "."
      or name:find("/", 1, true) or name:find("\\", 1, true)
      or name:find("..", 1, true) or name:find("%c") then
    error((what or "name") .. " must be a single path component without separators, '..', or a leading dot", 0)
  end
  return name
end
local function create_fresh_directory(path)
  if not (remuda.fs and remuda.fs.mkdir_new) then return false end
  local parent = path:match("^(.*)/[^/]+$")
  if not parent then return false end
  remuda.mkdir(parent)
  local created, reason = remuda.fs.mkdir_new(path)
  return created == true
end
local function directory_is_under(path, root)
  if type(path) ~= "string" or type(root) ~= "string" or path == root then return false end
  local prefix = root:sub(-1) == "/" and root or (root .. "/")
  return path:sub(1, #prefix) == prefix
end
local function json_quote(s)
  return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"')
    :gsub('\r', '\\r'):gsub('\n', '\\n'):gsub('\t', '\\t') .. '"'
end
local function status_settings(path)
  -- TODO core #213: remove this Python statusLine helper once the core JSON/stdin boundary is settled.
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
    local root = remuda._butler_bus and remuda._butler_bus.agents.butler or {}
    local skipped = {}
    for _, attempt in ipairs(remuda._butler_attempts or {}) do
      if attempt.reason ~= "ready" then skipped[#skipped + 1] = attempt.kind .. "=" .. attempt.reason end
    end
    local launch = " AGENT:" .. tostring(root.kind or "?")
      .. (#skipped > 0 and (" SKIPPED:" .. table.concat(skipped, ",")) or "")
    local f = io.open(remuda._butler_status_path or "", "r")
    if not f then
      return "MODEL:? CTX:? CTXWIN:? CTXPCT:? (no status reading yet)" .. launch
    end
    local line = f:read("*l")
    f:close()
    -- The helper owns this file.  Refuse a malformed or externally replaced
    -- record instead of presenting arbitrary file contents as Claude status.
    if not line or not line:match("^MODEL:[A-Za-z0-9_.%-?]+ CTX:[0-9?]+ CTXWIN:[0-9?]+ CTXPCT:[0-9?]+$") then
      error("butler status record is malformed", 0)
    end
    return line .. launch
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
bus.codex_update_state = bus.codex_update_state or { claimed = false, done = false }
bus.codex_update_relaunches = bus.codex_update_relaunches or {}
bus.codex_update_state.waiting = bus.codex_update_state.waiting or {}
bus.codex_update_state.restart_waiting = bus.codex_update_state.restart_waiting or {}

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
  local second = os.time()
  local millis = math.floor(second * 1000)
  local bytes = {}
  for i = 6, 1, -1 do bytes[i] = millis % 256; millis = math.floor(millis / 256) end
  local entropy
  if bus.previous_ulid_second == second then
    local bytes = { bus.previous_ulid_random:byte(1, 10) }
    local carry = 1
    for i = 10, 1, -1 do
      local value = bytes[i] + carry
      bytes[i] = value % 256
      carry = math.floor(value / 256)
    end
    if carry ~= 0 then error("ULID random component overflow", 0) end
    local out = {}
    for i = 1, 10 do out[i] = string.char(bytes[i]) end
    entropy = table.concat(out)
  else
    local random = io.open("/dev/urandom", "rb")
    entropy = random and random:read(10)
    if random then random:close() end
    if not entropy or #entropy ~= 10 then
      math.randomseed(second + math.floor(os.clock() * 1000000))
      local out = {}
      for i = 1, 10 do out[i] = string.char(math.random(0, 255)) end
      entropy = table.concat(out)
    end
  end
  bus.previous_ulid_second, bus.previous_ulid_random = second, entropy
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
remuda._butler_new_ulid = crockford_ulid
remuda._butler_mail_config = { bus = bus, root = mail_root, json_quote = json_quote }
remuda.exec("butler/mail")
local function identity_record(record)
  if not identity_path then return end
  local dir = identity_path:match("^(.*)/[^/]+$")
  if dir then os.execute("mkdir -p " .. shell_quote(dir)) end
  local row = '{"id":' .. json_quote(record.id) .. ',"alias":' .. json_quote(record.alias)
    .. ',"kind":' .. json_quote(record.kind or "") .. ',"leader_id":' .. json_quote(record.leader_id or "")
  if record.created_at and not record.created_at_unknown then
    row = row .. ',"created_at":' .. json_quote(record.created_at)
  elseif record.created_at_unknown then
    row = row .. ',"created_at_unknown":true'
  end
  row = row .. ',"state":' .. json_quote(record.state or "running")
  if record.reason then row = row .. ',"reason":' .. json_quote(record.reason) end
  if record.ended_at then row = row .. ',"ended_at":' .. json_quote(record.ended_at) end
  if record.ended_at_estimate then row = row .. ',"ended_at_estimate":true' end
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
        local created_at, ended_at = json_field(line, "created_at"), json_field(line, "ended_at")
        local state = json_field(line, "state")
        local created_at_unknown = line:match('"created_at_unknown":true') ~= nil
          or (not state and ended_at and created_at == ended_at)
        local record = { id = id, alias = alias, kind = json_field(line, "kind"),
          leader_id = json_field(line, "leader_id"), created_at = created_at,
          created_at_unknown = created_at_unknown, ended_at = ended_at,
          state = state or (ended_at and "ended" or "running"),
          reason = json_field(line, "reason"),
          ended_at_estimate = line:match('"ended_at_estimate":true') ~= nil }
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
      record.state, record.reason = "ended", "daemon_restart"
      record.ended_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
      record.ended_at_estimate = true
      identity_record(record)
    end
  end
  bus.identities_loaded = true
end
local function register_identity(alias, kind, leader_id, id)
  id = id or crockford_ulid()
  local record = { id = id, alias = alias, kind = kind, leader_id = leader_id or "",
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"), state = "running" }
  bus.identities[alias], bus.identity_ids[id] = record, record
  identity_record(record)
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
      message.in_reply_to, message.references, message.matrix)
  end
  if not delivered then
    message.delivery_error = why
    return nil
  end
  return delivered
end
remuda._butler_inbox_delivery = inbox_delivery
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
      message.in_reply_to, message.references, message.matrix)
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
remuda.exec("butler/prompt")
local AGENT_BUILDERS = remuda._butler_agent_builders
local TELEMETRY_ADAPTERS = remuda._butler_telemetry_adapters
local PROMPT_DELIVERY = assert(remuda._butler_prompt_delivery)
local BUILTIN_AGENT_BUILDERS = {}
for kind, builder in pairs(AGENT_BUILDERS) do BUILTIN_AGENT_BUILDERS[kind] = builder end
if not remuda.contribute then
  for order, kind in ipairs({ "claude", "codex" }) do
    local kind_id = kind
    local startup = remuda._butler_agent_startup[kind_id] or {}
    remuda._butler_contribute("butler.agent", kind_id, {
      order = order * 10, executable = kind_id,
      argv = function(_, spec) return AGENT_BUILDERS[kind_id](spec) end,
      ready = startup.ready and function(_, screen) return startup.ready(screen) end or nil,
      working = function(_, screen) return screen:find("esc to interrupt", 1, true) ~= nil end,
      login = kind_id == "claude"
        and { "Please log in", "not logged in", "Authentication required", "Invalid API key", "Please run /login", "Select login method" }
        or { "Please log in", "not logged in", "Authentication required", "Sign in to continue", "Not authenticated" },
      dialogs = startup.modals,
    })
  end
end
local function build_agent_argv(kind, spec)
  local builder = AGENT_BUILDERS[kind]
  if not builder then error("unknown agent kind: " .. tostring(kind), 0) end
  return builder(spec)
end
local function one_line(value)
  return (tostring(value or ""):match("^[^\r\n]*") or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end
local function readiness_timeout()
  local configured = tonumber(remuda._butler_readiness_timeout or os.getenv("REMUDA_BUTLER_READINESS_TIMEOUT"))
  if configured and configured > 0 then return configured end
  return 15
end
local startup_action_safe
local trust_modal_state
-- The one generic launch chooser serves Butler and every managed member. Kinds
-- are lifecycle contributions; the chooser only reads their data and callbacks.
-- Member launches must not hold the daemon image while an agent paints its
-- first prompt. This scheduler advances one candidate at a time and invokes
-- `done(name, kind, attempts)` when a candidate is ready or the chain ends.
local function choose(candidates, opts, done)
  local attempts, index, state, schedule = {}, 0, nil, nil
  local lifecycle = remuda._butler_state or remuda._butler_compaction_state or {}
  lifecycle.active_choosers = lifecycle.active_choosers or {}
  lifecycle.next_chooser_id = (lifecycle.next_chooser_id or 0) + 1
  local chooser_id = "chooser-" .. tostring(lifecycle.next_chooser_id)
  local chooser_record = { id = chooser_id, name = opts.name }
  lifecycle.active_choosers[chooser_id] = chooser_record
  local cancelled = false
  local function trace(attempt)
    if remuda._butler_session_trace then
      remuda._butler_session_trace("candidate", attempt.kind .. ": " .. attempt.reason
        .. ": " .. (attempt.detail or ""))
    end
  end
  local function callback(name, kind)
    if cancelled then return end
    if schedule then remuda.cancel(schedule); schedule = nil end
    chooser_record.ready = name ~= nil
    lifecycle.active_choosers[chooser_id] = nil
    done(name, kind, attempts)
  end
  local function alive(name)
    for _, row in ipairs(remuda.ls()) do if row.name == name and row.alive then return true end end
    return false
  end
  local by_id = {}
  for _, row in ipairs(contributions("butler.agent")) do by_id[row.id] = row.entry end
  for id, builder in pairs(remuda._butler_agent_builders or {}) do
    if not by_id[id] then
      local startup = remuda._butler_agent_startup[id] or {}
      by_id[id] = { argv = function(_, spec) return builder(spec) end,
        ready = startup.ready and function(_, screen) return startup.ready(screen) end or nil,
        login = {}, dialogs = startup.modals }
    end
  end
  local function fail_candidate(reason, detail)
    local current = state
    current.attempt.reason, current.attempt.detail = reason, detail
    local ok, err = pcall(remuda.close, current.name)
    current.closing, current.close_error, current.close_ticks = true, ok and nil or err, 0
  end
  local function start_next()
    index = index + 1
    local id = candidates[index]
    if not id then callback(nil, nil); return end
    local entry = by_id[id]
    local attempt = { kind = id, reason = "unknown" }
    attempts[#attempts + 1] = attempt
    if not entry then
      attempt.reason, attempt.detail = "not_found", "agent kind is not registered"
      trace(attempt); start_next(); return
    end
    local spec = opts.spec(id)
    local argv = (type(opts.argv) == "function" and opts.argv(id, spec)) or opts.argv
      or (type(entry.argv) == "function" and select(2, call_callback(entry.argv, spec))) or entry.argv
      or (entry.build and entry.build(spec))
    local builder_override = remuda._butler_agent_builders[id]
      and remuda._butler_agent_builders[id] ~= BUILTIN_AGENT_BUILDERS[id]
    local executable = (builder_override and argv and argv[1])
      or entry.requires or entry.executable or (argv and argv[1]) or id
    if not opts.argv then
      local quoted = "'" .. tostring(executable):gsub("'", "'\\''") .. "'"
      local found = os.execute("command -v " .. quoted .. " >/dev/null 2>&1")
      if found ~= true and found ~= 0 then
        attempt.reason, attempt.detail = "not_found", executable .. " not found in PATH"
        trace(attempt); start_next(); return
      end
    end
    local ok, name = pcall(remuda.new, opts.name, argv, opts.cwd, opts.env(id, spec))
    if not ok then
      attempt.reason, attempt.detail = "spawn_error", one_line(name)
      trace(attempt); start_next(); return
    end
    state = { id = id, entry = entry, attempt = attempt, name = name,
      started = os.time(), timeout = opts.timeout or readiness_timeout(),
      handled = {}, last_screen = "", dialog_seen = nil }
    local test_builder = remuda._butler_agent_builders[id]
      and remuda._butler_agent_builders[id] ~= BUILTIN_AGENT_BUILDERS[id]
    local force_test_probe = type(remuda._butler_test_force_launch_probe) == "table"
      and remuda._butler_test_force_launch_probe[opts.name] == true
    if opts.skip_probe or (test_builder and not force_test_probe) then
      attempt.reason, attempt.session = "ready", name
      callback(name, id)
    end
  end
  local function tick()
    if not state then return end
    if state.closing then
      state.close_ticks = state.close_ticks + 1
      if not alive(state.name) then
        trace(state.attempt); state = nil; start_next()
      elseif state.close_ticks >= 10 then
        state.attempt.reason = "spawn_error"
        state.attempt.detail = (state.attempt.detail or "") .. "; failed to kill failed session"
          .. (state.close_error and (": " .. tostring(state.close_error)) or "")
        trace(state.attempt); callback(nil, nil)
      end
      return
    end
    if not alive(state.name) then fail_candidate("exited", "session exited before prompt became ready"); return end
    local captured, screen = pcall(remuda.capture, state.name)
    if not captured then fail_candidate("exited", one_line(screen)); return end
    screen = tostring(screen or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    state.last_screen = one_line(screen)
    local entry, id = state.entry, state.id
    -- Authentication screens can still contain a prompt glyph; classify
    -- login before readiness so expired credentials never look usable.
    for _, pattern in ipairs(entry.login or {}) do
      if screen:find(pattern, 1, true) then fail_candidate("login", one_line(screen)); return end
    end
    local ready = false
    if entry.ready then local tested, matched = call_callback(entry.ready, screen); ready = tested and not not matched end
    local startup = remuda._butler_agent_startup[id] or {}
    if not ready and startup.ready then local tested, matched = pcall(startup.ready, screen); ready = tested and not not matched end
    if not ready and remuda._butler_prompt_is_empty then
      local tested, decision = pcall(remuda._butler_prompt_is_empty, id, screen); ready = tested and decision == "EMPTY"
    end
    if not ready and (screen:match("\n%s*❯%s*$") or screen:match("\n%s*>%s*$") or screen:match("\n%s*›%s*$")) then ready = true end
    if ready then state.attempt.reason, state.attempt.session = "ready", state.name; callback(state.name, id); return end
    local dialogs = type(entry.dialogs) == "function" and select(2, call_callback(entry.dialogs)) or entry.dialogs or {}
    local known = false
    for dialog_index, dialog in ipairs(dialogs) do
      local lower_screen = screen:lower()
      local trust_state = dialog.trust and trust_modal_state(dialog, screen) or nil
      local matched = dialog.trust and trust_state ~= "absent"
        or (dialog.match and lower_screen:find(dialog.match:lower(), 1, true))
      if matched then
        known, state.dialog_seen = true, dialog.match
        if dialog.trust then
          if state.trust_screen == screen then state.trust_ticks = (state.trust_ticks or 0) + 1
          else state.trust_screen, state.trust_ticks = screen, 1 end
          if state.trust_ticks < 2 then break end
          if trust_state == "pending" and opts.auto_trust then break end
          if trust_state == "safe" and opts.auto_trust and bus.trusted_launch_dirs
              and bus.trusted_launch_dirs[opts.cwd] == true and startup_action_safe
              and startup_action_safe(state.name) then
            if not state.handled[dialog_index] then
              state.handled[dialog_index] = true
              local answered = true
              for _, key in ipairs(dialog.keys or {}) do
                local ok, result = pcall(remuda.key, state.name, key)
                if not ok or result == false then answered = false end
              end
              if answered then
                state.attempt.trust_answered = true
                bus.trusted_launch_dirs[opts.cwd] = nil
              end
            end
            break
          end
          state.attempt.reason, state.attempt.session = "waiting_for_human_trust", state.name
          state.attempt.trust_path = opts.cwd
          callback(state.name, id)
          return
        end
        -- Codex's update is an actionable startup state. Hand it to the
        -- member launch flow, which owns the shared update lock and relaunch.
        if dialog.update then
          state.attempt.reason, state.attempt.session = "startup_dialog", state.name
          callback(state.name, id)
          return
        end
        if not state.handled[dialog_index] then
          state.handled[dialog_index] = true
          for _, key in ipairs(dialog.keys or {}) do pcall(remuda.key, state.name, key) end
        end
        break
      elseif dialog.pending_match and lower_screen:find(dialog.pending_match:lower(), 1, true) then
        -- Claude paints the trust explanation before the selectable options.
        -- Keep polling that known startup state until its affirmative option
        -- is visible; the broad unknown-dialog check below would otherwise
        -- reject the partial frame before the label handler can run.
        known, state.dialog_seen = true, dialog.pending_match
        break
      end
    end
    if known then
      state.unknown_dialog_screen, state.unknown_dialog_since = nil, nil
    else
      local lower = screen:lower()
      local suspicious = lower:find("trust", 1, true) or lower:find("continue", 1, true)
        or lower:find("press enter", 1, true) or lower:find("select an option", 1, true)
        or lower:find("terms of service", 1, true) or lower:find("confirm", 1, true)
      if suspicious then
        if state.unknown_dialog_screen ~= screen then
          state.unknown_dialog_screen, state.unknown_dialog_since = screen, os.time()
        elseif os.time() - state.unknown_dialog_since >= 2 then
          fail_candidate("dialog", one_line(screen)); return
        end
      else
        state.unknown_dialog_screen, state.unknown_dialog_since = nil, nil
      end
    end
    if os.time() - state.started >= state.timeout then
      local prefix = state.dialog_seen and ("dialog remained after its handler: " .. state.dialog_seen .. "; ") or ""
      fail_candidate(state.dialog_seen and "dialog" or "timeout", prefix
        .. "readiness prompt not observed within " .. tostring(state.timeout)
        .. " seconds; last screen: " .. (state.last_screen ~= "" and state.last_screen or "<empty>"))
    end
  end
  schedule = remuda.schedule({ every = 0.2, run = function()
    local ok, err = pcall(tick)
    if not ok then
      if state and state.name then fail_candidate("spawn_error", tostring(err))
      else callback(nil, nil) end
    end
  end })
  chooser_record.schedule = schedule
  chooser_record.cancel = function()
    if cancelled then return end
    cancelled = true
    if schedule then pcall(remuda.cancel, schedule); schedule = nil end
    if state and not chooser_record.ready then
      local name = state.name
      if name and alive(name) then pcall(remuda.close, name) end
      state = nil
    end
    if opts.name == "butler" then
      remuda._butler_launching, remuda._butler_start_pending = nil, nil
      remuda._butler_selected_agent = nil
    end
    lifecycle.active_choosers[chooser_id] = nil
  end
  start_next()
  return attempts
end
remuda._butler_choose = choose
remuda._butler_choose_async = choose
function remuda._butler_cancel_active_choosers(lifecycle)
  lifecycle = lifecycle or remuda._butler_state or remuda._butler_compaction_state
  local active = lifecycle and lifecycle.active_choosers or {}
  local pending = {}
  for id, record in pairs(active) do pending[#pending + 1] = { id = id, record = record } end
  for _, item in ipairs(pending) do
    if item.record.cancel then pcall(item.record.cancel) else active[item.id] = nil end
  end
end
local function configured_agent_order()
  if remuda._butler_candidate_order then return remuda._butler_candidate_order end
  local raw = os.getenv("REMUDA_BUTLER_AGENT_ORDER")
  if raw and raw ~= "" then
    local order = {}
    for kind in raw:gmatch("[^,%s]+") do order[#order + 1] = kind end
    if #order > 0 then return order end
  end
  local rows = contributions("butler.agent")
  table.sort(rows, function(a, b)
    local ao = tonumber(a.order or (a.entry and a.entry.order)) or 0
    local bo = tonumber(b.order or (b.entry and b.entry.order)) or 0
    if ao ~= bo then return ao < bo end
    return a.id < b.id
  end)
  local order = {}
  for _, row in ipairs(rows) do order[#order + 1] = row.id end
  if #order == 0 then return { "claude", "codex" } end
  return order
end
remuda._butler_configured_agent_order = configured_agent_order
local function readiness_chain_budget()
  -- Include time for the ordered candidates plus room for the scheduler to
  -- notice each timeout and close a failed session before advancing.
  return math.ceil(#configured_agent_order() * readiness_timeout() + 15)
end
local function setup_telemetry(kind, spec)
  local adapter = TELEMETRY_ADAPTERS[kind]
  return adapter and adapter.setup and adapter.setup(spec) or {}
end
-- A member's AGENTS.md and prompt are `butler.guidance` sections joined in
-- order, so an extension adds its own section (hook-design §4.2).
if not remuda.contribute then
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
end
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
local function option_number(screen, matches)
  -- Parse the visible chooser ourselves. Core versions that strip a UTF-8
  -- selection glyph as a byte-class can leave stray bytes before its label.
  local found
  for line in (tostring(screen or "") .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("^%s*", "")
    for _, marker in ipairs({ "│", "┃", "❯", "›", ">" }) do
      if line:sub(1, #marker) == marker then
        line = line:sub(#marker + 1):gsub("^%s*", "")
        break
      end
    end
    local number, label = line:match("^%s*(%d+)[%.)]%s*(.-)%s*$")
    if number and matches(label) then
      if found then return nil end
      found = number
    end
  end
  return found
end
local function codex_update_version(screen)
  local from, to = tostring(screen or ""):match("(%d+%.%d+%.%d+)%s*→%s*(%d+%.%d+%.%d+)")
  if from and to then return from .. "->" .. to end
end
local function skip_option_number(screen)
  local number = option_number(screen, function(label) return label:lower() == "skip" end)
  if number then return number end
  number = option_number(screen, function(label)
    local lower = label:lower()
    return lower:sub(1, 5) == "skip " and lower ~= "skip until next version"
  end)
  if number then return number end
  return option_number(screen, function(label) return label:lower() == "skip until next version" end)
end
local function startup_modal_timeout_seconds()
  return tonumber(remuda._butler_modal_timeout or remuda._butler_modal_attempts or remuda._butler_task_poke_attempts) or 60
end
trust_modal_state = function(modal, screen)
  local lines, title, affirmative, selected_no, selected_index, selected_codex = {}, false, false, false, nil, false
  for line in (tostring(screen or "") .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
    local trimmed = line:gsub("^%s+", "")
    if trimmed:find("Accessing workspace:", 1, true) then title = true end
    if trimmed:match("^❯%s*No, exit") then selected_no, selected_index = true, #lines end
    if trimmed:match("^Yes, I trust this folder%s*$") then affirmative = true end
    if trimmed:match("^[›❯]%s*1[.)]%s*Trust and continue%s*$") then selected_codex = true end
  end
  local lower = tostring(screen or ""):lower()
  if modal.trust == "claude" then
    if not title then
      if lower:find("quick safety check:", 1, true) then return "pending" end
      return "absent"
    end
    if not lower:find("no, exit", 1, true) or not lower:find("yes, i trust this folder", 1, true) then
      if lower:find("quick safety check:", 1, true) then return "pending" end
      return "human"
    end
    if not selected_no or not selected_index then return "human" end
    local options = 0
    for _, line in ipairs(lines) do
      if line:match("^%s*[❯›]%s*%S") or line:match("^  %S") then options = options + 1 end
    end
    if affirmative and selected_no and options == 2 then return "safe" end
    return "human"
  elseif modal.trust == "codex" then
    if not lower:find("trust this folder?", 1, true) then return "absent" end
    local options = 0
    local no_option = false
    for _, line in ipairs(lines) do
      if line:match("^%s*[❯›]%s+") or line:match("^%s*%d+[.)]%s+") then
        options = options + 1
        if line:lower():find("don't trust", 1, true) or line:lower():find("do not trust", 1, true) then no_option = true end
      end
    end
    if selected_codex and no_option and options == 2 then return "safe" end
    return "human"
  end
  return "human"
end
local function startup_modal(startup, screen)
  local lower = tostring(screen or ""):lower()
  for _, modal in ipairs(startup.modals or {}) do
    if modal.trust then
      if trust_modal_state(modal, screen) ~= "absent" then return modal end
    elseif modal.match and lower:find(modal.match:lower(), 1, true) then
      return modal
    elseif modal.pending_match and lower:find(modal.pending_match:lower(), 1, true) then
      return modal
    end
  end
end
local function known_startup_modal(startup, screen)
  if startup_modal(startup, screen) then return true end
  local lower = tostring(screen or ""):lower()
  return lower:find("updating codex", 1, true) ~= nil
    or lower:find("installing codex update", 1, true) ~= nil
end
local function codex_update_complete(screen)
  local lower = tostring(screen or ""):lower()
  return lower:find("update complete", 1, true) ~= nil
    or lower:find("update successful", 1, true) ~= nil
    or lower:find("update ran successfully", 1, true) ~= nil
    or lower:find("codex was updated", 1, true) ~= nil
    or lower:find("codex has been updated", 1, true) ~= nil
    or lower:find("restarting codex", 1, true) ~= nil
end
local function capture_update_evidence(session, screen)
  local evidence = tostring(screen or "")
  -- Some hosts may expose scrollback separately; core 355e8b2 only exposes
  -- the current screen through remuda.capture.
  if type(remuda.capture_scrollback) == "function" then
    local ok, scrollback = pcall(remuda.capture_scrollback, session)
    if ok and scrollback then
      if type(scrollback) == "table" then
        local rows = {}
        for _, row in ipairs(scrollback) do rows[#rows + 1] = tostring(row) end
        evidence = table.concat(rows, "\n") .. "\n" .. evidence
      else
        evidence = tostring(scrollback) .. "\n" .. evidence
      end
    end
  end
  return evidence
end
local function launch_agent(kind, requested_name, cwd, model, parent, task, relaunch_identity, fresh_trusted_cwd)
  local candidates = kind and { kind } or configured_agent_order()
  kind = kind or candidates[1]
  local name = valid_child_name(requested_name or kind or "agent", "agent name")
  if cwd ~= nil and (type(cwd) ~= "string" or cwd:find("%c")) then
    error("cwd must be a string without control characters", 0)
  end
  if bus.agents[name] then
    error("alias " .. name .. " is live as " .. tostring(bus.agents[name].id) .. "; pick another alias", 0)
  end
  local parent_identity = parent and bus.agents[parent]
  local identity = relaunch_identity and (bus.identity_ids[relaunch_identity] or bus.identities[name])
    or register_identity(name, kind, parent_identity and parent_identity.id or "")
  if relaunch_identity then
    identity.kind, identity.leader_id, identity.state = kind, parent_identity and parent_identity.id or "", "running"
    identity.ended_at, identity.reason = nil, nil
    identity_record(identity)
  end
  local auto_trust = fresh_trusted_cwd == true
  if not cwd and data_home then
    local sessions_root = data_home .. "/remuda/butler/sessions"
    cwd = sessions_root .. "/" .. name
    local created_now = create_fresh_directory(cwd)
    if created_now then
      bus.trusted_launch_dirs = bus.trusted_launch_dirs or {}
      bus.trusted_launch_dirs[cwd] = true
    end
    if not created_now then remuda.mkdir(cwd) end
    auto_trust = created_now and directory_is_under(sessions_root, data_home)
      and directory_is_under(cwd, sessions_root)
  end
  local launch_cwd = cwd or "."
  if cwd and parent and auto_trust then write_agent_guidance(cwd, team_member_guidance(parent)) end
  local token = next_token(name)
  local telemetry_by_kind = {}
  local agent_telemetry = setup_telemetry(kind, { name = name, model = model })
  telemetry_by_kind[kind] = agent_telemetry
  local choose_opts = {
    name = name, cwd = launch_cwd, auto_trust = auto_trust,
    spec = function(candidate_kind)
      local telemetry = telemetry_by_kind[candidate_kind]
        or setup_telemetry(candidate_kind, { name = name, model = model })
      telemetry_by_kind[candidate_kind] = telemetry
      return { name = name, token = token, model = model,
        settings_path = telemetry.settings_path, telemetry = telemetry,
        system_prompt = parent and team_member_prompt(parent) or nil }
    end,
    env = function(candidate_kind)
      return { REMUDA_BUTLER_SESSION_NAME = name, REMUDA_BUTLER_AGENT_ID = identity.id,
        REMUDA_BUTLER_AGENT_ALIAS = name,
        REMUDA_BUTLER_LEADER_ID = parent_identity and parent_identity.id or "",
        REMUDA_BUTLER_AGENT_KIND = candidate_kind,
        CLAUDE_CODE_FORCE_SESSION_PERSISTENCE = "1" }
    end,
  }
  local function finish(actual, selected_kind, attempts)
  if not actual then
    if bus.trusted_launch_dirs then bus.trusted_launch_dirs[launch_cwd] = nil end
    local errors = {}
    for _, a in ipairs(attempts) do errors[#errors + 1] = a.kind .. ": " .. a.reason .. " (" .. (a.detail or "") .. ")" end
    local message = "no agent candidate became ready: " .. table.concat(errors, "; ")
    bus.launch_failures = bus.launch_failures or {}
    bus.launch_failures[name] = { attempts = attempts, error = message }
    _butler_session_trace("launch_failed", name .. ": " .. message)
    return nil
  end
  kind = selected_kind
  agent_telemetry = telemetry_by_kind[kind]
  identity.kind = kind
  identity_record(identity)
  local waiting_for_trust, trust_answered = false, false
  for _, attempt in ipairs(attempts or {}) do
    if attempt.session == actual and attempt.reason == "waiting_for_human_trust" then
      waiting_for_trust = true
    end
    if attempt.session == actual and attempt.trust_answered then trust_answered = true end
  end
  bus.tokens[token] = actual
  bus.agents[actual] = {
    kind = kind, token = token, model = model, telemetry = agent_telemetry,
    parent = parent, children = {}, id = identity.id, alias = actual, session_name = actual,
    cwd = launch_cwd, task = task, launch_attempts = attempts, trust_allowed = auto_trust,
    trust_reported = waiting_for_trust, trust_answered = trust_answered,
  }
  if parent and bus.agents[parent] then
    local children = bus.agents[parent].children
    children[#children + 1] = actual
  end
  local migrated, migration_error = migrate_legacy_mail(actual, identity.id)
  if not migrated then error("cannot migrate legacy Butler mail: " .. tostring(migration_error), 0) end
  mailbox(identity.id)
  if waiting_for_trust then
    pcall(remuda._butler_send, "butler", parent or "butler",
      "waiting for a human: trust dialog in " .. tostring(launch_cwd or "unknown directory"))
  end
  -- A failed welcome write must not prevent the agent from starting.
  if not relaunch_identity then
    pcall(queue_message, mail_address(parent or "butler"), mail_address(actual),
      team_member_guidance(parent or "butler"), "Welcome to Butler")
  end
  if task and task ~= "" then
    -- Keep an immediate mail notice out of the child's first prompt until the
    -- delegated task has been submitted.
    bus.pending_tasks[actual] = true
    local startup = remuda._butler_agent_startup[kind] or {}
    if kind == "codex" then
    local poke, confirm, attempts, settle, deferred = nil, nil, 0, 0, 0
    local update_waiting, waiting_for_update, update_deadline = false, false, 0
    local modal_wait_started, update_timeout_reported, update_version = nil, false, nil
    local function modal_wait_expired()
      modal_wait_started = modal_wait_started or os.time()
      return os.time() - modal_wait_started >= startup_modal_timeout_seconds()
    end
    local update_relaunch_record_ref
    local function update_relaunch_record()
      local agent = bus.agents[actual] or {}
      return {
        kind = kind, name = actual, cwd = agent.cwd, model = agent.model,
        parent = agent.parent, task = task, identity = agent.id,
        update_pressed = false, last_screen = agent.last_screen,
      }
    end
    local function relaunch_after_update()
      if update_relaunch_record_ref and update_relaunch_record_ref.relaunched then
        remuda.cancel(poke)
        return true
      end
      if not startup_action_safe or not startup_action_safe(actual) then return false end
      bus.codex_update_relaunches[actual] = update_relaunch_record()
      update_relaunch_record_ref = bus.codex_update_relaunches[actual]
      update_relaunch_record_ref.version = update_version
      update_relaunch_record_ref.expected_close = true
      if bus.codex_update_state.waiting then bus.codex_update_state.waiting[actual] = nil end
      if bus.codex_update_state.restart_waiting then bus.codex_update_state.restart_waiting[actual] = nil end
      local closed, result = pcall(remuda.close, actual)
      if not closed or result == false then
        bus.codex_update_relaunches[actual] = nil
        update_relaunch_record_ref = nil
        return false
      end
      remuda.cancel(poke)
      return true
    end
    local function finish_update()
      local state = bus.codex_update_state
      state.done, state.claimed, state.done_version, state.owner = true, false, update_version, nil
      state.restart_waiting = state.restart_waiting or {}
      for member in pairs(state.waiting or {}) do state.restart_waiting[member] = true end
      state.waiting = {}
    end
    -- Either timeout means the task never reached the agent: say so to its
    -- leader rather than only in the trace (#29).
    local function give_up(detail)
      remuda.cancel(poke)
      if confirm then remuda.cancel(confirm) end
      bus.pending_tasks[actual] = nil
      if bus.codex_update_state.waiting then bus.codex_update_state.waiting[actual] = nil end
      if bus.codex_update_state.restart_waiting then bus.codex_update_state.restart_waiting[actual] = nil end
      _butler_session_trace("task_poke_timeout", actual .. detail)
      pcall(remuda._butler_send, "butler", parent or "butler", "Task for " .. actual
        .. " was not delivered: its pane never became ready or free to type into."
        .. " Resend it with `remuda butler send " .. actual .. " TASK` once it is.")
    end
    local function report_update_timeout(detail)
      if update_timeout_reported then return end
      update_timeout_reported = true
      bus.pending_tasks[actual] = nil
      _butler_session_trace("codex_update_timeout", actual .. detail)
      pcall(remuda._butler_send, "butler", parent or "butler", "Codex update wait limit reached for " .. actual
        .. ". Its pane was left open; task delivery will resume when the pane is safe to relaunch.")
    end
    poke = remuda.schedule({ every = 0.5, run = function()
      if update_relaunch_record_ref and (update_relaunch_record_ref.relaunched or update_relaunch_record_ref.cancelled) then
        remuda.cancel(poke)
        bus.pending_tasks[actual] = nil
        return
      end
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
      local agent = bus.agents[actual]
      if agent then agent.last_screen = capture_update_evidence(actual, screen) end
      if update_relaunch_record_ref then
        update_relaunch_record_ref.last_screen = agent and agent.last_screen or capture_update_evidence(actual, screen)
      end
      if attempts < settle then return end -- let an answered modal repaint
      local modal = startup_modal(startup, screen)
      if modal and modal.trust then
        local trust_state = trust_modal_state(modal, screen)
        local agent = bus.agents[actual]
        if trust_state == "safe" and agent.trust_answered then return end
        if agent.last_trust_screen == screen then agent.trust_ticks = (agent.trust_ticks or 0) + 1
        else agent.last_trust_screen, agent.trust_ticks = screen, 1 end
        if agent.trust_ticks < 2 then return end
        if trust_state == "safe" and agent.trust_allowed and bus.trusted_launch_dirs
            and bus.trusted_launch_dirs[agent.cwd] == true and startup_action_safe
            and startup_action_safe(actual) then
          if not agent.trust_answered then
            local answered = true
            for _, key in ipairs(modal.keys or {}) do
              local ok, result = pcall(remuda.key, actual, key)
              if not ok or result == false then answered = false end
            end
            if answered then
              agent.trust_answered = true
              bus.trusted_launch_dirs[agent.cwd] = nil
            end
          end
        elseif not agent.trust_reported then
          agent.trust_reported = true
          pcall(remuda._butler_send, "butler", parent or "butler",
            "waiting for a human: trust dialog in " .. tostring(agent.cwd or "unknown directory"))
        end
        return
      end
      if update_waiting and update_relaunch_record_ref and codex_update_complete(screen) then
        update_relaunch_record_ref.update_complete_seen = true
      end
      if update_waiting then
        if not modal and startup.ready and startup.ready(screen) then
          -- The update completed in place. Restart the same alias with the
          -- same identity so the task is submitted only by its fresh pane.
          finish_update()
          if not relaunch_after_update() then
            if modal_wait_expired(screen) then
              bus.codex_update_state.restart_waiting[actual] = true
              report_update_timeout(" update completed while human attached")
            end
          end
          return
        end
        if os.time() >= update_deadline then
          local skip = modal and modal.update and skip_option_number(screen)
          if skip and startup_action_safe and startup_action_safe(actual) then
            pcall(remuda.key, actual, skip)
            local update_state = bus.codex_update_state
            if update_state.owner == actual then
              update_state.claimed, update_state.owner = false, nil
              update_state.aborted_version = update_version
              update_state.waiting, update_state.restart_waiting = {}, {}
            end
            bus.codex_update_relaunches[actual] = nil
            update_relaunch_record_ref = nil
            update_waiting, settle = false, attempts + 3
            return
          end
          -- Never close a pane while brew may still be replacing Codex.
          report_update_timeout(" still updating")
          return
        end
        return
      end
      local update_state = bus.codex_update_state
      if update_state.done and update_state.waiting and update_state.waiting[actual] then
        update_version, waiting_for_update = update_state.done_version, true
        if relaunch_after_update() then return end
        if modal_wait_expired(screen) then give_up(" update completed while human attached") end
        return
      end
      if update_state.done and update_state.restart_waiting and update_state.restart_waiting[actual] then
        update_version, waiting_for_update = update_state.done_version, true
        if relaunch_after_update() then update_state.restart_waiting[actual] = nil; return end
        if modal_wait_expired(screen) then give_up(" update completed while human attached") end
        return
      end
      if update_state.claimed and update_state.owner ~= actual
          and update_state.waiting and update_state.waiting[actual] then
        waiting_for_update = true
        if update_deadline == 0 then
          update_deadline = os.time() + (tonumber(remuda._butler_codex_update_timeout) or 300)
        end
        if os.time() >= update_deadline then
          local skip = modal and modal.update and skip_option_number(screen)
          if skip and startup_action_safe and startup_action_safe(actual) then
            pcall(remuda.key, actual, skip)
            waiting_for_update, settle = false, attempts + 3
            update_state.waiting[actual] = nil
          else
            give_up(" waiting for Codex update")
          end
        end
        return
      end
      local version = modal and modal.update and (codex_update_version(screen) or "unknown") or nil
      if version and version ~= "unknown" then
        if update_state.version and update_state.version ~= version and not update_state.claimed then
          update_state.done, update_state.done_version = false, nil
          update_state.waiting, update_state.restart_waiting = {}, {}
        end
        update_state.version = version
        update_version = version
      end
      if modal then
        _butler_session_trace("startup_modal", actual .. " " .. modal.match)
        if modal.update then
          if update_state.done and update_state.done_version == version
              and update_state.waiting and update_state.waiting[actual] then
            waiting_for_update = true
          end
          if update_state.claimed and update_state.owner ~= actual then
            waiting_for_update = true
            update_state.waiting[actual] = true
            if update_deadline == 0 then
              update_deadline = os.time() + (tonumber(remuda._butler_codex_update_timeout) or 300)
            end
            if update_state.done and update_state.done_version == version then
              if relaunch_after_update() then return end
              if modal_wait_expired(screen) then give_up(" modal human attached") end
              return
            end
            if os.time() >= update_deadline then
              local skip = skip_option_number(screen)
              if skip and startup_action_safe and startup_action_safe(actual) then
                pcall(remuda.key, actual, skip)
                waiting_for_update, settle = false, attempts + 3
                update_state.waiting[actual] = nil
                return
              end
            end
            if modal_wait_expired(screen) then give_up(" waiting for Codex update") end
            return
          end
          if waiting_for_update and update_state.done and update_state.done_version == version then
            if relaunch_after_update() then return end
          end
          if update_state.aborted_version == version then
            local skip = skip_option_number(screen)
            if skip and startup_action_safe and startup_action_safe(actual) then
              pcall(remuda.key, actual, skip)
              settle = attempts + 3
              return
            end
          elseif update_state.done and update_state.done_version == version then
            local skip = skip_option_number(screen)
            if skip and startup_action_safe and startup_action_safe(actual) then
              pcall(remuda.key, actual, skip)
              settle = attempts + 3
              return
            end
          elseif not update_state.claimed then
            local update = option_number(screen, function(label)
              return label:lower():find("update now", 1, true) ~= nil
            end)
            if update and startup_action_safe and startup_action_safe(actual) then
              update_state.claimed, update_state.owner = true, actual
              update_waiting = true
              update_deadline = os.time() + (tonumber(remuda._butler_codex_update_timeout) or 300)
              update_state.waiting = update_state.waiting or {}
              bus.codex_update_relaunches[actual] = update_relaunch_record()
              update_relaunch_record_ref = bus.codex_update_relaunches[actual]
              update_relaunch_record_ref.version = update_version
              update_relaunch_record_ref.update_pressed = true
              local pressed = pcall(remuda.key, actual, update)
              if pressed then
                return
              end
              update_relaunch_record_ref.update_pressed = false
              bus.codex_update_relaunches[actual] = nil
              update_relaunch_record_ref = nil
              update_state.claimed, update_state.owner = false, nil
            end
          end
          local skip = skip_option_number(screen)
          if skip and startup_action_safe and startup_action_safe(actual) then
            pcall(remuda.key, actual, skip)
            settle = attempts + 3
          else
            if modal_wait_expired(screen) then give_up(" update dialog") end
          end
          return
        end
        if modal_wait_expired(screen) then give_up(" modal"); return end
        if startup_action_safe and not startup_action_safe(actual) then return end
        for _, key in ipairs(modal.keys or {}) do pcall(remuda.key, actual, key) end
        settle = attempts + 3
        return
      end
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
        local checks, empty_checks = 0, 0
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
          if not task_in_composer and decision == "EMPTY" then
            empty_checks = empty_checks + 1
          else
            empty_checks = 0
          end
          -- The task can be accepted between type_text and this first poll.
          -- A fast TUI may also still be painting the text on its first empty
          -- poll, so require two consecutive empty captures. Busy is definitive.
          if busy or empty_checks >= 2 then
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
      if attempts >= (remuda._butler_task_poke_attempts or 60) then give_up("") end
    end })
    else
    PROMPT_DELIVERY.schedule(remuda, kind, actual, name, parent, task, {
      ready = startup.ready,
      modals = startup.modals,
      trust_dialog = function(screen)
        local modal = startup_modal(startup, screen)
        return modal ~= nil and modal.trust ~= nil
      end,
      allowed = function(retrying)
        if retrying then return remuda._butler_task_retry_policy(actual) end
        return remuda._butler_notify_policy(actual)
      end,
      human_active = function() return remuda._butler_human_active(actual) end,
      empty = function(screen)
        return remuda._butler_prompt_is_empty(kind, screen)
      end,
      timeout = remuda._butler_task_poke_deferrals or 600,
      ready_timeout = remuda._butler_task_poke_attempts or 60,
      submit_timeout = remuda._butler_submit_timeout or 300,
      on_done = function(delivered, reason)
        bus.pending_tasks[actual] = nil
        if delivered then return end
        local detail = reason or "delivery could not be verified"
        if detail == "submit" then detail = "it was typed but not submitted" end
        _butler_session_trace("task_poke_timeout", actual .. " " .. detail)
        pcall(remuda._butler_send, "butler", parent or "butler", "Task for " .. actual
          .. " was not delivered: " .. detail
          .. ". Resend it with `remuda butler send " .. actual .. " TASK` once it is.")
      end,
    })
    end
  end
  return actual
  end
  local result
  choose(candidates, choose_opts, function(actual, selected_kind, attempts)
    local ok, value = pcall(finish, actual, selected_kind, attempts)
    if ok then result = value
    else
      bus.launch_failures = bus.launch_failures or {}
      bus.launch_failures[name] = { attempts = attempts, error = tostring(value) }
      _butler_session_trace("launch_failed", name .. ": " .. tostring(value))
    end
  end)
  return result or ("launching " .. name)
end

local function make_topic(name, template, kind, parent, task, model)
  valid_child_name(name, "topic name")
  load_topic_config()
  local root = topic_config.project_home .. "/" .. name
  local created_now = create_fresh_directory(root)
  if created_now then
    bus.trusted_launch_dirs = bus.trusted_launch_dirs or {}
    bus.trusted_launch_dirs[root] = true
  end
  if not created_now then remuda.mkdir(root) end
  if template and not created_now then
    error("topic directory already exists; templates require a fresh topic name", 0)
  end
  local auto_trust = created_now and not template and directory_is_under(root, topic_config.project_home)
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
  if created_now and not template then write_agent_guidance(root, team_member_guidance(parent or "butler")) end
  return launch_agent(kind, name, root, model, parent, task, nil, auto_trust)
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
  return make_topic(name, template, kind, parent, task, model)
end
-- #29: a mail notice must never land on a human's half-typed line. Notices
-- wait per recipient, coalesce, and are typed only when the policy allows;
-- the declared `butler-notices` schedule (init.lua) retries every second.
bus.notices = bus.notices or {}
bus.notice_screens = bus.notice_screens or {}
bus.notice_seen = bus.notice_seen or {}
local NOTICE_STABLE_SECONDS = 3

-- The composer's text starts after the last prompt glyph and includes its
-- continuation rows up to the TUI footer. Returns "EMPTY" (nothing, or
-- exactly one of the kind's `placeholders`), "NON-EMPTY" or "UNPARSEABLE",
-- plus the text. Dim ghost suggestions stay NON-EMPTY and defer (#137).
local PROMPT_GLYPHS = { "❯", ">", "›" }
function remuda._butler_prompt_is_empty(kind, screen)
  local text, prompt_at
  -- Claude draws its empty composer as '❯' + NO-BREAK SPACE; Lua's %s
  -- misses U+00A0, so fold it to a space before parsing (every kind).
  screen = screen:gsub("\194\160", " ")
  local lines = {}
  for line in (screen .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  for index, line in ipairs(lines) do
    local rest = line:gsub("^%s+", "")
    if rest:sub(1, 3) == "│" then rest = rest:sub(4):gsub("^%s+", "") end
    for _, glyph in ipairs(PROMPT_GLYPHS) do
      if rest:sub(1, #glyph) == glyph then
        text, prompt_at = rest:sub(#glyph + 1), index
        break
      end
    end
  end
  if not text then return "UNPARSEABLE", "" end
  text = text:gsub("│%s*$", ""):match("^%s*(.-)%s*$")
  local parts = { text }
  for index = prompt_at + 1, #lines do
    local rest = lines[index]:gsub("^%s+", "")
    if rest:sub(1, 3) == "╰" or rest:sub(1, 3) == "└" or rest:sub(1, 3) == "─" then break end
    if rest:match("^%? for shortcuts")
        or (kind == "codex" and (rest:lower():find("context left", 1, true)
        or rest:match("^[^%s]+%s+[^%s]+%s+·"))) then
      break
    end
    if kind == "claude" and rest:sub(1, 3) == "│" then
      rest = rest:sub(4):gsub("│%s*$", "")
    end
    parts[#parts + 1] = rest
  end
  text = table.concat(parts, "\n"):match("^%s*(.-)%s*$")
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
  -- Attached panes use the human idle clock or screen stability below. Only
  -- detached panes need the core busy bit, whose Session metatable may throw
  -- when older cores lack output_idle data.
  if not attached and remuda.session then
    local checked, busy = pcall(function()
      local current = remuda.session(session)
      return current and current.is_busy
    end)
    -- Older cores and synthetic rows can lack a Session object, and some
    -- Session metatables can fail while computing is_busy. Unknown busy state
    -- falls through to the prompt parser; only an explicit busy state defers.
    if checked and busy == true then return false end
  end
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
  local full_screen, prompt_screen = screen, screen
  if remuda.capture_styled then
    -- A core with remuda#137 marks dim text: parse only the cursor row, and
    -- drop a TUI's dim ghost suggestion so it reads as the empty prompt it is.
    local captured, styled = pcall(remuda.capture_styled, session)
    if not captured then return false end
    local rows = {}
    for row_index, spans in ipairs(styled.rows or {}) do
      local parts = {}
      for _, span in ipairs(spans) do parts[#parts + 1] = span.text end
      rows[row_index] = table.concat(parts)
    end
    if not full_screen then full_screen = table.concat(rows, "\n") end
    local cursor_parts = {}
    for _, span in ipairs(styled.rows[styled.cursor.row] or {}) do
      if not span.dim then cursor_parts[#cursor_parts + 1] = span.text end
    end
    prompt_screen = table.concat(cursor_parts)
  end
  if not full_screen then
    local captured
    captured, full_screen = pcall(remuda.capture, session)
    if not captured then return false end
  end
  prompt_screen = prompt_screen or full_screen
  local agent = bus.agents[session]
  local kind = agent and agent.kind or ""
  if known_startup_modal(remuda._butler_agent_startup[kind] or {}, full_screen) then
    _butler_session_trace("notice_deferred_modal", session .. " " .. kind)
    return false
  end
  local decision, text = remuda._butler_prompt_is_empty(kind, prompt_screen)
  if seen.decision ~= decision then -- once per change, not every retry
    seen.decision = decision
    _butler_session_trace("notice_prompt", session .. " " .. kind .. " " .. decision .. " " .. text)
  end
  return decision == "EMPTY"
end

-- Startup dialogs are not empty prompts, so task/notice policy cannot be used
-- to decide whether a key or close is safe. Protect attached human panes using
-- the same idle/stable-screen rule, while allowing detached panes to proceed.
startup_action_safe = function(session, now)
  now = now or os.time()
  for _, row in ipairs(remuda.ls()) do
    if row.name == session and row.alive then
      if not row.attached then return true end
      if row.human_idle ~= nil then
        return row.human_idle >= (remuda._butler_notice_human_idle or 10)
      end
      local captured, screen = pcall(remuda.capture, session)
      if not captured then return false end
      local seen = bus.notice_screens[session] or {}
      bus.notice_screens[session] = seen
      if seen.startup_screen ~= screen then
        seen.startup_screen, seen.startup_since = screen, now
        return false
      end
      return now - (seen.startup_since or now) >= NOTICE_STABLE_SECONDS
    end
  end
  return false
end

-- A Return retry happens while the delegated task is still in the composer,
-- so the notice policy's empty-composer check cannot be reused. Keep its human
-- pause guard: use human_idle when available, otherwise require a stable screen.
bus.task_retry_screens = bus.task_retry_screens or {}
function remuda._butler_task_retry_policy(session, now)
  now = now or os.time()
  local row
  for _, candidate in ipairs(remuda.ls()) do
    if candidate.name == session then row = candidate end
  end
  if not row or not row.alive then return false end
  if not row.attached then return true end
  if row.human_idle ~= nil then
    return row.human_idle >= (remuda._butler_notice_human_idle or 10)
  end
  local captured, screen = pcall(remuda.capture, session)
  if not captured then return false end
  local seen = bus.task_retry_screens[session] or {}
  bus.task_retry_screens[session] = seen
  if seen.screen ~= screen then
    seen.screen, seen.since = screen, now
    return false
  end
  return now - seen.since >= NOTICE_STABLE_SECONDS
end

-- Some agent builds hide their idle marker while a person types. Keep those
-- waits on the human clock, not the bounded startup-readiness clock.
bus.human_activity_screens = bus.human_activity_screens or {}
function remuda._butler_human_active(session, now)
  now = now or os.time()
  local row
  for _, candidate in ipairs(remuda.ls()) do
    if candidate.name == session then row = candidate end
  end
  if not row or not row.alive or not row.attached then return false end
  if row.human_idle ~= nil then
    return row.human_idle < (remuda._butler_notice_human_idle or 10)
  end
  local captured, screen = pcall(remuda.capture, session)
  if not captured then return true end
  local seen = bus.human_activity_screens[session] or {}
  bus.human_activity_screens[session] = seen
  if seen.screen ~= screen then
    seen.screen, seen.since = screen, now
    return true
  end
  return now - seen.since < NOTICE_STABLE_SECONDS
end

-- `_butler_notify` queues each notice. Delivery verifies an empty composer;
-- for an idle stuck composer it uses the bounded, draft-preserving recovery below.
bus.notice_recoveries = bus.notice_recoveries or {}
local function pending_notice_text(pending)
  return pending.count == 1 and pending.text
    or (pending.count .. " new Butler messages arrived. Read them: remuda butler inbox")
end
local notice_recovery_error
local function input_was_busy(ok, result, detail)
  local message = tostring(ok and (detail or result) or result or "")
  return message == "a session input write is already in flight"
    or message == "runtime error: a session input write is already in flight"
end
local function refresh_pending_notice(session, pending)
  if not pending.message_order then return pending end
  local agent = bus.agents[session]
  local identity = agent and agent.id
  local order, notices = {}, {}
  for _, id in ipairs(pending.message_order) do
    local notice = pending.message_ids and pending.message_ids[id]
    if notice and identity and mail.is_unread(identity, id) then
      order[#order + 1], notices[id] = id, notice
    end
  end
  pending.message_order, pending.message_ids = order, notices
  pending.count = #order
  pending.text = order[#order] and notices[order[#order]] or nil
  if pending.count == 0 then
    local recovery = bus.notice_recoveries[session]
    if recovery and recovery.draft and recovery.draft ~= "" then
      notice_recovery_error(session, recovery, "mail was read while notice recovery was active; draft preserved")
    else
      bus.notices[session], bus.notice_recoveries[session] = nil, nil
    end
    return nil
  end
  return pending
end
local function recovery_screen(session)
  local ok, screen = pcall(remuda.capture, session)
  if not ok then return nil end
  local agent = bus.agents[session]
  local kind = agent and agent.kind or ""
  local decision, text = remuda._butler_prompt_is_empty(kind, tostring(screen or ""))
  return screen, decision, text
end
local function recovery_draft(kind, screen, first_line)
  local lines, prompt_at = {}, nil
  screen = tostring(screen or ""):gsub("\194\160", " "):gsub("\r\n", "\n")
  for line in (screen .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local composer_text = tostring(first_line or "")
  local composer_lines = {}
  for line in (composer_text .. "\n"):gmatch("(.-)\n") do
    composer_lines[line:match("^%s*(.-)%s*$")] = true
  end
  local composer_is_multiline = composer_text:find("\n", 1, true) ~= nil
  local glyphs = { "❯", ">", "›" }
  for index, line in ipairs(lines) do
    local rest = line:gsub("^%s+", "")
    if rest:sub(1, 3) == "│" then rest = rest:sub(4):gsub("^%s+", "") end
    for _, glyph in ipairs(glyphs) do
      if rest:sub(1, #glyph) == glyph then prompt_at = index end
    end
  end
  if not prompt_at then return nil, false end
  local parts = { composer_text }
  for index = prompt_at + 1, #lines do
    local rest = lines[index]:gsub("^%s+", "")
    if rest == "" then
      -- Empty rows can separate a boxed prompt from its lower border.
    elseif rest:sub(1, 3) == "╰" or rest:sub(1, 3) == "└" or rest:sub(1, 3) == "─" then
      break
    elseif kind == "claude" and rest:sub(1, 3) == "│" then
      local continuation = rest:sub(4):gsub("│%s*$", ""):match("^%s*(.-)%s*$")
      if continuation ~= "" then
        if composer_is_multiline then
          if not composer_lines[continuation] then return nil, false end
        else
          parts[#parts + 1] = continuation
        end
      end
    elseif kind == "codex" and (rest:match("^%? for shortcuts")
        or rest:lower():find("context left", 1, true)
        or rest:match("^[^%s]+%s+[^%s]+%s+·")) then
      -- Known Codex model/path and help footer rows are outside the composer.
    elseif composer_is_multiline and composer_lines[rest:match("^%s*(.-)%s*$")] then
      -- This row was already parsed into the full composer text.
    else
      -- Don't erase a multiline draft when the TUI's continuation rows
      -- cannot be distinguished from footer text.
      return nil, false
    end
  end
  return table.concat(parts, "\n"), true
end
local function normalized_composer(text)
  return tostring(text or ""):gsub("\194\160", " "):gsub("\r\n", "\n"):gsub("\r", "\n")
    :match("^%s*(.-)%s*$")
end
local function compact_composer(text)
  return tostring(text or ""):gsub("\194\160", " "):gsub("%s+", "")
end
local function notice_matches_composer(session, screen, text, expected)
  local agent = bus.agents[session]
  local composer, safe = recovery_draft(agent and agent.kind or "", screen, text)
  local expected_compact = compact_composer(expected)
  return (safe and compact_composer(composer) == expected_compact)
    or compact_composer(text) == expected_compact
end
local function notice_log_value(value)
  local raw = tostring(value or "")
  local length = #raw
  if length > 8192 then
    raw = raw:sub(1, 8192) .. ("<truncated; %d bytes total>"):format(length)
  end
  return string.format("%q", raw)
end
local function log_notice_verify_mismatch(session, screen, text, expected)
  -- Failure-only trace data; never display diagnostic captures in an agent pane.
  _butler_session_trace("notice_verify_mismatch", session
    .. " capture=" .. notice_log_value(screen)
    .. " composer=" .. notice_log_value(text)
    .. " expected=" .. notice_log_value(expected))
end
local function recovery_composer_empty(session, screen, decision, text)
  if decision ~= "EMPTY" then return false end
  local agent = bus.agents[session]
  local composer, safe = recovery_draft(agent and agent.kind or "", screen, "")
  return safe and normalized_composer(composer) == ""
end
notice_recovery_error = function(session, state, reason)
  state.failed = true
  local agent = bus.agents[session]
  local parent = agent and agent.parent or "butler"
  _butler_session_trace("notice_recovery_failed", session .. " " .. reason)
  pcall(remuda._butler_send, "butler", parent,
    "Could not safely deliver queued Butler mail to " .. session .. ": " .. reason
    .. ". Inspect the composer and resend the notice."
    .. (state.draft and (" Parsed composer draft: " .. state.draft) or ""))
  bus.notices[session] = nil
  bus.notice_recoveries[session] = nil
  return false
end
local function complete_notice_recovery(session, state)
  local pending = bus.notices[session]
  if pending then
    if state.message_ids and pending.message_order then
      local submitted = {}
      for _, id in ipairs(state.message_ids) do submitted[id] = true end
      local order = {}
      for _, id in ipairs(pending.message_order) do
        if not submitted[id] then order[#order + 1] = id end
      end
      pending.message_order = order
      pending.count = #order
      pending.text = order[#order] and pending.message_ids[order[#order]] or nil
    else
      pending.count = pending.count - state.count
    end
    if pending.count <= 0 then bus.notices[session] = nil end
  end
  bus.notice_recoveries[session] = nil
  return true
end
local function recovery_human_safe(session, allow_busy)
  local session_row
  for _, candidate in ipairs(remuda.ls()) do
    if candidate.name == session then session_row = candidate end
  end
  if not session_row or not session_row.alive or session_row.attached then return false end
  if remuda._butler_human_active(session) then return false end
  if remuda.session then
    local ok, busy = pcall(function()
      local row = remuda.session(session)
      return row and row.is_busy
    end)
    if ok and busy == true and not allow_busy then return false end
  end
  return true
end
local function begin_notice_submit(session, state, draft)
  local pending = bus.notices[session]
  if not pending then bus.notice_recoveries[session] = nil; return true end
  state.draft = draft
  state.count = pending.count
  state.message_ids = {}
  for _, id in ipairs(pending.message_order or {}) do state.message_ids[#state.message_ids + 1] = id end
  state.notice = pending_notice_text(pending)
  if draft and draft ~= "" then
    state.notice = state.notice .. "\n\nYour unsent draft was: " .. draft
  end
  bus.notice_recoveries[session] = state
  local typed, result, why = pcall(remuda.type_text, session, state.notice, 0.1)
  if input_was_busy(typed, result, why) then
    state.phase = "retry_type"
    return false
  end
  if not typed then return notice_recovery_error(session, state,
    "the notice could not be typed: " .. tostring(why or result)) end
  state.phase, state.checks, state.saw_notice = "verify_notice", 0, false
  return false
end
local function tick_notice_recovery(session, state)
  if state.failed then return false end
  local observing_submit = state.phase == "verify_notice" or state.phase == "verify_existing"
  if not recovery_human_safe(session, observing_submit) then return false end
  local busy = false
  if remuda.session then
    local checked, value = pcall(function()
      local row = remuda.session(session)
      return row and row.is_busy
    end)
    busy = checked and value == true
  end
  if not busy then state.checks = (state.checks or 0) + 1 end
  if state.checks > 40 then return notice_recovery_error(session, state, "verification timed out") end
  local screen, decision, text = recovery_screen(session)
  if not screen then return notice_recovery_error(session, state, "the pane could not be captured") end
  local normalized = tostring(screen):gsub("\r\n", "\n"):gsub("\r", "\n")
  if state.phase == "retry_type" then
    return begin_notice_submit(session, state, state.draft)
  end
  if state.phase == "probe" then
    if state.last_screen == normalized then state.stable = (state.stable or 0) + 1
    else state.last_screen, state.stable = normalized, 1 end
    if state.stable < 2 then return false end
    if decision == "EMPTY" then
      bus.notice_recoveries[session] = nil
      return begin_notice_submit(session, state)
    end
    state.pre_redraw_decision, state.pre_redraw_screen, state.pre_redraw_text = decision, screen, text
    local redrawn, why = pcall(remuda.key, session, "C-l")
    if not redrawn then return notice_recovery_error(session, state, "Ctrl-L redraw failed: " .. tostring(why)) end
    state.phase = "redrawn"
    return false
  elseif state.phase == "redrawn" then
    if decision == "EMPTY" then
      if state.pre_redraw_decision == "NON-EMPTY" then
        local pending = pending_notice_text(bus.notices[session] or { count = 0, text = "" })
        if notice_matches_composer(session, state.pre_redraw_screen, state.pre_redraw_text, pending) then
          return begin_notice_submit(session, state)
        end
        local agent = bus.agents[session]
        local draft, safe = recovery_draft(agent and agent.kind or "", state.pre_redraw_screen,
          state.pre_redraw_text)
        if not safe then
          return notice_recovery_error(session, state, "the pre-redraw draft could not be preserved")
        end
        return begin_notice_submit(session, state, draft)
      end
      return begin_notice_submit(session, state)
    end
    if decision == "UNPARSEABLE" or not text or text == "" then
      return notice_recovery_error(session, state, "the composer remained unparseable after Ctrl-L")
    end
    local current_notice = pending_notice_text(bus.notices[session] or { count = 0, text = "" })
    if notice_matches_composer(session, screen, text, current_notice) then
      local pressed, result, why = pcall(remuda.key, session, "RET")
      if input_was_busy(pressed, result, why) then return false end
      if not pressed then return notice_recovery_error(session, state,
        "the existing Butler notice could not be submitted: " .. tostring(why or result)) end
      state.phase, state.checks, state.notice = "verify_existing", 0, current_notice
      state.message_ids = {}
      for _, id in ipairs((bus.notices[session] or {}).message_order or {}) do
        state.message_ids[#state.message_ids + 1] = id
      end
      return false
    end
    local agent = bus.agents[session]
    local startup = remuda._butler_agent_startup[agent and agent.kind or ""] or {}
    local draft, safe = recovery_draft(agent and agent.kind or "", screen, text)
    if not safe then
      return notice_recovery_error(session, state, "the draft spans unrecognized composer rows")
    end
    if not startup.clear_input then
      state.draft = draft
      return notice_recovery_error(session, state, "this agent has no verified composer clear key")
    end
    state.draft = draft
    local cleared, why = pcall(remuda.key, session, startup.clear_input)
    if not cleared then return notice_recovery_error(session, state, "the draft clear key failed: " .. tostring(why)) end
    state.phase, state.checks = "verify_clear", 0
    return false
  elseif state.phase == "verify_clear" then
    if not recovery_composer_empty(session, screen, decision, text) then
      return notice_recovery_error(session, state, "the composer did not become empty after the clear key")
    end
    return begin_notice_submit(session, state, state.draft)
  elseif state.phase == "verify_existing" then
    local notice_visible = state.notice and tostring(screen):gsub("%s+", "")
      :find(tostring(state.notice):gsub("%s+", ""):sub(1, 32), 1, true) ~= nil
    local notice_in_composer = decision == "NON-EMPTY"
      and notice_matches_composer(session, screen, text, state.notice)
    if decision == "EMPTY" or (notice_visible and not notice_in_composer) then
      return complete_notice_recovery(session, state)
    end
    if busy then return false end
    if state.checks >= 6 then
      return notice_recovery_error(session, state, "the existing Butler notice did not leave the composer")
    end
    return false
  elseif state.phase == "verify_notice" then
    local notice_head = tostring(state.notice or ""):gsub("%s+", ""):sub(1, 32)
    local notice_visible = notice_head ~= "" and normalized:gsub("%s+", ""):find(notice_head, 1, true) ~= nil
    local notice_in_composer = decision == "NON-EMPTY"
      and notice_matches_composer(session, screen, text, state.notice)
    if notice_visible or notice_in_composer then
      state.saw_notice = true
    end
    local agent = bus.agents[session]
    local non_tui_echo = decision == "UNPARSEABLE" and agent
      and agent.kind ~= "claude" and agent.kind ~= "codex" and notice_visible
    if (decision == "EMPTY" and (state.saw_notice or busy))
        or (state.saw_notice and notice_visible and not notice_in_composer) or non_tui_echo then
      return complete_notice_recovery(session, state)
    end
    if notice_in_composer and not state.return_retried then
      if not recovery_human_safe(session) then return false end
      local pressed, result, why = pcall(remuda.key, session, "RET")
      if input_was_busy(pressed, result, why) then return false end
      if not pressed then return notice_recovery_error(session, state,
        "the notice Return failed: " .. tostring(why or result)) end
      state.return_retried = true
      return false
    end
    if state.checks >= 12 then
      log_notice_verify_mismatch(session, screen, text, state.notice)
      return notice_recovery_error(session, state, "the notice submit could not be verified")
    end
    return false
  end
  return notice_recovery_error(session, state, "unknown recovery state")
end
local function deliver_notice(session)
  local pending = bus.notices[session]
  if not pending then return true end
  pending = refresh_pending_notice(session, pending)
  if not pending then return true end
  if bus.pending_tasks[session] then return false end
  local recovering = bus.notice_recoveries[session]
  if recovering then
    if (recovering.failed or recovering.phase == "probe" or recovering.phase == "redrawn")
        and remuda._butler_notify_policy(session) then
      bus.notice_recoveries[session] = nil
      recovering = nil
    else
      return tick_notice_recovery(session, recovering)
    end
  end
  if remuda._butler_notify_policy(session) then
    local state = { phase = "verify_notice", count = pending.count, notice = pending_notice_text(pending), checks = 0 }
    state.message_ids = {}
    for _, id in ipairs(pending.message_order or {}) do state.message_ids[#state.message_ids + 1] = id end
    local typed, result, why = pcall(remuda.type_text, session, state.notice, 0.1)
    if input_was_busy(typed, result, why) then return false, "busy" end
    if not typed then return false, why or result end
    bus.notice_recoveries[session] = state
    return false
  end
  local screen, decision = recovery_screen(session)
  if not screen or decision == "EMPTY" then return false end
  local state = { phase = "probe", count = pending.count, checks = 0 }
  bus.notice_recoveries[session] = state
  return tick_notice_recovery(session, state)
end
function remuda._butler_notify(alias, notice, message_id)
  local _, recipient = mail_id(alias, false)
  if message_id and not mail.is_unread(recipient.id, message_id) then return true end
  if message_id then
    local seen = bus.notice_seen[recipient.id] or {}
    bus.notice_seen[recipient.id] = seen
    if seen[message_id] then return false end
    seen[message_id] = true
  end
  local pending = bus.notices[alias] or { count = 0 }
  if message_id then
    pending.message_ids = pending.message_ids or {}
    pending.message_order = pending.message_order or {}
    if pending.message_ids[message_id] then return false end
    pending.message_ids[message_id] = notice
    pending.message_order[#pending.message_order + 1] = message_id
  end
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
function remuda._butler_send(from, to, text)
  local _, recipient = mail_id(to, false)
  local sender = (from == "operator" or from == "outside") and mail_address(from)
    or mail_address(resolve(from))
  local message = deliver_message({ from = sender, to = mail_address(recipient.alias), text = text })
  local notice = "Butler message " .. message.id .. " from " .. sender.session
    .. " arrived. Read it: remuda butler inbox"
  local delivered, why = remuda._butler_notify(recipient.alias, notice, message.id)
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
    .. " arrived. Read it: remuda butler inbox", message.id)
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
  local result = mail.inbox(id)
  if mail.unread(id) == 0 then
    for alias, agent in pairs(bus.agents) do
      if agent.id == id then
        local recovery = bus.notice_recoveries[alias]
        if recovery and recovery.draft and recovery.draft ~= "" then
          notice_recovery_error(alias, recovery, "mail was read while notice recovery was active; draft preserved")
        else
          bus.notices[alias], bus.notice_recoveries[alias] = nil, nil
        end
      end
    end
    local seen = bus.notice_seen[id]
    if seen then
      for message_id in pairs(seen) do
        if not mail.is_unread(id, message_id) then seen[message_id] = nil end
      end
    end
  end
  return result
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

local butler_attempts = remuda._butler_attempts or {}
remuda._butler_attempts = butler_attempts
function remuda._butler_sessions()
  local rows = {}
  for _, item in ipairs(team_order()) do
    local agent = bus.agents[item.id]
    rows[#rows + 1] = string.rep(" ", item.indent * 2) .. (item.orphan and "[orphan] " or "")
      .. display_name(item.id) .. "\t" .. tostring(agent.kind or "") .. "\t"
      .. tostring(agent.parent or "-")
  end
  local out = #rows == 0 and "no Butler agents"
    or "SESSION\tAGENT\tLEADER\n" .. table.concat(rows, "\n")
  if bus.agents.butler and #butler_attempts > 0 then
    local details = {}
    for _, attempt in ipairs(butler_attempts) do
      details[#details + 1] = attempt.kind .. ": " .. attempt.reason
        .. (attempt.detail and (" (" .. attempt.detail:gsub("\n", " ") .. ")") or "")
    end
    out = out .. "\nBUTLER ATTEMPTS\n" .. table.concat(details, "\n")
  end
  local member_attempts = {}
  for _, item in ipairs(team_order()) do
    local agent = bus.agents[item.id]
    if item.id ~= "butler" and agent.launch_attempts then
      local failed = {}
      for _, attempt in ipairs(agent.launch_attempts) do
        if attempt.reason ~= "ready" then failed[#failed + 1] = attempt.kind .. ": " .. attempt.reason end
      end
      if #failed > 0 then member_attempts[#member_attempts + 1] = display_name(item.id) .. ": " .. table.concat(failed, ", ") end
    end
  end
  if #member_attempts > 0 then out = out .. "\nMEMBER ATTEMPTS\n" .. table.concat(member_attempts, "\n") end
  local failed_names = {}
  for name in pairs(bus.launch_failures or {}) do failed_names[#failed_names + 1] = name end
  table.sort(failed_names)
  if #failed_names > 0 then
    local failed = {}
    for _, name in ipairs(failed_names) do
      local report = bus.launch_failures[name]
      local details = {}
      for _, attempt in ipairs(report.attempts or {}) do
        details[#details + 1] = attempt.kind .. ": " .. attempt.reason
          .. (attempt.detail and (" (" .. attempt.detail:gsub("\n", " ") .. ")") or "")
      end
      failed[#failed + 1] = name .. ": " .. (#details > 0 and table.concat(details, ", ") or report.error)
    end
    out = out .. "\nFAILED LAUNCHES\n" .. table.concat(failed, "\n")
  end
  return out
end

local function registry_list(include_ended)
  local latest, first_created = {}, {}
  if identity_path then
    local file = io.open(identity_path, "r")
    if file then
      for line in file:lines() do
        local id, alias = json_field(line, "id"), json_field(line, "alias")
        if id and alias then
          local created_at, ended_at = json_field(line, "created_at"), json_field(line, "ended_at")
          local state = json_field(line, "state")
          local unknown = line:match('"created_at_unknown":true') ~= nil
            or not created_at or (ended_at and created_at == ended_at)
          if first_created[id] == nil and latest[id] == nil and not unknown then
            first_created[id] = created_at
          end
          local shown_created = created_at
          if unknown then shown_created = first_created[id] end
          latest[id] = {
            id = id, alias = alias, kind = json_field(line, "kind") or "",
            leader = json_field(line, "leader_id") or "",
            state = state or (ended_at and "ended" or "running"),
            reason = json_field(line, "reason") or "",
            created = shown_created or "?",
            ended = ended_at or "",
          }
        end
      end
      file:close()
    end
  end
  local records = {}
  for _, record in pairs(latest) do
    if include_ended or record.state == "running" then records[#records + 1] = record end
  end
  table.sort(records, function(a, b)
    if a.alias ~= b.alias then return a.alias < b.alias end
    return a.id < b.id
  end)
  local lines = { "ID\tALIAS\tKIND\tLEADER\tSTATE\tREASON\tCREATED\tENDED" }
  for _, record in ipairs(records) do
    lines[#lines + 1] = table.concat({ record.id, record.alias, record.kind, record.leader,
      record.state, record.reason, record.created, record.ended }, "\t")
  end
  return table.concat(lines, "\n")
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
  local attempts = agent.launch_attempts or (session.name == "butler" and remuda._butler_attempts)
  if attempts then
    local skipped = {}
    for _, attempt in ipairs(attempts) do
      if attempt.reason ~= "ready" then skipped[#skipped + 1] = attempt.kind .. " " .. attempt.reason end
    end
    if #skipped > 0 then detail = detail .. " · skipped " .. table.concat(skipped, ", ") end
  end
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
local command_entries = {}
local function command(order, verb, usage, run)
  local entry = { id = verb, order = order, verb = verb, usage = usage, run = run }
  command_entries[verb] = entry
  if not remuda.contribute then remuda._butler_contribute("butler.command", verb, entry) end
end
command(10, "sessions", "  remuda butler sessions", function(args)
  if #args == 1 then return remuda._butler_sessions() end
end)
command(12, "status", "  remuda butler status  (0=up, 75=launching, 1=failed)", function(args)
  if #args == 1 then
    local message, code = remuda._butler_status()
    if code ~= 0 then
      if type(remuda.fail) == "function" then return remuda.fail(message, code) end
      error(message, 0)
    end
    return message
  end
end)
command(15, "agents", "  remuda butler agents [--all]", function(args)
  if #args == 1 then return registry_list(false) end
  if #args == 2 and args[2] == "--all" then return registry_list(true) end
end)
command(20, "launch", "  remuda butler launch <claude|codex> [name] [--model M]", function(args, caller)
  if not args[2] then return nil end
  local registered = false
  for _, row in ipairs(contributions("butler.agent")) do if row.id == args[2] then registered = true end end
  if not registered then return nil end
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
command(100, "matrix", remuda.butler.matrix.cli_usage(), function(args, caller)
  return remuda.butler.matrix.cli(args, current_agent(caller))
end)
remuda._butler_command_run = function(verb, args, caller)
  local entry = command_entries[verb]
  if entry then return entry.run(args, caller) end
end

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
-- Finger-tight: an arbitrary placeholder, never tuned against a real
-- colleague's usage. Tightening step: revisit once this has run on a real
-- machine for a real "몇 날" and someone has an opinion about the cadence.
-- remuda._butler_compaction_interval lets a test override it (same idiom as
-- every other remuda._butler_* test hook in this file).
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
    local size = f:seek("end") or 0
    f:close()
    if size >= 512 * 1024 then
      os.remove(path .. ".1")
      os.rename(path, path .. ".1")
    end
    f = io.open(path, "a")
    if not f then return end
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
function remuda._butler_status()
  local name = butler_name or remuda._butler_initial_name
  local selected = remuda._butler_selected_agent
  if remuda._butler_start_pending or remuda._butler_launching then
    local lines = { "launching", "readiness budget: " .. tostring(readiness_chain_budget()) }
    for _, attempt in ipairs(remuda._butler_attempts or {}) do
      lines[#lines + 1] = attempt.kind .. ": " .. attempt.reason
        .. (attempt.detail and attempt.detail ~= "" and (": " .. one_line(attempt.detail)) or "")
    end
    return table.concat(lines, "\n"), 75
  end
  if selected and session_exists(name) then return "butler: up (" .. tostring(selected) .. ")", 0 end
  if remuda._butler_start_error then
    local lines = { "failed" }
    for _, attempt in ipairs(remuda._butler_attempts or {}) do
      lines[#lines + 1] = attempt.kind .. ": " .. attempt.reason
        .. (attempt.detail and attempt.detail ~= "" and (": " .. one_line(attempt.detail)) or "")
    end
    return table.concat(lines, "\n"), 1
  end
  return "launching\nreadiness budget: " .. tostring(readiness_chain_budget()), 75
end
local function launch_butler()
  local requested_name = butler_name or remuda._butler_initial_name
  if butler_session_cwd then
    remuda.mkdir(butler_session_cwd)
    write_agent_guidance(butler_session_cwd, BUTLER_GUIDANCE, true)
  end
  local stale_session = session_exists(requested_name)
  if remuda._butler_selected_agent and stale_session then
    butler_name = requested_name
    remuda._butler_name = butler_name
    return
  end
  if remuda._butler_launching then return "launching Butler" end
  remuda._butler_selected_agent = nil
  remuda._butler_launching = true
  remuda._butler_start_pending = true
  if stale_session then pcall(remuda.close, requested_name) end
  local order = configured_agent_order()
  local telemetry_by_kind = {}
  local choose_opts = {
    name = requested_name, cwd = butler_session_cwd, argv = remuda._butler_argv,
    skip_probe = remuda._butler_argv ~= nil,
    spec = function(candidate_kind)
      local telemetry = setup_telemetry(candidate_kind, { name = requested_name, status_path = status_path })
      telemetry_by_kind[candidate_kind] = telemetry
      return { name = requested_name, token = butler_token, mcp_config_path = mcp_config_path,
        settings_path = telemetry.settings_path, telemetry = telemetry, system_prompt = SYSTEM_PROMPT }
    end,
    env = function(candidate_kind)
      return { REMUDA_BUTLER_SESSION_NAME = requested_name, REMUDA_BUTLER_AGENT_ID = root_identity.id,
        REMUDA_BUTLER_AGENT_ALIAS = "butler", REMUDA_BUTLER_LEADER_ID = "",
        REMUDA_BUTLER_AGENT_KIND = candidate_kind, CLAUDE_CODE_FORCE_SESSION_PERSISTENCE = "1" }
    end,
  }
  local function finish(selected, kind, attempts)
  butler_attempts = attempts
  remuda._butler_attempts = attempts
  bus.agents.butler.launch_attempts = attempts
  if not selected then
    local failures = { "butler: no candidate became ready" }
    for _, a in ipairs(attempts) do
      failures[#failures + 1] = "butler: " .. one_line(a.kind) .. ": " .. one_line(a.reason)
        .. (a.detail and a.detail ~= "" and (" (" .. one_line(a.detail) .. ")") or "")
    end
    local message = table.concat(failures, "\n")
    remuda._butler_start_error = message
    remuda._butler_start_pending = false
    for _, attempt in ipairs(attempts) do
      io.stderr:write("butler: " .. one_line(attempt.kind) .. ": " .. one_line(attempt.reason)
        .. (attempt.detail and attempt.detail ~= "" and (" (" .. one_line(attempt.detail) .. ")") or "") .. "\n")
    end
    _butler_session_trace("reconcile_error", message)
    return nil
  end
  butler_name, butler_kind = selected, kind
  remuda._butler_name, remuda._butler_selected_agent = selected, kind
  bus.agents.butler.kind, bus.agents.butler.telemetry = kind, telemetry_by_kind[kind]
  local root_record = bus.identities.butler or root_identity
  root_record.kind = kind
  bus.identities.butler, bus.identity_ids[root_record.id] = root_record, root_record
  identity_record(root_record)
  remuda._butler_start_error = nil
  remuda._butler_start_pending = false
  return selected
  end
  local attempts = choose(order, choose_opts, function(selected, kind, attempts)
    remuda._butler_launching = nil
    local ok, err = pcall(finish, selected, kind, attempts)
    if not ok then
      remuda._butler_start_error = tostring(err)
      _butler_session_trace("reconcile_error", tostring(err))
    end
  end)
  butler_attempts, remuda._butler_attempts = attempts, attempts
  bus.agents.butler.launch_attempts = attempts
  return "launching Butler"
end

-- The lifecycle declaration owns the one compaction schedule. The session's
-- one-time run_script call only enables its callback; reloading the mod
-- replaces the schedule without leaving an old handle behind.
function remuda._butler_register_compaction_schedule()
  _butler_trace("registered")
  local state = remuda._butler_state or remuda._butler_compaction_state or {}
  remuda._butler_compaction_reset_idle(state)
  if not remuda._butler_state then remuda._butler_compaction_state = state end
  if remuda._butler_state then
    remuda._butler_state.compaction_enabled = true
  else
    remuda._butler_compaction_enabled = true
  end
  return true
end
function remuda._butler_compaction_tick(target_name, dry_run)
  if target_name and not remuda._butler_compaction_has_session(target_name) then
    return "unknown session: " .. tostring(target_name)
  end
  local owner_state = remuda._butler_state or remuda._butler_compaction_state or {}
  if not target_name then
    if dry_run then
      -- A dry run is observational and may be used before the schedule is enabled.
    elseif remuda._butler_state then
      if not remuda._butler_state.compaction_enabled then return end
    elseif not remuda._butler_compaction_enabled then
      return
    end
  end
  local names = {}
  if target_name then
    names[1] = target_name
  else
    for name, agent in pairs(remuda._butler_bus.agents) do
      names[#names + 1] = agent.session_name or name
    end
    table.sort(names)
  end
  local results = {}
  for _, session_name in ipairs(names) do
    if session_name and session_name ~= "" then
      local members = owner_state.compaction_members or remuda._butler_compaction_members_state or {}
      if not dry_run then owner_state.compaction_members = members end
      local agent = remuda._butler_bus.agents[session_name] or {}
      local state_key = tostring(agent.id or session_name)
      local state = members[state_key] or {}
      if not dry_run then
        members[state_key] = state
        remuda._butler_compaction_members_state = members
      end
      if state.compaction_in_progress then
        results[#results + 1] = session_name .. ":compaction_in_progress"
      elseif owner_state.compaction_fleet_active and owner_state.compaction_fleet_active ~= state_key then
        results[#results + 1] = session_name .. ":fleet_busy"
      elseif state.pending_restore_blocked then
        results[#results + 1] = session_name .. ":restore_blocked"
      elseif state.pending_restore_model_unavailable then
        results[#results + 1] = session_name .. ":restore_needs_model_family"
      elseif state.pending_restore_model then
        if dry_run then
          results[#results + 1] = session_name .. ":pending_restore"
        elseif (state.cooldown_ticks or 0) > 0 then
          state.cooldown_ticks = state.cooldown_ticks - 1
          results[#results + 1] = session_name .. ":restore_pending_cooldown"
        elseif type(remuda.expect) == "function" then
          results[#results + 1] = remuda.butler.compact(session_name)
        else
          results[#results + 1] = session_name .. ":restore_pending_core_lacks_expect"
        end
      else
        local should_send, event, ctx = remuda.butler.compaction_policy(session_name, state, dry_run)
        if dry_run then
          local telemetry = remuda._butler_telemetry_for(agent) or {}
          local family = compaction_family(telemetry.model) or compaction_family(agent.model)
          if should_send and agent.kind == "claude" and not family then
            results[#results + 1] = table.concat({ session_name, "skip: model family unknown",
              "ctx=" .. tostring(ctx), "idle_captures=" .. tostring(state.idle_ticks or 0) }, "; ")
          else
            local sequence = remuda._butler_compaction_sequence(agent.kind or "claude", family,
              remuda._butler_compaction_model or "sonnet")
            results[#results + 1] = table.concat({ session_name, "decision=" .. tostring(event),
              "ctx=" .. tostring(ctx), "idle_captures=" .. tostring(state.idle_ticks or 0),
              "keys=" .. table.concat(sequence, " -> ") .. " -> visible switch option (if prompted)" }, "; ")
          end
        elseif should_send then
          if type(remuda.expect) ~= "function" then
            if not remuda._butler_compaction_core_missing then
              remuda._butler_compaction_core_missing = true
              _butler_trace("disabled", "remuda.expect unavailable; update remuda core")
              io.stderr:write("butler: compaction disabled; this remuda core lacks remuda.expect (run `remuda upgrade`)\n")
            end
            results[#results + 1] = "compaction disabled: core lacks remuda.expect (run remuda upgrade)"
          else
            results[#results + 1] = remuda.butler.compact(session_name)
          end
      else
        if event ~= state.last_trace_event then
          _butler_trace(event, "ctx=" .. tostring(ctx))
          state.last_trace_event = event
        end
        results[#results + 1] = session_name .. ":" .. tostring(event)
        end
      end
    end
  end
  if target_name then return results[1] end
  if dry_run then return table.concat(results, "\n") end
  return nil
end

function remuda._butler_compaction_execute(session_name)
  if not session_name then return "no session" end
  if not remuda._butler_compaction_has_session(session_name) then
    return "unknown session: " .. tostring(session_name)
  end
  local owner_state = remuda._butler_state or remuda._butler_compaction_state or {}
  owner_state.compaction_members = owner_state.compaction_members or remuda._butler_compaction_members_state or {}
  remuda._butler_compaction_members_state = owner_state.compaction_members
  local agent = remuda._butler_bus.agents[session_name] or {}
  local state_key = tostring(agent.id or session_name)
  local state = owner_state.compaction_members[state_key] or {}
  owner_state.compaction_members[state_key] = state
  if state.compaction_in_progress then return "compaction_in_progress" end
  if owner_state.compaction_fleet_active and owner_state.compaction_fleet_active ~= state_key then return "fleet_busy" end
  local level = remuda.butler.ctx_level(session_name)
  local ctx = level.used or "?"
  local detail = "ctx=" .. tostring(ctx)
  local config = compaction_config()
  state.compaction_in_progress = true
  owner_state.compaction_fleet_active = state_key
    local function report(reason, suppress_notice, keep_fleet)
      state.compaction_in_progress = false
      if not keep_fleet and owner_state.compaction_fleet_active == state_key then owner_state.compaction_fleet_active = nil end
      state.cooldown_ticks = config.failure_cooldown_ticks
      if keep_fleet then state.cooldown_ticks = 0 end
      _butler_trace("error", detail .. " reason=" .. tostring(reason))
      if not suppress_notice then
        pcall(remuda._butler_send, session_name, agent.parent or "butler", "Compaction failed: " .. tostring(reason))
      end
    end
    local screen_ok, screen = pcall(remuda.capture, session_name)
    local agent = remuda._butler_bus.agents[session_name] or {}
    local initial_telemetry = remuda._butler_telemetry_for(agent) or {}
    local restore_only = state.pending_restore_model ~= nil or state.pending_restore_model_unavailable == true
    local prior_display = state.pending_restore_display or initial_telemetry.model
    local prior = state.pending_restore_model or compaction_family(initial_telemetry.model)
      or compaction_family(agent.model)
    local prior_command = prior
    local prior_window = tonumber(state.pending_restore_context_window or initial_telemetry.context_window)
    local low = remuda._butler_compaction_model or "sonnet"
    if agent.kind == "claude" and not restore_only and not prior then
      state.compaction_in_progress = false
      if owner_state.compaction_fleet_active == state_key then owner_state.compaction_fleet_active = nil end
      state.cooldown_ticks = config.failure_cooldown_ticks
      if not state.pending_restore_notice_sent then
        state.pending_restore_notice_sent = true
        pcall(remuda._butler_send, session_name, agent.parent or "butler",
          "compaction skipped: model family is unknown; cannot safely restore after switching to Sonnet")
      end
      _butler_trace("skipped", detail .. " reason=unknown_model_family")
      return "skipped_unknown_model_family"
    end
    _butler_trace("sent", detail)
    local dialog_timeout = math.max(1, config.dialog_timeout)
    local failure_reason, compact_sent, restore_attempt_count, verification_failed
    local verify, request_restore, watch_restore, restore_after_unknown
    local function watch(branches, options, restore_on_error)
      local ok, handle = pcall(remuda.expect, session_name, branches, options)
      if not ok then
        if restore_on_error then request_restore("could not start restore watcher: " .. tostring(handle))
        else report("could not start verification watcher: " .. tostring(handle)) end
        return nil
      end
      return handle
    end
    if not screen_ok or type(screen) ~= "string" then report("could not capture model status"); return end
    local ctx_before = tonumber(ctx)
    local function is_switch_dialog(value)
      return compaction_is_switch_dialog(value)
    end
    local is_unknown_dialog = remuda._butler_compaction_is_unknown_dialog
    local function register_unknown_dialog(value)
      remuda._butler_compaction_dialog_registry = remuda._butler_compaction_dialog_registry or {}
      local registry = remuda._butler_compaction_dialog_registry
      if #registry >= 50 then table.remove(registry, 1) end
      table.insert(registry, { session = session_name, kind = "unknown_dialog", at = os.time() })
    end
    local function wait_until_output_idle(callback)
      local deadline = os.time() + math.max(1, math.ceil(config.idle_wait_timeout))
      local timer, finished
      local function poll()
        if finished then return end
        local ok, current = pcall(remuda.session, session_name)
        if not ok or not current then
          finished = true
          if timer then remuda.cancel(timer) end
          callback("session unavailable")
        elseif current.attached then
          finished = true
          if timer then remuda.cancel(timer) end
          callback("human attached")
        elseif current.is_busy == false then
          finished = true
          if timer then remuda.cancel(timer) end
          callback(nil)
        elseif os.time() >= deadline then
          finished = true
          if timer then remuda.cancel(timer) end
          callback("output idle timeout")
        end
      end
      poll()
      if not finished then timer = remuda.schedule({ every = 0.25, run = poll }) end
    end
    local function wait_until_switch_closed(callback)
      local deadline = os.time() + math.max(1, math.ceil(config.dialog_timeout))
      local timer, finished
      local function poll()
        if finished then return end
        local ok, current = pcall(remuda.capture, session_name)
        if ok and type(current) == "string" and not is_switch_dialog(current) then
          finished = true
          if timer then remuda.cancel(timer) end
          wait_until_output_idle(callback)
        elseif os.time() >= deadline then
          finished = true
          if timer then remuda.cancel(timer) end
          callback("switch dialog did not close")
        end
      end
      poll()
      if not finished then timer = remuda.schedule({ every = 0.25, run = poll }) end
    end
    local function answer_switch_dialog(_, on_answered)
      wait_until_output_idle(function(idle_error)
        if idle_error then
          if idle_error == "human attached" then report("aborted: human attached; restore suppressed")
          else
            failure_reason = "switch dialog did not become idle: " .. idle_error
            restore_after_unknown(failure_reason)
          end
          return
        end
        local captured, current = pcall(remuda.capture, session_name)
        if not captured or type(current) ~= "string" then
          failure_reason = "could not capture switch dialog"
          request_restore(failure_reason)
          return
        end
        if not is_switch_dialog(current) then
          on_answered()
          return
        end
        local answer = remuda.expect_option(current, function(label)
          local lower = label:lower()
          return lower:find("yes", 1, true) and lower:find("switch", 1, true)
        end)
        if not answer then
          register_unknown_dialog(current)
          failure_reason = "switch dialog had no unique yes/switch option"
          restore_after_unknown(failure_reason)
          return
        end
        local safe = remuda._butler_compaction_action_guard(session_name)
        if safe then
          if safe == "human attached" then report("aborted: human attached; restore suppressed")
          else request_restore("aborted: " .. safe) end
          return
        end
        local ok, err = pcall(remuda.key, session_name, answer)
        if not ok then
          failure_reason = "switch dialog answer failed: " .. tostring(err)
          restore_after_unknown(failure_reason)
          return
        end
        wait_until_switch_closed(function(close_error)
          if close_error then
            if close_error == "human attached" then
              report("aborted: human attached; restore suppressed")
            else
              failure_reason = close_error
              restore_after_unknown(close_error)
            end
          else
            on_answered()
          end
        end)
      end)
    end
    local function after_restored()
      if compact_sent then
        if verification_failed then report(failure_reason or "verification failed after model restore")
        else verify() end
      elseif restore_only then
        state.pending_restore_model = nil
        state.pending_restore_model_unavailable = nil
        state.pending_restore_display = nil
        state.pending_restore_context_window = nil
        state.pending_restore_notice_sent = nil
        state.pending_restore_mismatch_notice_sent = nil
        state.pending_restore_blocked = nil
        state.restore_retry_in_progress = nil
        state.compaction_in_progress = false
        state.cooldown_ticks = config.cooldown_ticks
        if owner_state.compaction_fleet_active == state_key then owner_state.compaction_fleet_active = nil end
        _butler_trace("restored", detail .. " retry=confirmed")
      else
        state.pending_restore_model = nil
        state.pending_restore_model_fallback = nil
        state.pending_restore_model_unavailable = nil
        state.pending_restore_display = nil
        state.pending_restore_context_window = nil
        state.pending_restore_blocked = nil
        report(failure_reason or "compaction aborted before /compact")
      end
    end
    local function finish_failed_restore(reason)
      report((failure_reason and (failure_reason .. "; ") or "") .. tostring(reason))
    end
    local function start_verification()
      watch({
        { id = "verified", match = function()
          local current = remuda._butler_telemetry_for(agent)
          local used = tonumber(current.context_used)
          return used and ctx_before and used < ctx_before
            and (agent.kind ~= "claude" or (compaction_family(current.model) == prior
              and (not prior_window or tonumber(current.context_window) == prior_window)))
        end, action = function()
          if failure_reason then report(failure_reason)
          else
            state.compaction_in_progress = false
            state.pending_restore_model = nil
            state.pending_restore_model_fallback = nil
            state.pending_restore_model_unavailable = nil
            state.pending_restore_display = nil
            state.pending_restore_context_window = nil
            state.pending_restore_notice_sent = nil
            state.pending_restore_mismatch_notice_sent = nil
            state.pending_restore_blocked = nil
            state.restore_retry_in_progress = nil
            state.cooldown_ticks = compaction_config().cooldown_ticks
            if owner_state.compaction_fleet_active == state_key then owner_state.compaction_fleet_active = nil end
            _butler_trace("verified", detail)
          end
        end },
      }, { timeout = config.verification_timeout, on_timeout = function()
        verification_failed = true
        failure_reason = failure_reason or "verification failed: CTX did not drop and model was not restored"
        request_restore(failure_reason)
      end, unknown = is_unknown_dialog,
        on_unknown = function(value)
          register_unknown_dialog(value)
          failure_reason = "unrecognized dialog during verification"
          restore_after_unknown(failure_reason)
        end,
        on_error = function(err)
          verification_failed = true
          failure_reason = "verification error: " .. tostring(err)
          request_restore(failure_reason)
        end }, false)
    end
    verify = start_verification
    local function restore_match(value)
      local current = remuda._butler_telemetry_for(agent) or {}
      return compaction_family(current.model) == prior
        and (not prior_window or tonumber(current.context_window) == prior_window)
    end
    watch_restore = function(ignore_unknown)
      watch({
        { id = "restore-dialog", match = is_switch_dialog, action = function(value)
          answer_switch_dialog(value, function() watch_restore() end)
        end },
        { id = "restore-prior", match = restore_match, action = after_restored },
      }, { timeout = dialog_timeout, unknown = function(value)
          if not is_unknown_dialog(value) then return false end
          return not (ignore_unknown and is_unknown_dialog(ignore_unknown)
            and compaction_model(value) == compaction_model(ignore_unknown))
        end,
        on_unknown = function(value)
          register_unknown_dialog(value)
          restore_after_unknown("unrecognized dialog during restore")
        end,
        on_timeout = function() request_restore("restore confirmation timed out") end,
        on_error = function(err) request_restore("restore confirmation error: " .. tostring(err)) end }, true)
    end
    request_restore = function(reason)
      failure_reason = reason or failure_reason
      local captured, current_screen = pcall(remuda.capture, session_name)
      if not captured or type(current_screen) ~= "string" then
        finish_failed_restore("could not read model status during restore")
        return
      end
      local current_model = compaction_model(current_screen)
      if not prior then
        if current_model and current_model:lower():find(low:lower(), 1, true) then
          state.pending_restore_model_unavailable = true
          state.pending_restore_display = prior_display or "unknown model"
          state.restore_retry_in_progress = nil
          local shown = tostring(state.pending_restore_display):gsub("[%c]", " ")
          report("restore skipped: model family unavailable", true)
          if not state.pending_restore_notice_sent then
            state.pending_restore_notice_sent = true
            pcall(remuda._butler_send, session_name, agent.parent or "butler",
              "compaction left " .. shown .. " on Sonnet; restore needs a known model family")
          end
        else
          state.pending_restore_model_unavailable = nil
          state.pending_restore_display = nil
          report("restore skipped: model family unavailable", true)
        end
        return
      end
      if is_switch_dialog(current_screen) then
        if not compact_sent and (restore_attempt_count or 0) == 0 then
          restore_after_unknown(failure_reason or "aborting before compaction")
          return
        end
        answer_switch_dialog(current_screen, function() watch_restore() end)
        return
      end
      if restore_match(current_screen) then after_restored(); return end
      local current_telemetry = remuda._butler_telemetry_for(agent) or {}
      if prior_window and compaction_family(current_telemetry.model) == prior
        and tonumber(current_telemetry.context_window) ~= prior_window then
        state.pending_restore_model = prior
        state.pending_restore_blocked = true
        if not state.pending_restore_mismatch_notice_sent then
          state.pending_restore_mismatch_notice_sent = true
          pcall(remuda._butler_send, session_name, agent.parent or "butler",
            "compaction restore mismatch for " .. session_name .. ": expected " .. prior
              .. " CTXWIN " .. tostring(prior_window) .. ", got "
              .. tostring(current_telemetry.context_window or "unknown"))
        end
        report("restore confirmation had a different context window", true)
        return
      end
      if current_model and current_model:lower():find(low:lower(), 1, true) then
        if (restore_attempt_count or 0) >= config.restore_attempts then
          finish_failed_restore("prior model restore attempts exhausted while model remains " .. current_model)
          return
        end
        wait_until_output_idle(function(idle_error)
          if idle_error then
            state.pending_restore_model = prior
            state.restore_retry_in_progress = true
            state.cooldown_ticks = 0
            report("restore deferred until the member is unattached and idle", true, true)
            return
          end
          local idle, idle_reason = remuda.butler.is_idle(session_name)
          if not idle then
            if idle_reason == "human attached" or idle_reason == "busy" then
              state.pending_restore_model = prior
              state.restore_retry_in_progress = true
              state.cooldown_ticks = 0
              report("restore deferred until the member is unattached and idle", true, true)
            else report("restore aborted: " .. tostring(idle_reason), true, true) end
            return
          end
          restore_attempt_count = (restore_attempt_count or 0) + 1
          local safe = remuda._butler_compaction_action_guard(session_name)
          if safe then
            if safe == "human attached" then
              state.pending_restore_model = prior
              state.restore_retry_in_progress = true
              state.cooldown_ticks = 0
            end
            report("restore aborted: " .. safe, true, state.pending_restore_model ~= nil)
            return
          end
          state.pending_restore_model = prior
          local sent, err = pcall(remuda.type_text, session_name, "/model " .. prior_command, config.input_settle)
          if not sent then finish_failed_restore("could not request prior model: " .. tostring(err)); return end
          watch_restore(is_unknown_dialog(current_screen) and current_screen or nil)
        end)
        return
      end
      finish_failed_restore("model status is neither prior nor low; restore was not sent")
    end
    restore_after_unknown = function(reason)
      failure_reason = reason or failure_reason
      local safe = remuda._butler_compaction_action_guard(session_name)
      if safe then finish_failed_restore("could not dismiss unknown dialog: " .. safe); return end
      local ok, err = pcall(remuda.key, session_name, "ESC")
      if not ok then finish_failed_restore("could not dismiss unknown dialog: " .. tostring(err)); return end
      local deadline = os.time() + math.max(2, math.ceil(config.idle_wait_timeout))
      local timer
      local finished = false
      local function poll()
        if finished then return end
        local captured, current = pcall(remuda.capture, session_name)
        if not captured or type(current) ~= "string" then
          finished = true
          remuda.cancel(timer)
          finish_failed_restore("could not verify unknown dialog dismissal")
        elseif not is_unknown_dialog(current) and not is_switch_dialog(current) then
          finished = true
          remuda.cancel(timer)
          request_restore(failure_reason)
        elseif os.time() >= deadline then
          finished = true
          remuda.cancel(timer)
          finish_failed_restore("unknown dialog did not close after Escape")
        end
      end
      timer = remuda.schedule({ every = 0.25, run = poll })
      poll()
    end
    local function unknown_dialog(value)
      register_unknown_dialog(value)
      failure_reason = "unrecognized dialog"
      restore_after_unknown(failure_reason)
    end
    local function after_switch()
      local blocked = remuda._butler_compaction_preflight(session_name)
      if blocked then
        failure_reason = "aborted: " .. blocked
        request_restore(failure_reason)
        return
      end
      if agent.kind == "codex" then
        local safe = remuda._butler_compaction_preflight(session_name)
        if safe then request_restore("aborted: " .. safe); return end
        safe = remuda._butler_compaction_action_guard(session_name)
        if safe then request_restore("aborted: " .. safe); return end
        local sent, err = pcall(remuda.type_text, session_name, "/compact", config.input_settle)
        if not sent then report("Codex compact command failed: " .. tostring(err)); return end
        compact_sent = true
        verify()
        return
      end
      local safe = remuda._butler_compaction_preflight(session_name)
      if safe then request_restore("aborted: " .. safe); return end
      safe = remuda._butler_compaction_action_guard(session_name)
      if safe then request_restore("aborted: " .. safe); return end
      local compact_ok, compact_err = pcall(remuda.type_text, session_name, "/compact", config.input_settle)
      if not compact_ok then
        failure_reason = "compact command failed: " .. tostring(compact_err)
        request_restore(failure_reason)
        return
      end
      compact_sent = true
      watch({
        { id = "compact-complete", match = function()
          local current = remuda._butler_telemetry_for(agent)
          local used = tonumber(current.context_used)
          return used and ctx_before and used < ctx_before
        end, action = function() request_restore() end },
      }, { timeout = config.completion_timeout, unknown = is_unknown_dialog,
        on_unknown = function(value)
          register_unknown_dialog(value)
          restore_after_unknown("unrecognized dialog after compaction")
        end,
        on_timeout = function() request_restore("compaction context did not drop") end,
        on_error = function(err) request_restore("compaction completion error: " .. tostring(err)) end }, true)
    end
    if restore_only then
      if not prior then
        request_restore("retrying pending restore")
      else
        local idle = remuda.butler.is_idle(session_name)
        if not idle then
          report("restore deferred until the member is unattached and idle", true, true)
          state.cooldown_ticks = 0
        else
          state.restore_retry_in_progress = true
          request_restore("retrying pending restore")
        end
      end
      return
    end
    if agent.kind == "codex" then
      after_switch()
    else
      local safe = remuda._butler_compaction_preflight(session_name)
      if safe then report("aborted: " .. safe); return end
      safe = remuda._butler_compaction_action_guard(session_name)
      if safe then report("aborted: " .. safe); return end
      state.pending_restore_model = prior
      state.pending_restore_model_unavailable = not prior
      state.pending_restore_display = prior_display
      state.pending_restore_context_window = prior_window
      local sent, send_err = pcall(remuda.type_text, session_name, "/model " .. low, config.input_settle)
      if not sent then request_restore("could not request low model: " .. tostring(send_err)); return end
      watch({
        { id = "switch-confirm", match = is_switch_dialog, action = function(value)
          answer_switch_dialog(value, after_switch)
        end },
        { id = "already-low", match = function(value)
          local model = compaction_model(value)
          return not is_unknown_dialog(value)
            and model and model:lower():find(low:lower(), 1, true) ~= nil
        end, action = function()
          wait_until_output_idle(function(idle_error)
            if idle_error then request_restore("aborted: " .. idle_error)
            else after_switch() end
          end)
        end },
      }, { timeout = dialog_timeout, unknown = is_unknown_dialog,
        on_unknown = unknown_dialog,
        on_timeout = function() request_restore("first model dialog timed out") end,
        on_error = function(err) request_restore("first model dialog error: " .. tostring(err)) end }, true)
    end
    _butler_trace("started", detail .. " model=" .. tostring(prior))
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

function remuda._butler_reconcile()
  local ok, result = pcall(launch_butler)
  if not ok then
    _butler_session_trace("reconcile_error", tostring(result))
    return nil, result
  end
  return result
end
-- Remember an explicit remuda.close call for older cores whose session_exited
-- event carries only the session name.
if not bus.close_wrapper_installed and type(remuda.close) == "function" then
  local close_session = remuda.close
  bus.close_wrapper_installed = true
  bus.close_requested = bus.close_requested or {}
  remuda.close = function(name, ...)
    local tracked = bus.agents[name] ~= nil
    if tracked then bus.close_requested[name] = true end
    local ok, a, b, c = pcall(close_session, name, ...)
    if not ok then
      if tracked then bus.close_requested[name] = nil end
      error(a, 0)
    end
    return a, b, c
  end
end
local function report_update_task_not_relaunched(record, reason)
  if not record or not record.task or record.task == "" then return end
  pcall(remuda._butler_send, "butler", record.parent or "butler",
    "Task for " .. record.name .. " was not delivered because its Codex update ended without a safe relaunch ("
      .. tostring(reason or "update aborted") .. "). Resend it with `remuda butler send "
      .. record.name .. " TASK` when the pane is ready.")
end
function remuda._butler_session_exited(name, info)
  _butler_session_trace("session_exited", name)
  local update_restart = bus.codex_update_relaunches[name]
  local explicitly_closed = bus.close_requested and bus.close_requested[name]
  local reason = type(info) == "table" and info.reason or nil
  local exit_code = type(info) == "table" and tonumber(info.exit_code) or nil
  local saw_success = update_restart and (update_restart.update_complete_seen
    or codex_update_complete(update_restart.last_screen))
  local exited_successfully = update_restart and update_restart.update_pressed
    and reason == "exited" and exit_code == 0
  local closed_by_person = explicitly_closed or reason == "closed"
  if update_restart and not update_restart.expected_close
      and (closed_by_person or not saw_success and not exited_successfully) then
    -- Older cores carry only the name; newer cores report reason and exit code.
    -- A human close always wins, while successful exits can use either signal.
    update_restart.cancelled = true
    bus.codex_update_relaunches[name] = nil
    if bus.codex_update_state.waiting then bus.codex_update_state.waiting[name] = nil end
    if bus.codex_update_state.owner == name then
      bus.codex_update_state.claimed, bus.codex_update_state.owner = false, nil
      bus.codex_update_state.done, bus.codex_update_state.done_version = false, nil
      bus.codex_update_state.aborted_version = update_restart.version
      bus.codex_update_state.waiting, bus.codex_update_state.restart_waiting = {}, {}
    end
    _butler_session_trace("codex_update_exit_unconfirmed", name)
    report_update_task_not_relaunched(update_restart, closed_by_person and "closed by a person" or "update did not report success")
    update_restart = nil
  end
  if update_restart then
    update_restart.relaunched = true
    bus.codex_update_relaunches[name] = nil
    local update_state = bus.codex_update_state
    update_state.done, update_state.claimed = true, false
    update_state.done_version = update_restart.version
    update_state.owner = nil
    update_state.restart_waiting = update_state.restart_waiting or {}
    for member in pairs(update_state.waiting or {}) do update_state.restart_waiting[member] = true end
    update_state.waiting = {}
  end
  -- #29: the mail stays in the inbox; only the pending pane notice goes.
  bus.notices[name], bus.notice_screens[name], bus.pending_tasks[name] = nil, nil, nil
  bus.notice_recoveries[name], bus.task_retry_screens[name], bus.human_activity_screens[name] = nil, nil, nil
  local exited = bus.agents[name]
  if exited and exited.cwd and bus.trusted_launch_dirs then
    bus.trusted_launch_dirs[exited.cwd] = nil
  end
  if exited and name ~= "butler" then
    local ended = bus.identity_ids[exited.id] or exited
    ended.alias, ended.kind = exited.alias or name, exited.kind
    ended.leader_id = exited.parent and bus.agents[exited.parent] and bus.agents[exited.parent].id or ""
    local was_closed = bus.close_requested and bus.close_requested[name]
    if bus.close_requested then bus.close_requested[name] = nil end
    ended.state, ended.reason = "ended", was_closed and "closed" or "exited"
    ended.ended_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    ended.ended_at_estimate = nil
    identity_record(ended)
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
  if update_restart then
    _butler_session_trace("codex_updated_relaunch", name)
    local ok, err = pcall(launch_agent, update_restart.kind, update_restart.name,
      update_restart.cwd, update_restart.model, update_restart.parent, update_restart.task,
      update_restart.identity)
    if not ok then
      _butler_session_trace("codex_updated_relaunch_failed", name .. ": " .. tostring(err))
      pcall(remuda._butler_send, "butler", update_restart.parent or "butler",
        "Codex update completed but " .. name .. " could not be relaunched: " .. tostring(err))
    end
  end
end

function remuda._butler_bootstrap()
  return remuda._butler_reconcile()
end
-- Pre-lifecycle cores load this file directly; lifecycle cores call bootstrap
-- from init.lua only after the command and contribution registries are live.
if remuda._butler_test_mode ~= "lifecycle" and not remuda._butler_state then
  remuda._butler_bootstrap()
end

function remuda._butler_compaction_submit()
  if not butler_name then return false end
  local agent = bus.agents[butler_name] or {}
  local captured, screen = pcall(remuda.capture, butler_name)
  local parsed, decision, text = false, nil, nil
  if captured then
    parsed, decision, text = pcall(remuda._butler_prompt_is_empty, agent.kind or "", screen)
  end
  if not captured or not parsed or not remuda._butler_compaction_submit_matches(decision, text) then
    _butler_trace("submit_skipped", "decision=" .. tostring(decision))
    return false
  end
  local sent, err = pcall(remuda.send, butler_name, "")
  if not sent then
    _butler_trace("submit_error", tostring(err))
    return false
  end
  return true
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
    local synchronous, invoking = nil, true
    remuda.butler.matrix.send({ text = a.text }, function(result)
      if invoking then synchronous = result
      elseif result and result.error then
        remuda.emit("butler-matrix-error", "send", result.error)
        io.stderr:write("butler Matrix send failed: " .. tostring(result.error) .. "\n")
      end
    end)
    invoking = false
    if synchronous and synchronous.error then error(synchronous.error, 0) end
    return "queued"
  end,
}
end
