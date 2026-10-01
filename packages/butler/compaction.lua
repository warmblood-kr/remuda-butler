-- Compaction policy: thresholds, the mail gate, the public butler.ctx_level/
-- is_idle/compact/compaction_policy units, the _butler_compaction_* helpers and
-- the dialog/model helpers. main.lua passes its locals in (the mail.lua
-- pattern) and binds the helpers it still uses back.
local config = assert(remuda._butler_compaction_module_config)
local system = assert(remuda._butler_system)
local registered_agent_kind = assert(config.registered_agent_kind)
local registered_agent_working = assert(config.registered_agent_working)
local DEFAULT_COMPACTION_CONFIG = {
  watch = 300000, warn = 400000, critical = 800000, critical_pct = 90,
  cooldown_ticks = 4, capture_gap = 3, completion_timeout = 180,
  claude_completion_timeout = 180, failure_cooldown_seconds = 600, monitor_ceiling_seconds = 1800,
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
  local home_variable = system.home()
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

remuda._butler_compaction = {
  compaction_config = compaction_config,
  compaction_mail_defers = compaction_mail_defers,
  compaction_mail_alert = compaction_mail_alert,
  numbered_option = numbered_option,
  bottom_screen_lines = bottom_screen_lines,
  unknown_dialog_signature = unknown_dialog_signature,
  read_claude_settings = read_claude_settings,
  statusline_model_matches = statusline_model_matches,
  clear_legacy_restore_state = clear_legacy_restore_state,
}
