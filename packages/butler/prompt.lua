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
  local raw = (tostring(result or "") .. " " .. tostring(detail or "")):lower()
  local refused = raw:find("latesubmitabandoned", 1, true)
    or (raw:find("input write", 1, true) and raw:find("in flight", 1, true))
  local outcome = (refused or result == false) and "refused" or ok and "success" or "error"
  if type(_butler_session_trace) == "function" then
    pcall(_butler_session_trace, "task_write_outcome", session .. " marker=" .. tostring(marker)
      .. " outcome=" .. outcome .. (first ~= "" and " first_line=" .. first or ""))
  end
  return outcome, first
end

local function prompt_start_visible(screen, task)
  local visible, expected = compact(screen), compact(task)
  if expected == "" then return false end
  local marker_size = math.min(48, #expected)
  return visible:find(expected:sub(1, marker_size), 1, true) ~= nil
end

local function notify(remuda, parent, name, reason)
  if parent then
    pcall(remuda._butler_send, "butler", parent,
      "Could not verify delivery of the initial task to " .. name .. ": " .. reason .. ".")
  end
end

local function schedule(remuda, kind, actual, name, parent, task, options)
  options = options or {}
  local poll, startup_ticks, deferred_ticks, verify_ticks = nil, 0, 0, 0
  local attempts = 0
  local handled_modals, settle_until, task_seen_in_composer = {}, 0, false
  local verify_started
  local function now()
    if options.now then
      local ok, value = pcall(options.now)
      if ok and tonumber(value) then return tonumber(value) end
    end
    return os.time()
  end
  local function finish(ok, reason)
    remuda.cancel(poll)
    if options.on_done then
      pcall(options.on_done, ok, reason)
    elseif not ok then
      notify(remuda, parent, name, reason)
    end
  end
  poll = remuda.schedule({ every = 0.5, run = function()
    if options.same_launch then
      local checked, alive, reason = pcall(options.same_launch)
      if not checked or alive ~= true then
        finish(false, reason or "session was replaced")
        return
      end
    end
    if verify_started and options.detect_only and now() - verify_started < 15 then return end
    local captured, screen = pcall(remuda.capture, actual)
    if not captured then
      finish(verify_started ~= nil and options.detect_only == true, "could not capture the agent screen")
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

    if attempts == 0 then
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
        local allowed = true
        if options.detect_only and options.empty then
          local checked, decision = pcall(options.empty, screen)
          allowed = checked and decision == "EMPTY"
        end
        if options.allowed then
          local checked, result = pcall(options.allowed, false, screen)
          allowed = allowed and checked and result == true
        end
        if not allowed then
          deferred_ticks = deferred_ticks + 1
          if deferred_ticks >= (options.timeout or 600) then
            finish(false, "deferred")
          end
          return
        end
        attempts = 1
        verify_ticks = 0
        -- Keep this nonblocking: a long terminal sleep stalls every daemon
        -- callback, including notice and lifecycle work.
        local typed, result, detail = pcall(remuda.type_text, actual, task, 0.1)
        local outcome, first = trace_write(remuda, actual, options.marker, typed, result, detail)
        if options.on_write then pcall(options.on_write, outcome, first) end
        if outcome ~= "success" then
          local reason = first ~= "" and first or "write refused"
          finish(false, options.detect_only and reason or "type failed: " .. reason)
        else
          verify_started = now()
        end
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

    verify_ticks = verify_ticks + 1
    local started = prompt_start_visible(screen, task)
    local empty = true
    local composer_text = ""
    if options.empty then
      local checked, decision, text = pcall(options.empty, screen)
      empty = checked and decision == "EMPTY"
      if checked then composer_text = tostring(text or "") end
    end
    local session_busy = false
    if remuda.session then
      local checked, session = pcall(remuda.session, actual)
      session_busy = not checked or not session or session.is_busy == true
    end
    if options.detect_only then
      if options.working then
        local checked, working = pcall(options.working, screen)
        session_busy = session_busy or not checked or working == true
      end
      finish(not (empty and not session_busy), "write returned success but the task never appeared")
      return
    end
    -- Busy is useful only after the composer releases our text; typing the
    -- task itself also makes a terminal look busy.
    if session_busy and empty then
      finish(true)
      return
    end
    local placeholder = composer_text:match("^%[?Pasted text #%d+%s*%+%s*%d+%s+lines?%]?%s*$") ~= nil
      or composer_text:match("^%[Pasted Content %d+ chars%]$") ~= nil
    local composer_is_task = not empty and (compact(composer_text) == compact(task) or placeholder)
    if composer_is_task then task_seen_in_composer = true end
    if started and empty then
      finish(true)
      return
    end
    if task_seen_in_composer and empty then
      finish(true)
      return
    end
    -- A task can be fully painted while its first Return is dropped. Retry
    -- submit once, before allowing queued notices to reach this composer.
    if composer_is_task and verify_ticks >= 4 and not options.return_retried then
      local allowed = true
      if options.allowed then
        local checked, result = pcall(options.allowed, true, screen)
        allowed = checked and result == true
      end
      if not allowed then
        deferred_ticks = deferred_ticks + 1
        if deferred_ticks >= (options.timeout or 600) then finish(false, "deferred") end
        return
      end
      options.return_retried = true
      pcall(remuda.key, actual, "RET")
      verify_ticks = 0
      return
    end
    if verify_started and now() - verify_started >= (options.submit_timeout or 300) then
      finish(false, "submit")
    end
  end })
  return poll
end

local delivery = { schedule = schedule, ready = ready, prompt_start_visible = prompt_start_visible, trace_write = trace_write }
remuda._butler_prompt_delivery = delivery
return delivery
