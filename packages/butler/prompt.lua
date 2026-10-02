-- First-task delivery is kept separate so its timing/verification policy can
-- be exercised against a fake agent screen without launching an agent CLI.
local function ready(kind, screen)
  if kind == "codex" then
    return screen:find("Ask Codex", 1, true) ~= nil
  end
  if kind == "claude" then
    return screen:find("❯", 1, true) ~= nil
      or screen:find("How can I help you today?", 1, true) ~= nil
  end
  return false
end

local function compact(text)
  return tostring(text):gsub("%s+", "")
end

local function utf8_prefix(value, limit)
  local cut = limit
  while cut > 0 do
    local byte = value:byte(cut + 1) or 0
    if byte < 0x80 or byte > 0xbf then break end
    cut = cut - 1
  end
  return value:sub(1, cut)
end

local function safe_type_error_line(value)
  local line = tostring(value):match("^[^\r\n]*") or ""
  line = line:gsub("[%c]", " "):gsub("\194[\128-\159]", " ")
  line = line:gsub("^.-%.lua:%d+: ", "", 1)
  return utf8_prefix(line, 200)
end

local function trace_write(remuda, session, marker, ok, result, detail)
  local first = safe_type_error_line(ok and (detail or result) or result or "")
  local outcome = "success"
  if not ok or result == false then
    local refused = first:find("LateSubmitAbandoned", 1, true) ~= nil
      or first:find("input write is already in flight", 1, true) ~= nil
    if result == false or refused then outcome = "refused" else outcome = "error" end
  end
  local trace = rawget(_G, "_butler_session_trace")
  if type(trace) == "function" then
    pcall(trace, "task_write_outcome", session .. " marker=" .. tostring(marker)
      .. " outcome=" .. outcome .. (first ~= "" and " first_line=" .. first or ""))
  end
  return outcome, first
end

local function schedule(remuda, kind, actual, name, parent, task, options)
  options = options or {}
  local poll, startup_ticks, deferred_ticks = nil, 0, 0
  local handled_modals, settle_until, write_at, finished = {}, 0, nil, false
  local function now()
    if options.now then
      local ok, value = pcall(options.now)
      if ok and tonumber(value) then return tonumber(value) end
    end
    return os.time()
  end
  local function finish(ok, reason)
    if finished then return end
    finished = true
    remuda.cancel(poll)
    if options.on_done then pcall(options.on_done, ok, reason) end
  end
  local function target_alive()
    if not options.same_launch then return true end
    local checked, alive, reason = pcall(options.same_launch)
    if not checked then return false, "session liveness check failed" end
    return alive == true, reason
  end
  local function observe_write()
    local alive, reason = target_alive()
    if not alive then finish(false, reason or "session was replaced"); return end
    local captured, screen = pcall(remuda.capture, actual)
    if not captured then
      local trace = rawget(_G, "_butler_session_trace")
      if type(trace) == "function" then pcall(trace, "task_write_observation", actual .. " outcome=capture_error") end
      finish(true)
      return
    end
    local checked, decision = pcall(options.empty or remuda._butler_prompt_is_empty, kind, screen)
    local activity_known, active = true, false
    if options.working then
      local ok, value = pcall(options.working, screen)
      if ok then active = value == true else activity_known = false end
    end
    if remuda.session then
      local ok, session = pcall(remuda.session, actual)
      if ok and session then active = active or session.is_busy == true
      else activity_known = false end
    end
    if checked and decision == "EMPTY" and activity_known and not active then
      finish(false, "write returned success but the task never appeared")
    else
      finish(true)
    end
  end
  poll = remuda.schedule({ every = 0.5, run = function()
    if finished then return end
    if write_at then
      if now() - write_at >= 15 then observe_write() end
      return
    end
    local alive, unavailable = target_alive()
    if not alive then finish(false, unavailable or "session was replaced"); return end
    local captured, screen = pcall(remuda.capture, actual)
    if not captured then
      finish(false, "could not capture the agent screen")
      return
    end

    if options.trust_dialog then
      local checked, waiting = pcall(options.trust_dialog, screen)
      if not checked or waiting then
        startup_ticks = startup_ticks + 1
        if startup_ticks >= (options.ready_timeout or 60) then
          finish(false, "waiting for a human to answer the trust dialog")
        end
        return
      end
    end

    if not write_at then
      for index, modal in ipairs(options.modals or {}) do
        if modal.match and screen:find(modal.match, 1, true) then
          local human_active = false
          if options.human_active then
            local checked, active = pcall(options.human_active, screen)
            human_active = checked and active == true
          end
          if human_active then
            startup_ticks = startup_ticks + 1
            if startup_ticks >= (options.ready_timeout or 60) then
              finish(false, "human active during startup modal")
            end
            return
          end
          if not handled_modals[index] then
            handled_modals[index] = true
            for _, key in ipairs(modal.keys or {}) do pcall(remuda.key, actual, key) end
            startup_ticks = startup_ticks + 1
            settle_until = startup_ticks + 3
          else
            startup_ticks = startup_ticks + 1
          end
          if startup_ticks >= (options.ready_timeout or 60) then
            finish(false, "startup modal did not clear")
          end
          return
        end
      end
      if startup_ticks < settle_until then
        startup_ticks = startup_ticks + 1
        if startup_ticks >= (options.ready_timeout or 60) then
          finish(false, "startup modal did not clear")
        end
        return
      end
      local is_ready = ready(kind, screen)
      if options.ready then
        local checked, result = pcall(options.ready, screen)
        is_ready = checked and result == true
      end
      if is_ready then
        local checked, decision = pcall(options.empty or remuda._butler_prompt_is_empty, kind, screen)
        if not checked or decision ~= "EMPTY" then
          finish(false, decision == "NON-EMPTY" and "composer is non-empty" or "composer state is unknown")
          return
        end
        local allowed = true
        if options.allowed then
          local checked, result = pcall(options.allowed, false, screen)
          allowed = checked and result == true
        end
        if not allowed then
          deferred_ticks = deferred_ticks + 1
          if deferred_ticks >= (options.timeout or 600) then
            finish(false, "deferred")
          end
          return
        end
        local typed, result, detail = pcall(remuda.type_text, actual, task, 0.1)
        local outcome, first = trace_write(remuda, actual, options.marker, typed, result, detail)
        if outcome ~= "success" then finish(false, first ~= "" and first or "write refused"); return end
        write_at = now()
      else
        local human_active = false
        if options.human_active then
          local checked, result = pcall(options.human_active, screen)
          human_active = checked and result == true
        end
        if human_active then
          deferred_ticks = deferred_ticks + 1
          if deferred_ticks >= (options.timeout or 600) then finish(false, "deferred") end
        else
          startup_ticks = startup_ticks + 1
          if startup_ticks >= (options.ready_timeout or 60) then
            finish(false, "the composer never became ready")
          end
        end
      end
      return
    end

  end })
  return poll
end

local delivery = { schedule = schedule, ready = ready, trace_write = trace_write }
remuda._butler_prompt_delivery = delivery
return delivery
