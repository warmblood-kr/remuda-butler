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

local function schedule(remuda, kind, actual, name, parent, task)
  local poll, ticks, attempts, verify_ticks = nil, 0, 0, 0
  poll = remuda.schedule({ every = 0.5, run = function()
    ticks = ticks + 1
    local captured, screen = pcall(remuda.capture, actual)
    if not captured then
      remuda.cancel(poll)
      notify(remuda, parent, name, "could not capture the agent screen")
      return
    end

    if attempts == 0 then
      if ready(kind, screen) then
        attempts = 1
        verify_ticks = 0
        -- One atomic paste after the agent has enabled its composer. The
        -- longer settle also ensures Codex sees Return as a separate submit.
        pcall(remuda.type_text, actual, task, 2)
      elseif ticks >= 60 then
        remuda.cancel(poll)
        notify(remuda, parent, name, "the composer never became ready")
      end
      return
    end

    if prompt_start_visible(screen, task) then
      remuda.cancel(poll)
      return
    end

    verify_ticks = verify_ticks + 1
    if verify_ticks >= 12 and attempts == 1 then
      -- The initial send may have raced a screen transition. A single full
      -- retry is permitted; the long prompt is never split into chunks.
      attempts = 2
      verify_ticks = 0
      pcall(remuda.type_text, actual, task, 2)
    elseif verify_ticks >= 12 then
      remuda.cancel(poll)
      notify(remuda, parent, name, "the START marker remained absent after two attempts")
    end
  end })
  return poll
end

local delivery = { schedule = schedule, ready = ready, prompt_start_visible = prompt_start_visible }
remuda._butler_prompt_delivery = delivery
return delivery
