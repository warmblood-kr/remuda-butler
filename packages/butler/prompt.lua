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
  local poll, ticks, attempts, verify_ticks = nil, 0, 0, 0
  local function finish(ok, reason)
    remuda.cancel(poll)
    if options.on_done then
      pcall(options.on_done, ok, reason)
    elseif not ok then
      notify(remuda, parent, name, reason)
    end
  end
  poll = remuda.schedule({ every = 0.5, run = function()
    ticks = ticks + 1
    local captured, screen = pcall(remuda.capture, actual)
    if not captured then
      finish(false, "could not capture the agent screen")
      return
    end

    if attempts == 0 then
      local is_ready = ready(kind, screen)
      if options.ready then
        local checked, result = pcall(options.ready, screen)
        is_ready = checked and result == true
      end
      if is_ready then
        local allowed = true
        if options.allowed then
          local checked, result = pcall(options.allowed)
          allowed = checked and result == true
        end
        if not allowed then
          if ticks >= (options.timeout or 60) then
            finish(false, "deferred")
          end
          return
        end
        attempts = 1
        verify_ticks = 0
        -- One atomic paste after the agent has enabled its composer. The
        -- longer settle also ensures Codex sees Return as a separate submit.
        pcall(remuda.type_text, actual, task, 2)
      elseif ticks >= (options.timeout or 60) then
        finish(false, "the composer never became ready")
      end
      return
    end

    verify_ticks = verify_ticks + 1
    local started = prompt_start_visible(screen, task)
    local empty = true
    if options.empty then
      local checked, decision = pcall(options.empty, screen)
      empty = checked and decision == "EMPTY"
    end
    local session_busy = false
    if remuda.session then
      local checked, session = pcall(remuda.session, actual)
      session_busy = checked and session and session.is_busy == true
    end
    if started and (empty or session_busy) then
      finish(true)
      return
    end
    -- A task can be fully painted while its first Return is dropped. Retry
    -- submit once, before allowing queued notices to reach this composer.
    if started and not empty and not session_busy and verify_ticks >= 4 and not options.return_retried then
      options.return_retried = true
      pcall(remuda.key, actual, "RET")
      verify_ticks = 0
      return
    end
    if verify_ticks >= 12 and attempts == 1 then
      -- The initial send may have raced a screen transition. A single full
      -- retry is permitted; the long prompt is never split into chunks.
      attempts = 2
      verify_ticks = 0
      pcall(remuda.type_text, actual, task, 2)
    elseif verify_ticks >= 12 then
      finish(false, "deferred")
    end
  end })
  return poll
end

local delivery = { schedule = schedule, ready = ready, prompt_start_visible = prompt_start_visible }
remuda._butler_prompt_delivery = delivery
return delivery
