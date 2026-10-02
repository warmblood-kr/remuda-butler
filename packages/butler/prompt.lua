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

local function prompt_start_visible(screen, task)
  local visible, expected = compact(screen), compact(task)
  if expected == "" then return false end
  local marker_size = math.min(48, #expected)
  return visible:find(expected:sub(1, marker_size), 1, true) ~= nil
end

local function task_running_visible(screen, task, composer)
  local expected = compact(task)
  local marker = expected:sub(1, math.min(48, #expected))
  return prompt_start_visible(screen, task) and not compact(composer):find(marker, 1, true)
end

local function paste_placeholder(text)
  text = tostring(text or "")
  return text:match("^%[Pasted text #%d+ %+%d+ lines?%]$") ~= nil
    or text:match("^%[Pasted Content %d+ chars%]$") ~= nil
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
  local handled_modals, settle_until = {}, 0
  local write_succeeded = false
  local write_result
  local task_seen_in_composer = false
  local verify_started, retry_at, retry_failures, last_retry_reason, finished
  local retry_delays = options.retry_delays or { 20, 60, 300, 900 }
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
    if options.on_done then
      pcall(options.on_done, ok, reason,
        (tonumber(options.prior_failures) or 0) + (retry_failures or 0) + (ok and 1 or 0))
    elseif not ok then
      notify(remuda, parent, name, reason)
    end
  end
  local function retry(reason)
    if options.recipient_alive then
      local checked, alive = pcall(options.recipient_alive)
      if not checked or alive ~= true then finish(false, "recipient gone"); return end
    end
    retry_failures = (retry_failures or 0) + 1
    last_retry_reason = reason
    local delay = retry_delays[retry_failures]
    if not delay then finish(false, reason); return end
    retry_at = now() + delay
    startup_ticks, deferred_ticks, verify_ticks = 0, 0, 0
    -- A successful write is at-most-once. Keep it in verification mode across
    -- retries so a populated composer can receive a safe Return retry.
    attempts = write_succeeded and 1 or 0
    settle_until = 0
    verify_started = write_succeeded and now() or nil
    options.return_retried = nil
    if options.on_retry then pcall(options.on_retry, retry_failures, delay, reason) end
  end
  local function submit_timeout(screen, decision, composer_text)
    if write_succeeded then
      -- Before giving up, allow one safe Return retry when the composer still
      -- exactly matches our write. Never submit an arbitrary paste or draft.
      if decision == "NON-EMPTY" and compact(composer_text) == compact(task)
          and not options.return_retried then
        local allowed = true
        if options.allowed then
          local checked, result = pcall(options.allowed, true, screen)
          allowed = checked and result == true
        end
        if allowed then
          options.return_retried = true
          pcall(remuda.key, actual, "RET")
          verify_ticks = 0
          verify_started = now()
          return
        end
      end
      finish(false, "submit")
    else retry("submit") end
  end
  poll = remuda.schedule({ every = 0.5, run = function()
    if finished then return end
    if options.recipient_alive then
      local checked, alive = pcall(options.recipient_alive)
      if not checked or alive ~= true then finish(false, "recipient gone"); return end
    end
    if retry_at then
      if now() < retry_at then return end
      retry_at = nil
    end
    local captured, screen = pcall(remuda.capture, actual)
    if not captured then
      retry("could not capture the agent screen")
      return
    end
    if write_succeeded and prompt_start_visible(screen, task) then
      task_seen_in_composer = true
    end

    if options.trust_dialog then
      local checked, waiting = pcall(options.trust_dialog, screen)
      if not checked or waiting then
        startup_ticks = startup_ticks + 1
        if startup_ticks >= (options.ready_timeout or 60) then
          retry("waiting for a human to answer the trust dialog")
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
              retry("human active during startup modal")
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
            retry("startup modal did not clear")
          end
          return
        end
      end
      if startup_ticks < settle_until then
        startup_ticks = startup_ticks + 1
        if startup_ticks >= (options.ready_timeout or 60) then
          retry("startup modal did not clear")
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
            retry("deferred")
          end
          return
        end
        if (retry_failures or 0) > 0 and not write_succeeded then
          local checked, decision = false, nil
          if options.empty then checked, decision = pcall(options.empty, screen) end
          if not checked or decision ~= "EMPTY" then
            finish(false, last_retry_reason or "composer was not empty after a failed write")
            return
          end
        end
        attempts = 1
        verify_ticks = 0
        -- Keep this nonblocking: a long terminal sleep stalls every daemon
        -- callback, including notice and lifecycle work.
        local typed, type_result = pcall(remuda.type_text, actual, task, 0.1)
        if not typed or type_result == false then
          local reason = "type failed"
          if not typed and type(type_result) == "string" then
            reason = "type failed: " .. safe_type_error_line(type_result)
          elseif type_result == false then
            reason = "type failed: write refused"
          end
          retry(reason)
        else
          write_succeeded = true
          write_result = type_result
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
          if deferred_ticks >= (options.timeout or 600) then retry("deferred") end
        else
          startup_ticks = startup_ticks + 1
          if startup_ticks >= (options.ready_timeout or 60) then
            retry("the composer never became ready")
          end
        end
      end
      return
    end

    verify_ticks = verify_ticks + 1
    local empty, decision = true, "EMPTY"
    local composer_text = ""
    if options.empty then
      local checked, composer_decision, text = pcall(options.empty, screen)
      decision = checked and composer_decision or "UNPARSEABLE"
      empty = checked and composer_decision == "EMPTY"
      if checked then composer_text = tostring(text or "") end
    end
    -- A blank capture can miss text that is still in the composer. Trust it
    -- only when the core confirmed submission or a prior screen proved the
    -- task reached the prompt.
    if empty then
      if write_result == "submitted" or task_seen_in_composer or prompt_start_visible(screen, task) then
        finish(true)
      elseif verify_started and now() - verify_started >= (options.submit_timeout or 300) then
        submit_timeout(screen, decision, composer_text)
      end
      return
    end
    local composer_is_task = compact(composer_text) == compact(task)
    if composer_is_task or paste_placeholder(composer_text) then task_seen_in_composer = true end
    if not composer_is_task and (decision ~= "NON-EMPTY" or write_result == "submitted")
        and task_running_visible(screen, task, composer_text) then
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
        if deferred_ticks >= (options.timeout or 600) then retry("deferred") end
        return
      end
      options.return_retried = true
      pcall(remuda.key, actual, "RET")
      verify_ticks = 0
      return
    end
    if verify_started and now() - verify_started >= (options.submit_timeout or 300) then
      submit_timeout(screen, decision, composer_text)
    end
  end })
  return poll
end

local delivery = { schedule = schedule, ready = ready, prompt_start_visible = prompt_start_visible }
remuda._butler_prompt_delivery = delivery
return delivery
