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
    local captured, screen = pcall(remuda.capture, actual)
    if not captured then
      finish(false, "could not capture the agent screen")
      return
    end

    if attempts == 0 then
      for index, modal in ipairs(options.modals or {}) do
        if screen:find(modal.match, 1, true) then
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
        attempts = 1
        verify_ticks = 0
        -- Keep this nonblocking: a long terminal sleep stalls every daemon
        -- callback, including notice and lifecycle work.
        local typed = pcall(remuda.type_text, actual, task, 0.1)
        if not typed then finish(false, "type failed") else verify_started = now() end
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
      session_busy = checked and session and session.is_busy == true
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

local delivery = { schedule = schedule, ready = ready, prompt_start_visible = prompt_start_visible }
remuda._butler_prompt_delivery = delivery
return delivery
