-- The compaction run: the restore record (models to restore after a
-- compaction), the schedule enable call, the tick and the execute procedure.
-- main.lua passes its locals in (the mail.lua pattern); the lifecycle
-- schedule itself stays declared in init.lua.
local config = assert(remuda._butler_compaction_run_config)
local system = assert(remuda._butler_system)
local mail_root = config.mail_root
local _butler_trace = assert(config._butler_trace)
local registered_agent_kind = assert(config.registered_agent_kind)
local registered_agent_working = assert(config.registered_agent_working)
local compaction_config = assert(config.compaction_config)
local compaction_mail_defers = assert(config.compaction_mail_defers)
local compaction_mail_alert = assert(config.compaction_mail_alert)
local bottom_screen_lines = assert(config.bottom_screen_lines)
local unknown_dialog_signature = assert(config.unknown_dialog_signature)
local read_claude_settings = assert(config.read_claude_settings)
local statusline_model_matches = assert(config.statusline_model_matches)
local clear_legacy_restore_state = assert(config.clear_legacy_restore_state)
local compaction_restore_path = mail_root and mail_root .. "/compaction-restore.json"

local function model_confirm_rule_row(line)
  local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
  return trimmed ~= "" and trimmed:gsub("─", "") == ""
end

local function blank(text)
  if type(text) ~= "string" then return false end
  local stripped = text:gsub("%s", "")
  stripped = stripped:gsub("\194\160", "")
  return stripped == ""
end

local function model_confirm_dialog(screen)
  if type(screen) ~= "string" then return nil end
  local lines = bottom_screen_lines(screen, 32)
  local index
  for row = #lines - 1, 1, -1 do
    if lines[row]:find("❯%s*1%.%s+Yes")
        and lines[row + 1]:find("%d%.%s+No, go back") then
      index = row
      break
    end
  end
  if not index then return nil end

  local title_row
  for row = math.max(1, index - 24), index - 1 do
    if lines[row]:find("Switch model?", 1, true) then
      title_row = row
    end
  end

  for row = index + 2, #lines do
    local line = lines[row]
    if line:match("^%s*%d+%.%s")
        or line:match("^%s*>%s*%d+%.%s")
        or line:match("^%s*❯%s*%d+%.%s") then
      return nil
    end
  end

  local first_rule
  for row = index + 2, #lines do
    if model_confirm_rule_row(lines[row]) then
      first_rule = row
      break
    end
  end
  if first_rule then
    for row = index + 2, first_rule - 1 do
      if not blank(lines[row])
          and not lines[row]:find("Enter to confirm", 1, true) then
        return nil
      end
    end
  end

  local previous_rule, last_rule
  for row = index + 2, #lines do
    if model_confirm_rule_row(lines[row]) then
      previous_rule, last_rule = last_rule, row
    end
  end
  if previous_rule and last_rule then
    for row = previous_rule + 1, last_rule - 1 do
      local content = lines[row]:gsub("^%s*❯", "", 1)
      if not blank(content) then
        return nil
      end
    end
  end

  return lines, index, title_row
end

local function model_confirm_signature(screen)
  local lines, index, title_row = model_confirm_dialog(screen)
  if not title_row then return nil end
  local dialog = {}
  for row = title_row, index + 1 do dialog[#dialog + 1] = lines[row] end
  return table.concat(dialog, "\n")
end

local function model_confirm_options_visible(screen)
  local _, index = model_confirm_dialog(screen)
  return index ~= nil
end

local function model_dialog_waiting(screen)
  if type(screen) ~= "string" then return false end
  local lines = bottom_screen_lines(screen, 32)
  for _, line in ipairs(lines) do
    if line:find("Switch model?", 1, true) then
      return true
    end
  end
  return false
end

local function model_timeout_reason(reason, session_name, screen)
  if not model_dialog_waiting(screen) then return reason end
  return reason .. "; a Switch model? dialog appears to be waiting in "
    .. session_name .. ". Next: run `remuda attach \"" .. session_name
    .. "\"` and press Enter to confirm or Esc to cancel"
end

remuda._butler_model_confirm_signature = model_confirm_signature
remuda._butler_model_confirm_options_visible = model_confirm_options_visible
remuda._butler_model_dialog_waiting = model_dialog_waiting
remuda._butler_model_timeout_reason = model_timeout_reason

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
  local wrote, write_err = remuda.fs.write_atomic(compaction_restore_path, encoded, { private = true })
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
      if agent.kind == "codex" and not state.restore_pending and not dry_run then
        local persisted = compaction_restore_for(agent, session_name)
        if type(persisted) == "string" and persisted:match("^codex:") then
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

-- Codex compacts on this model. `/model` (codex-cli 0.159) opens "Select Model
-- and Effort" (a number key picks a row), then "Select Reasoning Level for
-- <Model>" with the cursor on that model's default effort; `s` applies the
-- choice for this session only. Enter or a number key there would rewrite
-- the global default in $CODEX_HOME/config.toml, so neither is ever sent.
local CODEX_LOWER_MODEL = "gpt-6-luna"
local CODEX_EFFORT_ROWS = { xhigh = "extra high" }
local function screen_lines(screen)
  local lines = {}
  for line in (screen .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  return lines
end
-- The footer names the session's model and effort: "GPT-5.6-Sol high · /work".
local function codex_footer(screen)
  if type(screen) ~= "string" then return nil end
  local model, effort
  for _, line in ipairs(screen_lines(screen)) do
    local m, e = line:match("^%s*(GPT%-[%w%.%-]+)%s+(%a+)%s+·")
    if m then model, effort = m:lower(), e:lower() end
  end
  return model, effort
end
-- The numbered rows below the picker titled `title` (lowercase), or nil.
local function codex_picker_rows(screen, title)
  if type(screen) ~= "string" then return nil end
  local rows
  for _, line in ipairs(screen_lines(screen)) do
    if line:lower():find(title, 1, true) then
      rows = {}
    elseif rows then
      local mark, number, label = line:match("^%s*([^%s%d]*)%s*(%d+)%.%s+(.-)%s*$")
      if number then rows[#rows + 1] = { number = number, label = label:lower(), cursor = mark ~= "" } end
    end
  end
  return rows
end
local function codex_row(rows, name)
  for index, row in ipairs(rows or {}) do
    local rest = row.label:sub(#name + 1)
    if row.label:sub(1, #name) == name and (rest == "" or rest:match("^[%s(]")) then return index, row end
  end
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
  if agent.kind == "codex" and not state.restore_pending then
    local persisted = compaction_restore_for(agent, session_name)
    if type(persisted) == "string" and persisted:match("^codex:") then
      state.restore_pending = persisted
      state.restore_pending_attempts = 0
      state.restore_pending_exhausted = nil
    end
  end
  local restore_pending = (agent.kind == "claude" or agent.kind == "codex") and type(state.restore_pending) == "string"
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
    settings_path = system.home() .. "/.claude/settings.json"
  end
  -- A Claude session already on Sonnet is not switched, so nothing is restored.
  local claude_switch = agent.kind == "claude"
  local function release_lock()
    state.compaction_in_progress = false
    if owner_state.compaction_fleet_active == state_key then owner_state.compaction_fleet_active = nil end
  end
  -- `wording` replaces "Compaction failed" when the outcome is unknown.
  local function fail(reason, wording)
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
            "model restore failed; member may still be on "
              .. (agent.kind == "codex" and CODEX_LOWER_MODEL or "sonnet"))
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
      (wording or "Compaction failed") .. ": " .. tostring(reason))
  end
  local function finish_success(event)
    if claude_switch then
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
    pcall(remuda._butler_notice_compacted, session_name)
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
    local sent, status = pcall(remuda.type_text, session_name, command, config.input_settle)
    if not sent then fail("compaction command failed: " .. tostring(status)); return false end
    -- The status ("submitted" or "unverified"; nil on an older core), else true.
    return status or true
  end
  local function wait_for(id, matcher, action, timeout, on_timeout, on_fail)
    local fail = on_fail or fail
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
        if claude_switch and (id == "model-sonnet" or id == "compact-complete") then
          state.restore_pending = prior_model
          state.restore_pending_attempts = 0
          state.restore_pending_attempt_active = nil
          state.restore_pending_failure_notified = nil
        end
        fail("unrecognized dialog during " .. id)
      end,
      on_timeout = function(screen, handle)
        local model_watcher = agent.kind == "claude" and (id == "model-sonnet" or id == "model-restored")
        local function timeout_reason(reason)
          if model_watcher then return model_timeout_reason(reason, session_name, screen) end
          return reason
        end
        if unknown_state.started_at or (model_watcher and model_confirm_state.started_at) then
          if claude_switch and (id == "model-sonnet" or id == "compact-complete") then
            state.restore_pending = prior_model
            state.restore_pending_attempts = 0
            state.restore_pending_attempt_active = nil
            state.restore_pending_failure_notified = nil
          end
          fail(timeout_reason("unrecognized dialog during " .. id))
        elseif on_timeout then
          on_timeout(screen, handle)
        else
          fail(timeout_reason("timed out waiting for " .. id))
        end
      end,
      on_error = function(err) fail("compaction watcher error: " .. tostring(err)) end }, false)
    if not ok then fail("could not start " .. id .. " watcher: " .. tostring(started_handle)) end
    handle = started_handle
    return ok
  end
  local completion_timeout = agent.kind == "claude"
    and config.claude_completion_timeout or config.completion_timeout
  local function claude_settings_model()
    return (read_claude_settings(settings_path) or {}).model
  end
  -- A Claude model wait ends only on a confirmed switch: the status line shows
  -- the target, or settings.json names `typed` where it did not before the
  -- command (`before`); and the pane is ready (no dialog, empty composer).
  local function wait_for_model(id, typed, before, status_matches, action)
    local now = remuda._butler_compaction_now or os.time
    local started, by = now(), nil
    local function traced(outcome)
      _butler_trace("model_wait", detail .. " id=" .. id .. " outcome=" .. outcome
        .. (by and " by=" .. by or "") .. " elapsed=" .. (now() - started) .. "s")
    end
    wait_for(id, function(screen)
      if model_confirm_options_visible(screen) or model_confirm_signature(screen) then return false end
      local checked, composer = pcall(remuda._butler_prompt_is_empty, agent.kind, screen)
      if not checked or composer ~= "EMPTY" then return false end
      if status_matches() then by = "status"
      elseif before ~= typed and claude_settings_model() == typed then by = "settings"
      else return false end
      return true
    end, function(screen) traced("confirmed"); action(screen) end, completion_timeout,
    function(screen)
      traced("timeout")
      fail(model_timeout_reason("timed out waiting for " .. id, session_name, screen))
    end)
  end
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
    local before = claude_settings_model()
    if not send_command("/model " .. prior_model) then return end
    wait_for_model("model-restored", prior_model, before, function()
      local current = remuda._butler_telemetry_for(agent) or {}
      return statusline_model_matches(current.model, prior_model)
    end, function()
      if after_restore then after_restore() else finish_success(event or "verified") end
    end)
  end
  local codex_prior = agent.kind == "codex" and restore_pending or nil
  local function forget_prior()
    codex_prior = nil
    state.restore_pending = nil
    state.restore_pending_attempts = nil
    state.restore_pending_attempt_active = nil
    local cleared, clear_err = clear_compaction_restore(compaction_agent_key(agent, session_name), session_name)
    if not cleared then _butler_trace("restore_record_clear_failed", detail .. " reason=" .. tostring(clear_err)) end
  end
  -- The prior Claude model is back after a failed compaction: forget the
  -- pending restore, unless settings.json still names another model (then the
  -- next tick puts it back).
  local function fail_after_claude_restore(reason)
    local matches = remuda._butler_compaction_verify_settings_model(read_claude_settings(settings_path), prior_model)
    if matches ~= false then forget_prior() end
    fail(reason)
  end
  -- Pick `model` at `effort` for this Codex session only, reading each picker
  -- row from the screen. Every failure closes the picker, then calls on_abort.
  local function codex_select(model, effort, on_done, on_abort)
    local row_label = CODEX_EFFORT_ROWS[effort] or effort
    local picker_timeout = math.max(completion_timeout, 15)
    local effort_title = "select reasoning level for " .. model
    local function picker_open(screen)
      if codex_picker_rows(screen, "select reasoning level for ") then return "effort" end
      if codex_picker_rows(screen, "select model and effort") then return "model" end
      if codex_footer(screen) then return "closed" end
    end
    -- One ESC per screen, each confirmed from the screen before the next,
    -- so two ESCs never merge and none lands in the composer.
    local function escape(reason, escapes)
      local function left_open() on_abort(reason .. "; the Codex model picker was left open") end
      wait_for("codex-picker-escape", function(screen) return picker_open(screen) ~= nil end, function(screen)
        local open = picker_open(screen)
        if open == "closed" then on_abort(reason); return end
        if escapes >= 2 or not pcall(remuda.key, session_name, "ESC") then left_open(); return end
        wait_for("codex-" .. open .. "-picker-closed", function(next_screen)
          local now = picker_open(next_screen)
          return now ~= nil and now ~= open
        end, function() escape(reason, escapes + 1) end, picker_timeout, nil, left_open)
      end, picker_timeout, nil, left_open)
    end
    local function abort(reason) escape(reason, 0) end
    local function key(name, what)
      local pressed, press_err = pcall(remuda.key, session_name, name)
      if not pressed then abort(what .. " key failed: " .. tostring(press_err)) end
      return pressed
    end
    if not send_command("/model") then return end
    -- The row, or the same rows on 3 captures (not a half-painted list).
    local seen, seen_count = nil, 0
    wait_for("codex-model-picker", function(screen)
      local rows = codex_picker_rows(screen, "select model and effort")
      if not rows or #rows == 0 then seen, seen_count = nil, 0; return false end
      if codex_row(rows, model) then return true end
      local labels = {}
      for _, row in ipairs(rows) do labels[#labels + 1] = row.label end
      labels = table.concat(labels, "\n")
      seen_count = labels == seen and seen_count + 1 or 1
      seen = labels
      return seen_count >= 3
    end, function(screen)
      local _, row = codex_row(codex_picker_rows(screen, "select model and effort"), model)
      if not row then abort("no " .. model .. " row in the Codex model picker"); return end
      if not key(row.number, "model picker") then return end
      local function effort_rows(effort_screen)
        local rows = codex_picker_rows(effort_screen, effort_title)
        for index, candidate in ipairs(rows or {}) do if candidate.cursor then return rows, index end end
      end
      wait_for("codex-effort-picker", function(effort_screen)
        return effort_rows(effort_screen) ~= nil
      end, function(effort_screen)
        local rows, cursor = effort_rows(effort_screen)
        local target = codex_row(rows, row_label)
        if not target then abort("no '" .. effort .. "' effort row for " .. model); return end
        local step = target > cursor and "<down>" or "<up>"
        for _ = 1, math.abs(target - cursor) do
          if not key(step, "effort picker") then return end
        end
        -- Only apply once the cursor is seen on the target row.
        wait_for("codex-effort-row", function(row_screen)
          local _, at = effort_rows(row_screen)
          return at == target
        end, function()
          if not key("s", "session-only model") then return end
          wait_for("codex-model-set", function(set_screen)
            local current, current_effort = codex_footer(set_screen)
            return current == model and current_effort == effort
          end, on_done, picker_timeout, nil, abort)
        end, picker_timeout, nil, abort)
      end, picker_timeout, nil, abort)
    end, picker_timeout, nil, abort)
  end
  local function codex_restore(event, after_restore)
    local model, effort = tostring(codex_prior):match("^codex:(%S+) (%S+)$")
    if not model then fail("unreadable Codex restore record: " .. tostring(codex_prior)); return end
    codex_select(model, effort, function()
      if after_restore then after_restore() else finish_success(event or "verified") end
    end, fail)
  end
  local function monitor_until_idle()
    local warned = pcall(remuda._butler_send, session_name, agent.parent or "butler",
      "Compaction is still running; the fleet lock remains held until this session is idle.")
    state.compaction_still_running_notice_sent = warned and true or false
    -- #158: the monitor holds the fleet lock, so it gives up at a ceiling.
    -- The pane is still busy there, so no /model is typed: a pending restore
    -- (state and durable record) stays for the tick to apply once idle.
    local ceiling = config.monitor_ceiling_seconds
    local now = remuda._butler_compaction_now or os.time
    local give_up_at = now() + ceiling
    local monitor_ok, monitor = pcall(remuda.schedule, { every = 1, run = function()
      local found, session = pcall(remuda.session, session_name)
      if now() >= give_up_at then
        if state.compaction_monitor then remuda.cancel(state.compaction_monitor) end
        state.compaction_monitor = nil
        state.compaction_still_running_notice_sent = nil
        local reason = "still busy after " .. math.ceil(ceiling / 60) .. " min"
        if state.restore_pending then reason = reason .. "; the model is restored when the session is idle" end
        fail(reason, "Compaction not confirmed yet")
      elseif not found or not session then
        if state.compaction_monitor then remuda.cancel(state.compaction_monitor) end
        state.compaction_monitor = nil
        fail("session unavailable after compaction timeout")
      elseif pane_busy() == false then
        if state.compaction_monitor then remuda.cancel(state.compaction_monitor) end
        state.compaction_monitor = nil
        state.compaction_still_running_notice_sent = nil
        if claude_switch then restore_model("completed_after_timeout")
        elseif codex_prior then codex_restore("completed_after_timeout")
        else finish_success("completed_after_timeout") end
      end
    end })
    if monitor_ok then state.compaction_monitor = monitor end
  end

  local function compact()
    local sent = send_command("/compact")
    if not sent then return end
    -- type_text could not confirm the command and the pane is idle: it was not
    -- submitted, so do not wait the completion timeout for a compaction.
    if agent.kind == "claude" and sent == "unverified" and pane_busy() == false then
      if claude_switch then
        restore_model(nil, function() fail_after_claude_restore("compact command not submitted") end)
      else
        fail("compact command not submitted")
      end
      return
    end
    wait_for("compact-complete", function()
      local current = remuda._butler_telemetry_for(agent) or {}
      local used = tonumber(current.context_used)
      return used and ctx_before and used < ctx_before
    end, function()
      if claude_switch then restore_model("verified")
      elseif codex_prior then codex_restore("verified")
      else finish_success("verified") end
    end, completion_timeout, function()
      if agent.kind == "claude" then
        if pane_busy() ~= false then
          monitor_until_idle()
        elseif claude_switch then
          restore_model(nil, function() fail_after_claude_restore("compaction context did not drop") end)
        else
          fail("compaction context did not drop")
        end
      elseif pane_busy() ~= false then
        monitor_until_idle()
      elseif codex_prior then
        codex_restore(nil, function()
          forget_prior()
          fail("compaction context did not drop", "Compaction not confirmed yet")
        end)
      else
        fail("compaction context did not drop", "Compaction not confirmed yet")
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
    if agent.kind == "codex" then codex_restore("restored_after_dialog")
    else restore_model("restored_after_dialog") end
    return "restoring_model"
  end
  state.compaction_in_progress = true
  state.failure_cooldown_until = nil
  owner_state.compaction_fleet_active = state_key
  _butler_trace("sent", detail)
  local function telemetry_on_sonnet()
    local current = remuda._butler_telemetry_for(agent) or {}
    return type(current.model) == "string" and current.model:lower():find("sonnet", 1, true) ~= nil
  end
  if agent.kind == "claude" and telemetry_on_sonnet() then
    claude_switch = false
    _butler_trace("model_switch_skipped", detail .. " reason=already_lower")
    compact()
  elseif agent.kind == "claude" then
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
    local before = claude_settings_model()
    if not send_command("/model sonnet") then return "failed" end
    wait_for_model("model-sonnet", "sonnet", before, telemetry_on_sonnet, compact)
  else
    local _, screen = pcall(remuda.capture, session_name)
    local current, current_effort = codex_footer(screen)
    if not current then
      _butler_trace("model_switch_skipped", detail .. " reason=footer_unreadable")
      compact()
    elseif current == CODEX_LOWER_MODEL then
      _butler_trace("model_switch_skipped", detail .. " reason=already_lower")
      compact()
    else
      codex_prior = "codex:" .. current .. " " .. current_effort
      state.restore_pending = codex_prior
      state.restore_pending_attempts = 0
      state.restore_pending_exhausted = nil
      local persisted, persist_err = persist_compaction_restore(compaction_agent_key(agent, session_name), codex_prior)
      if not persisted then
        codex_prior, state.restore_pending, state.restore_pending_attempts = nil, nil, nil
        fail("could not persist model restore state: " .. tostring(persist_err))
        return "failed"
      end
      codex_select(CODEX_LOWER_MODEL, current_effort, compact, function(reason)
        forget_prior()
        fail(reason)
      end)
    end
  end
  return "started"
end
