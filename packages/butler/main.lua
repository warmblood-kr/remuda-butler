-- remuda-butler: runs one Claude Code session, optionally bridged to Matrix.
-- Matrix commands and the MCP reply tool share the Lua async request vocabulary.

-- This is the one service session installed by the package, not an ordinary
-- user-created session. Its stable name is its public control surface:
-- `remuda send butler ...`, installer liveness checks, and restart recovery
-- must never depend on the directory that happened to start the daemon.
local function initial_butler_name()
  return "butler"
end

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
  watch = 300000, warn = 400000, critical = 800000, critical_pct = 90,
  cooldown_ticks = 4, capture_gap = 3, completion_timeout = 45,
  claude_completion_timeout = 180, failure_cooldown_seconds = 600,
  input_settle = 0.15,
}
local COMPACTION_MAIL_DEFER_SECONDS = 600
local function compaction_config()
  local configured = remuda._butler_compaction_config or {}
  local out = {}
  for key, fallback in pairs(DEFAULT_COMPACTION_CONFIG) do
    out[key] = tonumber(configured[key]) or fallback
  end
  return out
end
local function compaction_mail_status(name)
  local agents = (remuda._butler_bus or {}).agents or {}
  local agent = agents[name]
  local mail = remuda._butler_mail
  -- Missing identity/module fails open; a live lookup error fails closed as queued.
  if not (agent and agent.id and type(mail) == "table" and type(mail.unread) == "function") then
    return false, false, agent
  end
  local read, unread = pcall(mail.unread, agent.id)
  if not read then return true, true, agent end
  return (tonumber(unread) or 0) > 0, false, agent
end
local function compaction_has_queued_mail(name)
  local queued = compaction_mail_status(name)
  return queued
end
local function compaction_mail_defers(name, state, level, now)
  local queued, lookup_failed, agent = compaction_mail_status(name)
  if not queued then
    state.mail_deferred_at = nil
    state.mail_defer_alert_sent = nil
    return false, false, false, false, agent
  end
  local deferred_at = tonumber(state.mail_deferred_at)
  if level.level ~= "critical" and not deferred_at then
    state.mail_deferred_at = now
    deferred_at = now
  end
  local expired = deferred_at and now - deferred_at >= COMPACTION_MAIL_DEFER_SECONDS
  if level.level ~= "critical" and not expired then return true, false, true, lookup_failed, agent end
  return false, true, true, lookup_failed, agent
end
local function compaction_mail_alert(name, state, level, queued, lookup_failed, agent)
  if not queued or state.mail_defer_alert_sent then return end
  state.mail_defer_alert_sent = true
  local why = lookup_failed and "mail lookup failed" or "mail remains unread"
  local urgency = level.level == "critical" and "critical context" or "the 10 minute deferral limit"
  pcall(remuda._butler_send, name, (agent and agent.parent) or "butler",
    "Compaction is proceeding with unread Butler mail (" .. why .. ") for " .. tostring(name)
      .. " due to " .. urgency .. "; please read the inbox.")
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
function remuda.butler.is_idle(name, allow_queued_mail)
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
  if (not allow_queued_mail and compaction_has_queued_mail(name))
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
function remuda.butler.compact(name, force)
  if not remuda._butler_compaction_execute then return "compaction procedure unavailable" end
  local result = remuda._butler_compaction_execute(name, force == true)
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
  local now = (remuda._butler_compaction_now or os.time)()
  local defer_mail, allow_queued_mail, queued_mail, mail_lookup_failed, mail_agent =
    compaction_mail_defers(name, current, level, now)
  if defer_mail then
    current.idle_ticks, current.last_idle_capture_at = 0, nil
    return false, "skipped_queued", level.used or "?"
  end
  local idle, reason = remuda.butler.is_idle(name, allow_queued_mail)
  if not idle then
    current.idle_ticks, current.last_idle_capture_at = 0, nil
    local reasons = {
      busy = "skipped_busy", working = "skipped_busy", ["human attached"] = "skipped_attached",
      ["queued work"] = "skipped_queued", ["composer not empty"] = "skipped_composer",
      ["working state unknown"] = "skipped_unknown", ["capture unavailable"] = "skipped_composer",
    }
    return false, reasons[reason] or "skipped_unknown", level.used or "?"
  end
  local config = compaction_config()
  if current.last_idle_capture_at and now - current.last_idle_capture_at < config.capture_gap then
    return false, "skipped_idle", level.used or "?"
  end
  current.last_idle_capture_at = now
  current.idle_ticks = current.idle_ticks + 1
  local required = level.level == "watch" and 2 or 1
  if current.idle_ticks < required then return false, "skipped_idle", level.used or "?" end
  if allow_queued_mail and not dry_run then
    compaction_mail_alert(name, current, level, queued_mail, mail_lookup_failed, mail_agent)
  end
  current.idle_ticks, current.last_idle_capture_at = 0, nil
  current.cooldown_ticks = config.cooldown_ticks
  return true, "sent", level.used or "?"
end

function remuda._butler_compaction_reset_idle(st)
  st.idle_ticks = 0
end

function remuda._butler_compaction_failure_cooldown(state, now, force)
  state.failure_cooldown = nil
  local until_at = tonumber(state.failure_cooldown_until)
  if force or not until_at or until_at <= (tonumber(now) or os.time()) then
    state.failure_cooldown_until = nil
    return false
  end
  return true, until_at
end

function remuda._butler_compaction_action_guard(session_name, allow_queued_mail)
  return remuda._butler_compaction_preflight(session_name, allow_queued_mail)
end

function remuda._butler_compaction_preflight(session_name, allow_queued_mail)
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
  if not allow_queued_mail and compaction_has_queued_mail(session_name) then return "queued mail" end
  local captured, screen = pcall(remuda.capture, session_name)
  if not captured or type(screen) ~= "string" then return "session unavailable" end
  local agent = remuda._butler_bus.agents[session_name] or {}
  local registered = registered_agent_kind(agent.kind)
  if registered and registered.working then
    local checked, working = registered_agent_working(registered, screen)
    if not checked then return "busy state unknown" end
    if working then return "busy" end
  end
  local checked, composer = pcall(remuda._butler_prompt_is_empty, agent.kind or "", screen)
  if not checked or composer ~= "EMPTY" then return "composer not empty" end
  return nil
end

function remuda._butler_compaction_submit_matches(decision, text)
  return decision == "NON-EMPTY" and text == "/compact"
end

local function numbered_option(line)
  local trimmed = line:gsub("^%s+", "")
  local selected = false
  for _, marker in ipairs({ "❯", "›", ">" }) do
    if trimmed:sub(1, #marker) == marker then
      selected = true
      trimmed = trimmed:sub(#marker + 1):gsub("^%s+", "")
      break
    end
  end
  local number, label = trimmed:match("^(%d+)[%.)]%s*(.-)%s*$")
  return number, label, selected
end
local function bottom_screen_lines(screen, limit)
  local lines = {}
  for line in (screen .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    lines[#lines] = nil
  end
  local first = math.max(1, #lines - limit + 1)
  local bottom = {}
  for index = first, #lines do
    bottom[#bottom + 1] = lines[index]
  end
  return bottom
end
local function unknown_dialog_signature(screen)
  if type(screen) ~= "string" then return nil end
  local lines = bottom_screen_lines(screen, 8)
  local top_border, bottom_border, selected_option_line, first_option_line, last_option_line, prompt_line
  for i, line in ipairs(lines) do
    local trimmed = line:gsub("^%s+", "")
    local prompt = trimmed:gsub("%s+$", "")
    local first, last = trimmed:sub(1, 3), trimmed:sub(-3)
    if (first == "╭" or first == "┌" or first == "╔")
      and (last == "╮" or last == "┐" or last == "╗") then top_border = i end
    if (first == "╰" or first == "└" or first == "╚")
      and (last == "╯" or last == "┘" or last == "╝") then bottom_border = i end
    if numbered_option(line) then
      first_option_line = first_option_line or i
      last_option_line = i
      if not selected_option_line
          and (trimmed:sub(1, #"❯") == "❯" or trimmed:sub(1, #"›") == "›") then
        selected_option_line = i
      end
    end
    if prompt == "❯" or prompt == "›" or prompt == ">" then prompt_line = i end
  end
  local first, last
  if top_border and bottom_border and top_border < bottom_border then
    first, last = top_border, bottom_border
  elseif selected_option_line then
    first, last = first_option_line, last_option_line
    if prompt_line and prompt_line > last and prompt_line - last <= 2 then last = prompt_line end
  elseif last_option_line and prompt_line and prompt_line > last_option_line
      and prompt_line - last_option_line <= 2 then
    first, last = first_option_line, prompt_line
  end
  if not first then return nil end
  local matched = {}
  for i = first, last do matched[#matched + 1] = lines[i] end
  return table.concat(matched, "\n")
end
function remuda._butler_compaction_is_unknown_dialog(screen)
  return unknown_dialog_signature(screen) ~= nil
end
function remuda._butler_compaction_sequence(prior_model)
  if type(prior_model) == "string" and prior_model ~= "" and prior_model ~= "?" then
    return { "/model sonnet", "/compact", "/model " .. prior_model }
  end
  return { "/compact" }
end

local function read_claude_settings(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local original = file:read("*a")
  file:close()
  local json = remuda.json
  if not json or type(json.decode) ~= "function" then return nil end
  local ok, settings = pcall(json.decode, original)
  if not ok or type(settings) ~= "table" then return nil end
  return settings
end

function remuda._butler_compaction_verify_settings_model(settings, prior_model)
  if type(settings) ~= "table" then return nil, nil, "unavailable" end
  if settings.model == nil then return nil, nil, "model_missing" end
  return settings.model == prior_model, settings.model, nil
end

function remuda._butler_claude_model_for(agent)
  if type(agent) == "table" and type(agent.model) == "string" and agent.model ~= "" then
    return agent.model
  end
  local config = remuda._butler_compaction_config or {}
  local configured = remuda._butler_claude_default_model
    or os.getenv("REMUDA_BUTLER_CLAUDE_DEFAULT_MODEL") or config.claude_default_model
  if type(configured) == "string" and configured ~= "" then return configured end
  local home_variable = os.getenv("HOME")
  local settings = home_variable and read_claude_settings(home_variable .. "/.claude/settings.json")
  if settings and type(settings.model) == "string" and settings.model ~= "" then return settings.model end
  return "opus"
end

function remuda._butler_compaction_valid_model(model)
  if type(model) ~= "string" then return false end
  if model == "opus" or model == "sonnet" or model == "haiku" then return true end
  local base = model:sub(-4) == "[1m]" and model:sub(1, -5) or model
  return base:match("^claude%-[%w%.%-]+$") ~= nil
end

function remuda._butler_compaction_statusline_model_matches(actual, expected)
  if type(actual) ~= "string" or type(expected) ~= "string" then return false end
  local actual_lower, expected_lower = actual:lower(), expected:lower()
  if actual_lower == expected_lower then return true end
  local family = expected_lower:match("(opus)") or expected_lower:match("(sonnet)")
    or expected_lower:match("(haiku)")
  if family then return actual_lower:find(family, 1, true) ~= nil end
  return actual_lower:find(expected_lower, 1, true) ~= nil
end
local statusline_model_matches = remuda._butler_compaction_statusline_model_matches

local function clear_legacy_restore_state(state)
  for _, key in ipairs({ "pending_restore_model", "pending_restore_model_fallback",
    "pending_restore_model_unavailable", "pending_restore_display",
    "pending_restore_context_window", "pending_restore_notice_sent",
    "pending_restore_mismatch_notice_sent", "pending_restore_blocked",
    "restore_retry_in_progress" }) do state[key] = nil end
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
do
  local lifecycle = remuda._butler_state or remuda._butler_compaction_state or {}
  local members = lifecycle.compaction_members or remuda._butler_compaction_members_state or {}
  for _, member_state in pairs(members) do clear_legacy_restore_state(member_state) end
  lifecycle.compaction_members = members
  remuda._butler_compaction_members_state = members
end

-- Config/data paths, Matrix credential paths and path helpers live in paths.lua.
remuda.exec("butler/paths")
local paths = remuda._butler_paths
local topic_config = paths.topic_config
local data_home = paths.data_home
local butler_session_cwd = paths.butler_session_cwd
local mail_root = paths.mail_root
local file_exists = paths.file_exists
local load_topic_config = paths.load_topic_config
local token_path = paths.token_path
local config_path = paths.config_path
local mcp_config_path = paths.mcp_config_path
local shell_quote = paths.shell_quote
local valid_child_name = paths.valid_child_name
local create_fresh_directory = paths.create_fresh_directory
local directory_is_under = paths.directory_is_under
local json_quote = paths.json_quote
local compaction_restore_path = mail_root and mail_root .. "/compaction-restore.json"

local function read_compaction_restore_record()
  if not compaction_restore_path then return {} end
  local file = io.open(compaction_restore_path, "r")
  if not file then return {} end
  local bytes = file:read("*a")
  file:close()
  local ok, decoded = pcall(remuda.json.decode, bytes)
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  local result = {}
  for session, model in pairs(decoded) do
    if type(session) == "string" and type(model) == "string" and model ~= "" then
      result[session] = model
    end
  end
  return result
end

local compaction_restore_sessions = read_compaction_restore_record()
remuda._butler_compaction_load_restore_record = function()
  compaction_restore_sessions = read_compaction_restore_record()
  remuda._butler_compaction_restore_sessions = compaction_restore_sessions
  return compaction_restore_sessions
end
remuda._butler_compaction_restore_sessions = compaction_restore_sessions

local function compaction_agent_key(agent, session_name)
  local id = type(agent) == "table" and agent.id or nil
  if type(id) == "string" and id ~= "" then return id end
  return session_name
end

local function write_compaction_restore_record(record)
  local ok, encoded = pcall(remuda.json.encode, record)
  if not ok then return nil, encoded end
  local wrote, write_err = remuda.fs.write_atomic(compaction_restore_path, encoded)
  if not wrote then return nil, write_err end
  compaction_restore_sessions = record
  remuda._butler_compaction_restore_sessions = compaction_restore_sessions
  return true
end

local function compaction_restore_for(agent, session_name)
  local key = compaction_agent_key(agent, session_name)
  local model = compaction_restore_sessions[key]
  if model then return model end
  -- #91 stored session names. Preserve those records across the key upgrade,
  -- then migrate them as soon as the matching live agent is known.
  if key ~= session_name and compaction_restore_sessions[session_name] then
    model = compaction_restore_sessions[session_name]
    local next_record = {}
    for name, prior in pairs(compaction_restore_sessions) do
      if name ~= session_name then next_record[name] = prior end
    end
    next_record[key] = model
    write_compaction_restore_record(next_record)
    return model
  end
  return nil
end

local function persist_compaction_restore(session, model)
  if not compaction_restore_path then return nil, "Butler state directory unavailable" end
  local next_record = {}
  for name, prior in pairs(compaction_restore_sessions) do next_record[name] = prior end
  next_record[session] = model
  local made, make_err = pcall(remuda.mkdir, mail_root)
  if not made then return nil, make_err end
  return write_compaction_restore_record(next_record)
end

local function clear_compaction_restore(key, legacy_session)
  if not compaction_restore_path then return nil, "Butler state directory unavailable" end
  local next_record = {}
  for name, prior in pairs(compaction_restore_sessions) do
    if name ~= key and name ~= legacy_session then next_record[name] = prior end
  end
  if next(next_record) == nil then
    local removed, remove_err, remove_errno = os.remove(compaction_restore_path)
    if not removed and remove_errno ~= 2 then return nil, remove_err end
  else
    return write_compaction_restore_record(next_record)
  end
  compaction_restore_sessions = next_record
  remuda._butler_compaction_restore_sessions = compaction_restore_sessions
  return true
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
local status_path = remuda._butler_status_path
  or (config_path and (config_path .. ".status") or (os.tmpname() .. ".status"))
local function status_settings(path)
  local settings_path = path .. ".settings.json"
  local settings = assert(io.open(settings_path, "w"))
  settings:write('{"statusLine":{"type":"command","command":'
    .. json_quote("remuda -s " .. shell_quote(server) .. " --stdin butler statusline " .. shell_quote(path))
    .. '}}')
  settings:close()
  return settings_path
end

local function statusline_tag(value)
  if type(value) ~= "string" or value == "" then return "?" end
  local tag = value:gsub("[^A-Za-z0-9_.-]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  return tag ~= "" and tag or "?"
end

local function statusline_integer(value)
  if type(value) ~= "number" then return "?" end
  local integer = value < 0 and math.ceil(value) or math.floor(value)
  if integer == 0 then return "0" end
  return string.format("%.0f", integer)
end

local function statusline(args, caller)
  local snapshot = {}
  local input = caller and caller.stdin
  if type(input) == "string" then
    local decoded = remuda.json.decode(input)
    if type(decoded) == "table" then snapshot = decoded end
  end

  local window = type(snapshot.context_window) == "table" and snapshot.context_window or {}
  local used = window.total_input_tokens
  if type(used) ~= "number" then
    local current = type(window.current_usage) == "table" and window.current_usage or {}
    local total, count = 0, 0
    for _, key in ipairs({ "input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens" }) do
      local part = current[key]
      if type(part) == "number" then total, count = total + part, count + 1 end
    end
    if count > 0 then used = total end
  end

  local model = type(snapshot.model) == "table" and snapshot.model or {}
  local model_name = model.display_name
  if not model_name or model_name == "" then model_name = model.id end
  local line = string.format("MODEL:%s CTX:%s CTXWIN:%s CTXPCT:%s",
    statusline_tag(model_name), statusline_integer(used),
    statusline_integer(window.context_window_size), statusline_integer(window.used_percentage))

  local path = args[2]
  local drive_rooted = type(path) == "string" and path:match("^%a:")
    and (path:sub(3, 3) == "/" or path:sub(3, 3) == "\\")
  local absolute = type(path) == "string" and (
    path:sub(1, 1) == "/" or path:sub(1, 2) == "\\\\" or drive_rooted
  )
  if absolute and path:match("%.status$") then
    pcall(remuda.fs.write_atomic, path, line .. "\n")
  end
  return line
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
-- Loaded before identity_record so agents.jsonl shares mail.lua's append.
remuda._butler_mail_config = { bus = bus, root = mail_root, json_quote = json_quote }
remuda.exec("butler/mail")
-- ULIDs, identity records and caller identity live in identity.lua.
remuda._butler_identity_config = { bus = bus, current_agent = current_agent, data_home = data_home,
  shell_quote = shell_quote, json_quote = json_quote }
remuda.exec("butler/identity")
local identity = remuda._butler_identity
local identity_path = identity.identity_path
local identity_record = identity.identity_record
local json_field = identity.json_field
local register_identity = identity.register_identity
local resolve = identity.resolve
local mail_address = identity.mail_address
local mail_id = identity.mail_id
local next_token = identity.next_token
local caller_name = identity.caller_name
local caller_agent = identity.caller_agent
local caller_leader = identity.caller_leader
local mail = assert(remuda._butler_mail)
local mailbox = mail.mailbox
local queue_message = mail.queue
local migrate_legacy_mail = mail.migrate_legacy
remuda._butler_migrate_legacy_mail = migrate_legacy_mail
local delivery_events = type(remuda.emit_until_success) == "function"
local delivery_notice_results = {}
local function delivery_notice_key(message_id, alias)
  return tostring(message_id) .. "\0" .. tostring(alias)
end
local function take_delivery_notice_result(message, alias)
  local key = delivery_notice_key(message.id, alias)
  local result = delivery_notice_results[key]
  delivery_notice_results[key] = nil
  return result
end
local function notify_mail_delivery(message, delivered, recipient_alias, what)
  local result = {}
  local recipient_ref = recipient_alias or (type(message.to) == "table" and message.to.alias or message.to)
  local recipient_ok, _, recipient = pcall(mail_id, recipient_ref, false)
  result.recipient_live = recipient_ok
  if recipient_ok then
    local notice
    if what then
      notice = "Butler message " .. delivered.id .. " " .. what
    else
      local sender = message.from.alias or message.from.session or "outside"
      if message.kind == "forward" then
        notice = "Butler message " .. delivered.id .. " forwarded by " .. sender
      elseif message.in_reply_to then
        notice = "Butler message " .. delivered.id .. " (reply) from " .. sender
      else
        sender = message.matrix and message.matrix.sender or message.from.session or sender
        notice = "Butler message " .. delivered.id .. " from " .. sender
      end
    end
    notice = notice .. " arrived. Read it: remuda butler inbox"
    local notify_ok, notified, notify_error =
      pcall(remuda._butler_notify, recipient.alias, notice, delivered.id)
    if notify_ok then
      result.delivered, result.error = notified, notify_error
    else
      result.error = notified
      _butler_session_trace("notice_delivery_error", recipient.alias .. " " .. tostring(notified))
    end
  end
  if message.from.host ~= "matrix" then
    delivery_notice_results[delivery_notice_key(delivered.id, recipient_ok and recipient.alias or recipient_ref)] = result
  end
  return delivered
end
local function inbox_delivery(message)
  local delivered, why
  if message.kind == "matrix_reply" then
    local queued, queue_error = remuda.butler.matrix.mail_reply({
      mail_id = message.in_reply_to, reply_mail_id = message.reply_id,
      text = message.text, route = message.matrix_route,
    })
    if not queued then
      message.delivery_error = queue_error
      return nil
    end
    return { id = message.reply_id, matrix_reply = true, source_mail_id = message.in_reply_to }
  elseif message.kind == "forward" then
    delivered, why = mail.forward_delivery(message)
  else
    delivered, why = queue_message(message.from, message.to, message.text, message.subject,
      message.in_reply_to, message.references, message.matrix)
  end
  if not delivered then
    message.delivery_error = why
    return nil
  end
  return notify_mail_delivery(message, delivered)
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
  if message.kind == "matrix_reply" then
    error("Matrix reply delivery requires the Butler delivery event hook", 0)
  end
  local delivered, why
  if message.kind == "forward" then
    delivered, why = mail.forward_delivery(message)
  else
    delivered, why = queue_message(message.from, message.to, message.text, message.subject,
      message.in_reply_to, message.references, message.matrix)
  end
  if not delivered then error(why or "no Butler channel installed (try remuda-butler-inbox)", 0) end
  return notify_mail_delivery(message, delivered)
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
-- The launch chooser, member guidance and startup modals live in agents_launch.lua.
local startup_action_safe
remuda._butler_chooser_config = { bus = bus, call_callback = call_callback, numbered_option = numbered_option,
  bottom_screen_lines = bottom_screen_lines, file_exists = file_exists, contributions = contributions,
  startup_action_safe = function(...) return startup_action_safe(...) end }
remuda.exec("butler/agents_launch")
local chooser = remuda._butler_chooser
local PROMPT_DELIVERY = chooser.PROMPT_DELIVERY
local build_agent_argv = chooser.build_agent_argv
local one_line = chooser.one_line
local trust_modal_state = chooser.trust_modal_state
local choose = chooser.choose
local configured_agent_order = chooser.configured_agent_order
local readiness_chain_budget = chooser.readiness_chain_budget
local setup_telemetry = chooser.setup_telemetry
local team_member_guidance = chooser.team_member_guidance
local team_member_prompt = chooser.team_member_prompt
local write_agent_guidance = chooser.write_agent_guidance
local option_number = chooser.option_number
local codex_update_version = chooser.codex_update_version
local skip_option_number = chooser.skip_option_number
local startup_modal_timeout_seconds = chooser.startup_modal_timeout_seconds
local startup_modal = chooser.startup_modal
local known_startup_modal = chooser.known_startup_modal
local codex_update_complete = chooser.codex_update_complete
local capture_update_evidence = chooser.capture_update_evidence
-- Member launch and topic creation live in launch.lua.
remuda._butler_launch_config = { bus = bus,
  topic_config = topic_config,
  data_home = data_home,
  load_topic_config = load_topic_config,
  shell_quote = shell_quote,
  valid_child_name = valid_child_name,
  create_fresh_directory = create_fresh_directory,
  directory_is_under = directory_is_under,
  identity_record = identity_record,
  register_identity = register_identity,
  resolve = resolve,
  mail_address = mail_address,
  next_token = next_token,
  mailbox = mailbox,
  queue_message = queue_message,
  migrate_legacy_mail = migrate_legacy_mail,
  startup_action_safe = function(...) return startup_action_safe(...) end }
remuda.exec("butler/launch")
local launch_agent = remuda._butler_launch_impl.launch_agent
-- Mail notice policy, recovery and delivery live in notice.lua.
remuda._butler_notice_config = { bus = bus,
  resolve = resolve,
  mail_address = mail_address,
  mail_id = mail_id,
  mail = mail,
  take_delivery_notice_result = take_delivery_notice_result,
  notify_mail_delivery = notify_mail_delivery,
  deliver_message = deliver_message,
}
remuda.exec("butler/notice")
-- The launch configs above call main.lua's startup_action_safe late; set it here.
startup_action_safe = remuda._butler_notice.startup_action_safe
local notice_recovery_error = remuda._butler_notice.notice_recovery_error
-- Reply and forward live in mail.lua; this adds the caller's identity and the
-- terminal notice. A recipient that has ended still gets the mail, unnotified.
local function sender_address(from)
  if from == OPERATOR then return mail_address(OPERATOR) end
  if from == "outside" then error("unknown caller: run from a Butler session", 0) end
  return mail_address(resolve(from))
end
local function notify_queued(message, alias, what)
  local notice = take_delivery_notice_result(message, alias)
  if not notice then
    notify_mail_delivery(message, message, alias, what)
    notice = take_delivery_notice_result(message, alias)
  end
  if notice and notice.delivered then return "queued " .. message.id .. " and notified " .. alias end
  if notice and not notice.recipient_live then return "queued " .. message.id .. " for " .. alias .. "; it is not live, so no notice" end
  return "queued " .. message.id .. " for " .. alias .. "; notice deferred"
    .. (notice and notice.error and (": " .. tostring(notice.error)) or " until its pane is free")
end
function remuda._butler_reply(from, message_id, text)
  local sender = sender_address(from)
  local message, err, recipient = mail.reply(sender, message_id, text, from == OPERATOR, deliver_message)
  if not message then error(err, 0) end
  if message.matrix_reply then return "queued Matrix reply " .. message.id .. " for " .. message.source_mail_id end
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
local butler_attempts = remuda._butler_attempts or {}
remuda._butler_attempts = butler_attempts
-- The household walk, roster and session hooks live in sessions.lua.
remuda._butler_sessions_config = { bus = bus, mail = mail, identity_path = identity_path, json_field = json_field }
remuda.exec("butler/sessions")
local registry_list = remuda._butler_sessions_impl.registry_list

-- CLI verbs and the argv parser live in commands.lua.
remuda._butler_commands_config = { current_agent = current_agent, OPERATOR = OPERATOR,
  contributions = contributions, registry_list = registry_list, statusline = statusline,
}
remuda.exec("butler/commands")

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
- For long bodies, use `cat <<'EOF' | remuda butler send MEMBER -` or `--file "$PWD/path"`;
  `send-to-leader` and `reply MESSAGE_ID` accept those forms too. The limit is 64 KiB.

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
      local state_key = compaction_agent_key(agent, session_name)
      local state = members[state_key] or {}
      if dry_run then
        local snapshot = {}
        for key, value in pairs(state) do snapshot[key] = value end
        state = snapshot
      end
      if not dry_run then
        members[state_key] = state
        remuda._butler_compaction_members_state = members
      end
      if agent.kind == "claude" then clear_legacy_restore_state(state) end
      if agent.kind == "claude" and not state.restore_pending then
        local persisted = compaction_restore_for(agent, session_name)
        if persisted then
          state.restore_pending = persisted
          state.restore_pending_attempts = 0
          state.restore_pending_exhausted = nil
        end
      end
      local cooling = remuda._butler_compaction_failure_cooldown(
        state, (remuda._butler_compaction_now or os.time)())
      if state.compaction_in_progress then
        results[#results + 1] = session_name .. ":compaction_in_progress"
      elseif owner_state.compaction_fleet_active and owner_state.compaction_fleet_active ~= state_key then
        results[#results + 1] = session_name .. ":fleet_busy"
      elseif state.restore_pending and not dry_run then
        results[#results + 1] = remuda._butler_compaction_execute(session_name)
      elseif cooling then
        results[#results + 1] = session_name .. ":skipped_cooldown"
      else
        local should_send, event, ctx = remuda.butler.compaction_policy(session_name, state, dry_run)
        if dry_run then
          local sequence = agent.kind == "claude"
            and remuda._butler_compaction_sequence((remuda._butler_telemetry_for(agent) or {}).model or agent.model)
            or { "/compact" }
          results[#results + 1] = table.concat({ session_name, "decision=" .. tostring(event),
            "ctx=" .. tostring(ctx), "idle_captures=" .. tostring(state.idle_ticks or 0),
            "keys=" .. table.concat(sequence, " -> ") .. " -> RET" }, "; ")
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

function remuda._butler_compaction_execute(session_name, force)
  if not session_name then return "no session" end
  if not remuda._butler_compaction_has_session(session_name) then
    return "unknown session: " .. tostring(session_name)
  end
  local owner_state = remuda._butler_state or remuda._butler_compaction_state or {}
  owner_state.compaction_members = owner_state.compaction_members or remuda._butler_compaction_members_state or {}
  remuda._butler_compaction_members_state = owner_state.compaction_members
  local agent = remuda._butler_bus.agents[session_name] or {}
  if agent.kind ~= "claude" and agent.kind ~= "codex" then
    local message = "compaction skipped: unsupported agent kind " .. tostring(agent.kind)
    pcall(remuda._butler_send, session_name, agent.parent or "butler", message)
    return "skipped_unsupported_kind"
  end
  local state_key = compaction_agent_key(agent, session_name)
  local state = owner_state.compaction_members[state_key] or {}
  owner_state.compaction_members[state_key] = state
  if agent.kind == "claude" then clear_legacy_restore_state(state) end
  if agent.kind == "claude" and not state.restore_pending then
    local persisted = compaction_restore_for(agent, session_name)
    if persisted then
      state.restore_pending = persisted
      state.restore_pending_attempts = 0
      state.restore_pending_exhausted = nil
    end
  end
  local restore_pending = agent.kind == "claude" and type(state.restore_pending) == "string"
    and state.restore_pending ~= "" and state.restore_pending or nil
  if state.compaction_in_progress then return "compaction_in_progress" end
  if owner_state.compaction_fleet_active and owner_state.compaction_fleet_active ~= state_key then return "fleet_busy" end
  local now = (remuda._butler_compaction_now or os.time)()
  if not restore_pending and remuda._butler_compaction_failure_cooldown(state, now, force == true) then
    return "skipped_cooldown"
  end
  local level = remuda.butler.ctx_level(session_name)
  local allow_queued_mail = false
  local queued_mail, mail_lookup_failed, mail_agent
  if not restore_pending then
    local defer_mail
    defer_mail, allow_queued_mail, queued_mail, mail_lookup_failed, mail_agent =
      compaction_mail_defers(session_name, state, level, now)
    if defer_mail then return "skipped_queued" end
  end
  local blocked = not restore_pending and remuda._butler_compaction_preflight(session_name, allow_queued_mail)
  if blocked then
    local statuses = {
      busy = "skipped_busy", ["busy state unknown"] = "skipped_busy",
      ["human attached"] = "skipped_attached", ["composer not empty"] = "skipped_composer",
      ["queued mail"] = "skipped_queued", ["session unavailable"] = "skipped_unknown",
    }
    return statuses[blocked] or "skipped_unknown"
  end
  local action_blocked = remuda._butler_compaction_action_guard(session_name, allow_queued_mail)
  if action_blocked then
    if restore_pending then return "restore_pending" end
    if action_blocked == "human attached" then return "skipped_attached" end
    if action_blocked == "busy" then return "skipped_busy" end
    return "skipped_unknown"
  end
  if type(remuda.expect) ~= "function" then return "compaction disabled: core lacks remuda.expect" end
  if allow_queued_mail then
    compaction_mail_alert(session_name, state, level, queued_mail, mail_lookup_failed, mail_agent)
  end

  local config = compaction_config()
  local detail = "ctx=" .. tostring(level.used or "?")
  local ctx_before = tonumber(level.used)
  local prior_model, settings_path
  if agent.kind == "claude" then
    prior_model = restore_pending or remuda._butler_claude_model_for(agent)
    settings_path = (os.getenv("HOME") or "") .. "/.claude/settings.json"
  end
  local function release_lock()
    state.compaction_in_progress = false
    if owner_state.compaction_fleet_active == state_key then owner_state.compaction_fleet_active = nil end
  end
  local function fail(reason)
    release_lock()
    if state.restore_pending_attempt_active then
      state.restore_pending_attempt_active = nil
      if (tonumber(state.restore_pending_attempts) or 0) >= 3 then
        state.restore_pending_exhausted = true
        state.failure_cooldown_until = (remuda._butler_compaction_now or os.time)()
          + config.failure_cooldown_seconds
        state.cooldown_ticks = 0
        if not state.restore_pending_failure_notified then
          state.restore_pending_failure_notified = true
          pcall(remuda._butler_send, session_name, agent.parent or "butler",
            "model restore failed; member may still be on sonnet")
        end
      else
        state.failure_cooldown_until = nil
      end
      _butler_trace("restore_failed", detail .. " attempt=" .. tostring(state.restore_pending_attempts)
        .. " reason=" .. tostring(reason))
      return
    end
    state.failure_cooldown_until = (remuda._butler_compaction_now or os.time)()
      + config.failure_cooldown_seconds
    state.cooldown_ticks = 0
    _butler_trace("error", detail .. " reason=" .. tostring(reason))
    pcall(remuda._butler_send, session_name, agent.parent or "butler",
      "Compaction failed: " .. tostring(reason))
  end
  local function finish_success(event)
    if agent.kind == "claude" then
      local settings = read_claude_settings(settings_path)
      local matches, actual, status = remuda._butler_compaction_verify_settings_model(settings, prior_model)
      if status then
        _butler_trace("settings_verify_skipped", detail .. " reason=" .. status)
      elseif not matches then
        _butler_trace("settings_model_mismatch", detail .. " model=" .. tostring(actual)
          .. " expected=" .. tostring(prior_model))
        if not state.settings_model_alert_sent then
          state.settings_model_alert_sent = true
          pcall(remuda._butler_send, session_name, agent.parent or "butler",
            "settings.json model is " .. tostring(actual) .. ", expected " .. tostring(prior_model))
        end
        -- The prior model is not back yet: keep the durable record so the
        -- next tick types /model again (bounded by restore attempts).
        state.restore_pending = prior_model
        state.restore_pending_attempt_active = true
        fail("settings.json model is " .. tostring(actual))
        return
      else
        _butler_trace("settings_model_verified", detail .. " model=" .. tostring(actual))
      end
    end
    release_lock()
    state.failure_cooldown_until = nil
    state.cooldown_ticks = config.cooldown_ticks
    state.compaction_still_running_notice_sent = nil
    state.restore_pending = nil
    state.restore_pending_attempts = nil
    state.restore_pending_attempt_active = nil
    state.restore_pending_failure_notified = nil
    state.restore_pending_exhausted = nil
    state.settings_model_alert_sent = nil
    clear_legacy_restore_state(state)
    local cleared, clear_err = clear_compaction_restore(compaction_agent_key(agent, session_name), session_name)
    if not cleared then
      _butler_trace("restore_record_clear_failed", detail .. " reason=" .. tostring(clear_err))
      pcall(remuda._butler_send, session_name, agent.parent or "butler",
        "model was restored, but its recovery record could not be cleared")
    end
    _butler_trace(event or "verified", detail)
  end
  local function pane_busy()
    local found, session = pcall(remuda.session, session_name)
    if not found or not session then return nil end
    if session.is_busy ~= false then return true end
    local captured, screen = pcall(remuda.capture, session_name)
    if not captured or type(screen) ~= "string" then return nil end
    local registered = registered_agent_kind(agent.kind)
    if registered and registered.working then
      local checked, working = registered_agent_working(registered, screen)
      if not checked then return nil end
      return working == true
    end
    return false
  end
  local function send_command(command)
    local sent, send_err = pcall(remuda.type_text, session_name, command, config.input_settle)
    if not sent then fail("compaction command failed: " .. tostring(send_err)); return false end
    return true
  end
  local function wait_for(id, matcher, action, timeout, on_timeout)
    local confirmation_sent = false
    local handle
    local action_started = false
    local function run_action(screen)
      if action_started then return end
      action_started = true
      if handle and handle.cancel then handle:cancel() end
      return action(screen)
    end
    local branches = { { id = id, match = matcher, action = run_action } }
    local model_confirm_state = { signature = nil, captures = 0, polls = 0, started_at = nil }
    local unknown_state = { signature = nil, captures = 0, polls = 0, started_at = nil }
    -- Each expect tick (native clock, about 1 s, with or without output)
    -- captures once and counts it here; never sleep, it blocks the image.
    -- The poll cap and deadline bound the wait; expiry fails closed.
    local stable_captures, stable_unknown_captures, stable_poll_cap, stable_timeout = 3, 10, 50, 5
    local function stable_screen(state, signature, required_captures)
      if not signature then
        state.signature, state.captures, state.polls, state.started_at = nil, 0, 0, nil
        return false
      end
      local now = os.time()
      state.started_at = state.started_at or now
      if state.signature ~= signature then
        state.signature, state.captures = signature, 1
      else
        state.captures = state.captures + 1
      end
      state.polls = state.polls + 1
      return state.captures >= (required_captures or stable_captures)
        and state.polls <= stable_poll_cap
        and now - state.started_at <= stable_timeout
    end
    local function stable_wait_expired(state)
      return state.started_at ~= nil
        and (state.polls >= stable_poll_cap or os.time() - state.started_at >= stable_timeout)
    end
    local function model_confirm_signature(screen)
      if type(screen) ~= "string" then return nil end
      local lines = bottom_screen_lines(screen, 32)
      for index = 1, #lines - 1 do
        if index > #lines - 8
            and lines[index]:find("❯%s*1%.%s+Yes")
            and lines[index + 1]:find("%d%.%s+No, go back") then
          for title_row = math.max(1, index - 24), index - 1 do
            if lines[title_row]:find("Switch model?", 1, true) then
              local dialog = {}
              for row = title_row, index + 1 do dialog[#dialog + 1] = lines[row] end
              return table.concat(dialog, "\n")
            end
          end
        end
      end
      return nil
    end
    local function model_confirm_options_visible(screen)
      if type(screen) ~= "string" then return false end
      local lines = bottom_screen_lines(screen, 32)
      for index = 1, #lines - 1 do
        if index > #lines - 24
            and lines[index]:find("❯%s*1%.%s+Yes")
            and lines[index + 1]:find("%d%.%s+No, go back") then
          return true
        end
      end
      return false
    end
    local function settle_model_confirm(screen)
      local signature = model_confirm_signature(screen)
      if signature then return stable_screen(model_confirm_state, signature) end
      if not model_confirm_options_visible(screen) then
        stable_screen(model_confirm_state, nil)
        return false
      end
      -- Options without the title yet (half-painted): wait, bounded by expiry.
      model_confirm_state.started_at = model_confirm_state.started_at or os.time()
      model_confirm_state.polls = model_confirm_state.polls + 1
      return false
    end
    if agent.kind == "claude" and (id == "model-sonnet" or id == "model-restored") then
      table.insert(branches, {
        id = "claude-model-confirm",
        match = settle_model_confirm,
        action = function()
          if not confirmation_sent then
            local pressed, press_err = pcall(remuda.key, session_name, "RET")
            if not pressed then error(press_err, 0) end
            confirmation_sent = true
            run_action()
          end
        end,
        continue = true,
      })
    end
    local ok, started_handle = pcall(remuda.expect, session_name, branches,
      -- This prompt is accepted only during the Claude model-switch watchers.
      -- All other unknown screens continue through the existing fail path.
      { timeout = timeout, interval = 0.1,
      unknown = function(screen)
        local model_watcher = agent.kind == "claude" and (id == "model-sonnet" or id == "model-restored")
        local model_signature = model_watcher and model_confirm_signature(screen)
        if model_signature then
          stable_screen(unknown_state, nil)
          return stable_wait_expired(model_confirm_state)
        end
        stable_screen(model_confirm_state, nil)
        local unknown_signature = unknown_dialog_signature(screen)
        return stable_screen(unknown_state, unknown_signature, stable_unknown_captures)
          or stable_wait_expired(unknown_state)
      end,
      on_unknown = function()
        if agent.kind == "claude" and (id == "model-sonnet" or id == "compact-complete") then
          state.restore_pending = prior_model
          state.restore_pending_attempts = 0
          state.restore_pending_attempt_active = nil
          state.restore_pending_failure_notified = nil
        end
        fail("unrecognized dialog during " .. id)
      end,
      on_timeout = function(screen, handle)
        local model_watcher = agent.kind == "claude" and (id == "model-sonnet" or id == "model-restored")
        if unknown_state.started_at or (model_watcher and model_confirm_state.started_at) then
          if agent.kind == "claude" and (id == "model-sonnet" or id == "compact-complete") then
            state.restore_pending = prior_model
            state.restore_pending_attempts = 0
            state.restore_pending_attempt_active = nil
            state.restore_pending_failure_notified = nil
          end
          fail("unrecognized dialog during " .. id)
        elseif on_timeout then
          on_timeout(screen, handle)
        else
          fail("timed out waiting for " .. id)
        end
      end,
      on_error = function(err) fail("compaction watcher error: " .. tostring(err)) end }, false)
    if not ok then fail("could not start " .. id .. " watcher: " .. tostring(started_handle)) end
    handle = started_handle
    return ok
  end
  local completion_timeout = agent.kind == "claude"
    and config.claude_completion_timeout or config.completion_timeout
  local function restore_model(event, after_restore)
    if not remuda._butler_compaction_valid_model(prior_model) then
      if not state.restore_pending_invalid_notified then
        state.restore_pending_invalid_notified = true
        pcall(remuda._butler_send, session_name, agent.parent or "butler",
          "Compaction stopped: unsafe Claude model value; no model command was sent")
      end
      state.restore_pending_attempt_active = nil
      state.restore_pending_exhausted = true
      state.failure_cooldown_until = (remuda._butler_compaction_now or os.time)()
        + config.failure_cooldown_seconds
      state.cooldown_ticks = 0
      release_lock()
      _butler_trace("unsafe_model", detail)
      return false
    end
    if not send_command("/model " .. prior_model) then return end
    wait_for("model-restored", function()
      local current = remuda._butler_telemetry_for(agent) or {}
      return statusline_model_matches(current.model, prior_model)
    end, function()
      if after_restore then after_restore() else finish_success(event or "verified") end
    end, completion_timeout)
  end
  local function monitor_until_idle()
    local warned = pcall(remuda._butler_send, session_name, agent.parent or "butler",
      "Compaction is still running; the fleet lock remains held until this session is idle.")
    state.compaction_still_running_notice_sent = warned and true or false
    local monitor_ok, monitor = pcall(remuda.schedule, { every = 1, run = function()
      local found, session = pcall(remuda.session, session_name)
      if not found or not session then
        if state.compaction_monitor then remuda.cancel(state.compaction_monitor) end
        state.compaction_monitor = nil
        fail("session unavailable after compaction timeout")
      elseif pane_busy() == false then
        if state.compaction_monitor then remuda.cancel(state.compaction_monitor) end
        state.compaction_monitor = nil
        state.compaction_still_running_notice_sent = nil
        if agent.kind == "claude" then restore_model("completed_after_timeout")
        else finish_success("completed_after_timeout") end
      end
    end })
    if monitor_ok then state.compaction_monitor = monitor end
  end

  local function compact()
    if not send_command("/compact") then return end
    wait_for("compact-complete", function()
      local current = remuda._butler_telemetry_for(agent) or {}
      local used = tonumber(current.context_used)
      return used and ctx_before and used < ctx_before
    end, function()
      if agent.kind == "claude" then restore_model("verified")
      else finish_success("verified") end
    end, completion_timeout, function()
      if agent.kind == "claude" then
        if pane_busy() ~= false then
          monitor_until_idle()
        else
          restore_model(nil, function() fail("compaction context did not drop") end)
        end
      else
        fail("compaction context did not drop")
      end
    end)
  end
  if restore_pending then
    if state.restore_pending_exhausted then
      local cooling = remuda._butler_compaction_failure_cooldown(
        state, (remuda._butler_compaction_now or os.time)())
      if cooling then return "restore_pending" end
      state.restore_pending_attempts = 0
      state.restore_pending_exhausted = nil
      state.restore_pending_failure_notified = nil
      state.restore_pending_invalid_notified = nil
    end
    local captured, screen = pcall(remuda.capture, session_name)
    if pane_busy() ~= false or not captured or type(screen) ~= "string"
        or remuda._butler_compaction_is_unknown_dialog(screen) then
      return "restore_pending"
    end
    state.compaction_in_progress = true
    state.failure_cooldown_until = nil
    owner_state.compaction_fleet_active = state_key
    state.restore_pending_attempts = (tonumber(state.restore_pending_attempts) or 0) + 1
    state.restore_pending_attempt_active = true
    restore_model("restored_after_dialog")
    return "restoring_model"
  end
  state.compaction_in_progress = true
  state.failure_cooldown_until = nil
  owner_state.compaction_fleet_active = state_key
  _butler_trace("sent", detail)
  if agent.kind == "claude" then
    if not remuda._butler_compaction_valid_model(prior_model) then
      state.compaction_in_progress = false
      owner_state.compaction_fleet_active = nil
      state.failure_cooldown_until = (remuda._butler_compaction_now or os.time)()
        + config.failure_cooldown_seconds
      state.cooldown_ticks = 0
      pcall(remuda._butler_send, session_name, agent.parent or "butler",
        "Compaction stopped: unsafe Claude model value; no model command was sent")
      _butler_trace("unsafe_model", detail)
      return "failed"
    end
    state.restore_pending = prior_model
    state.restore_pending_attempts = 0
    state.restore_pending_exhausted = nil
    state.restore_pending_invalid_notified = nil
    local persisted, persist_err = persist_compaction_restore(
      compaction_agent_key(agent, session_name), prior_model)
    if not persisted then
      state.restore_pending = nil
      state.restore_pending_attempts = nil
      state.restore_pending_attempt_active = nil
      state.compaction_in_progress = false
      owner_state.compaction_fleet_active = nil
      state.failure_cooldown_until = (remuda._butler_compaction_now or os.time)()
        + config.failure_cooldown_seconds
      state.cooldown_ticks = 0
      pcall(remuda._butler_send, session_name, agent.parent or "butler",
        "Compaction stopped: could not persist model restore state: " .. tostring(persist_err))
      _butler_trace("restore_record_write_failed", detail .. " reason=" .. tostring(persist_err))
      return "failed"
    end
    if not send_command("/model sonnet") then return "failed" end
    wait_for("model-sonnet", function()
      local current = remuda._butler_telemetry_for(agent) or {}
      return type(current.model) == "string" and current.model:lower():find("sonnet", 1, true) ~= nil
    end, compact, completion_timeout)
  else
    compact()
  end
  return "started"
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
local function stale_session_exit(name, instance_id)
  if type(instance_id) ~= "string" or instance_id == "" then return false end
  local ok, sessions = pcall(remuda.ls)
  if not ok or type(sessions) ~= "table" then return false end
  for _, session in ipairs(sessions) do
    if session.name == name and session.alive
        and type(session.instance_id) == "string" then
      return session.instance_id ~= instance_id
    end
  end
  return false
end

function remuda._butler_session_exited(name, info)
  local instance_id = type(info) == "table" and info.instance_id or nil
  if stale_session_exit(name, instance_id) then
    _butler_session_trace("stale_session_exit", name .. " instance=" .. instance_id)
    return
  end
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
