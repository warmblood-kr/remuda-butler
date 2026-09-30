-- Mail notices: the typing policy, notice recovery, deposit debounce and
-- delivery, and _butler_send. main.lua passes its locals in (the mail.lua
-- pattern) and binds startup_action_safe and notice_recovery_error back.
local config = assert(remuda._butler_notice_config)
local bus = assert(config.bus)
local resolve = assert(config.resolve)
local mail_address = assert(config.mail_address)
local mail_id = assert(config.mail_id)
local mail = assert(config.mail)
local mailbox = mail.mailbox
local take_delivery_notice_result = assert(config.take_delivery_notice_result)
local notify_mail_delivery = assert(config.notify_mail_delivery)
local deliver_message = assert(config.deliver_message)
local known_startup_modal = assert(remuda._butler_chooser).known_startup_modal
local startup_action_safe

local function mail_notice_text(message, detail)
  if not detail then
    local sender = message.from and (message.from.alias or message.from.session) or "outside"
    if message.kind == "forward" then
      detail = "forwarded by " .. sender
    elseif message.in_reply_to then
      detail = "(reply) from " .. sender
    else
      sender = message.matrix and message.matrix.sender or (message.from and message.from.session) or sender
      detail = "from " .. sender
    end
  end
  return "Butler message " .. message.id .. " " .. detail .. " arrived. Read it: remuda butler inbox"
end

-- #29: a mail notice must never land on a human's half-typed line. Notices
-- wait per recipient, coalesce, and are typed only when the policy allows;
-- the declared `butler-notices` schedule (init.lua) retries every second.
bus.notices = bus.notices or {}
bus.notice_screens = bus.notice_screens or {}
bus.notice_seen = bus.notice_seen or {}
bus.unread_seeded = bus.unread_seeded or {}
bus.unread_seeded_exited_at = bus.unread_seeded_exited_at or {}
bus.notice_retry_reasons = bus.notice_retry_reasons or {}
bus.notice_fallbacks = bus.notice_fallbacks or {}
bus.notice_failure_alerts = bus.notice_failure_alerts or {}
local NOTICE_STABLE_SECONDS = 3
local NOTICE_QUIET_S = 2
local NOTICE_MAX_WAIT_S = 10
local NOTICE_RECOVERY_TIMEOUT_S = 20
-- os.time is whole seconds: quiet is 1-2 s, plus up to 1 s for the notice tick.
local function notice_now()
  local clock = remuda._butler_notice_clock
  if type(clock) == "function" then return clock() end
  return os.time()
end

local function codex_trace_row(text)
  return tostring(text or ""):match(
    "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[%.,]?%d*Z?%s+%u+%s+[%w_%.:]+:.*$") ~= nil
end

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
  if kind == "codex" then
    local remaining = {}
    for row in (text .. "\n"):gmatch("(.-)\n") do
      if not codex_trace_row(row) then remaining[#remaining + 1] = row end
    end
    text = table.concat(remaining, "\n"):match("^%s*(.-)%s*$")
  end
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
    _butler_session_trace("notice_prompt", "message_ids="
      .. table.concat(bus.notices[session] and bus.notices[session].message_order or {}, ",")
      .. " session=" .. session .. " kind=" .. kind .. " decision=" .. decision
      .. " composer_bytes=" .. tostring(#text))
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
  local order, notices, message_times = {}, {}, {}
  for _, id in ipairs(pending.message_order) do
    local notice = pending.message_ids and pending.message_ids[id]
    if notice and identity and mail.is_unread(identity, id) then
      order[#order + 1], notices[id] = id, notice
      message_times[id] = pending.message_times and pending.message_times[id]
    end
  end
  pending.message_order, pending.message_ids, pending.message_times = order, notices, message_times
  local fallback = bus.notice_fallbacks[session]
  if fallback then
    for id in pairs(fallback) do
      if not notices[id] then fallback[id] = nil end
    end
    if next(fallback) == nil then bus.notice_fallbacks[session] = nil end
  end
  pending.count = #order
  pending.text = order[#order] and notices[order[#order]] or nil
  if pending.count == 0 then
    local recovery = bus.notice_recoveries[session]
    if recovery and recovery.draft and recovery.draft ~= "" then
      notice_recovery_error(session, recovery, "mail read during notice recovery")
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
local function trace_notice_retry(session, pending, reason)
  if bus.notice_retry_reasons[session] == reason then return end
  bus.notice_retry_reasons[session] = reason
  _butler_session_trace("notice_retry", "message_ids="
    .. table.concat(pending and pending.message_order or {}, ",")
    .. " session=" .. session .. " reason=" .. tostring(reason))
end
local function notice_byte_length(value)
  return #tostring(value or "")
end
local function log_notice_verify_mismatch(session, state, screen, text, expected, reason)
  _butler_session_trace("notice_verify_mismatch", "message_ids="
    .. table.concat(state.message_ids or {}, ",") .. " session=" .. session
    .. " reason=" .. reason .. " capture_bytes=" .. tostring(notice_byte_length(screen))
    .. " composer_bytes=" .. tostring(notice_byte_length(text))
    .. " expected_bytes=" .. tostring(notice_byte_length(expected)))
end
local function clear_notice_fallbacks(session, ids)
  local fallback = bus.notice_fallbacks[session]
  if not fallback then return end
  for _, id in ipairs(ids or {}) do fallback[id] = nil end
  if next(fallback) == nil then bus.notice_fallbacks[session] = nil end
end
local function notice_fallback_or_fail(session, state, pending, reason)
  local ids = pending and pending.message_order or state.message_ids or {}
  local fallback = bus.notice_fallbacks[session] or {}
  for _, id in ipairs(ids) do
    if fallback[id] then
      return notice_recovery_error(session, state, "notice fallback retry limit reached")
    end
  end
  for _, id in ipairs(ids) do fallback[id] = true end
  bus.notice_fallbacks[session] = fallback
  trace_notice_retry(session, pending, reason)
  bus.notice_recoveries[session] = nil
  return true
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
  _butler_session_trace("notice_recovery_failed", "message_ids="
    .. table.concat(state.message_ids or {}, ",") .. " session=" .. session .. " reason=" .. reason
    .. " draft_bytes=" .. tostring(notice_byte_length(state.draft)))
  bus.notice_retry_reasons[session] = nil
  local alerts = bus.notice_failure_alerts[session] or {}
  bus.notice_failure_alerts[session] = alerts
  if not alerts[reason] then
    alerts[reason] = true
    pcall(remuda._butler_send, "butler", parent,
      "Could not safely deliver queued Butler mail to " .. session .. ": " .. reason
      .. ". Inspect the composer and resend the notice. Message IDs: "
      .. table.concat(state.message_ids or {}, ",") .. "; draft bytes: "
      .. tostring(notice_byte_length(state.draft)) .. ".")
  end
  clear_notice_fallbacks(session, state.message_ids)
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
      for _, id in ipairs(state.message_ids) do
        if pending.message_times then pending.message_times[id] = nil end
      end
    else
      pending.count = pending.count - state.count
    end
    if pending.count <= 0 then
      bus.notices[session] = nil
    else
      local first_at, last_at
      for _, id in ipairs(pending.message_order or {}) do
        local arrived_at = pending.message_times and pending.message_times[id]
        if arrived_at then
          first_at = first_at and math.min(first_at, arrived_at) or arrived_at
          last_at = last_at and math.max(last_at, arrived_at) or arrived_at
        end
      end
      pending.first_at = first_at or pending.last_at or notice_now()
      pending.last_at = last_at or pending.last_at or pending.first_at
      pending.due_at = math.min(pending.last_at + NOTICE_QUIET_S,
        pending.first_at + NOTICE_MAX_WAIT_S)
    end
  end
  bus.notice_recoveries[session] = nil
  bus.notice_retry_reasons[session] = nil
  bus.notice_failure_alerts[session] = nil
  clear_notice_fallbacks(session, state.message_ids)
  return true
end
local function recovery_human_safe(session, allow_busy)
  local session_row
  for _, candidate in ipairs(remuda.ls()) do
    if candidate.name == session then session_row = candidate end
  end
  if not session_row or not session_row.alive then return false end
  if session_row.attached then
    if session_row.human_idle ~= nil then
      if session_row.human_idle < (remuda._butler_notice_human_idle or 10) then return false end
    elseif remuda._butler_human_active(session) then
      return false
    end
  end
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
  if not typed then
    local fallback = bus.notice_fallbacks[session] or {}
    for _, id in ipairs(state.message_ids) do
      if fallback[id] then return notice_recovery_error(session, state, "fallback notice typing failed") end
    end
    return notice_recovery_error(session, state, "the notice could not be typed")
  end
  state.phase, state.checks, state.saw_notice = "verify_notice", 0, false
  return false
end
local function tick_notice_recovery(session, state)
  if state.failed then return false end
  state.started_at = state.started_at or notice_now()
  if notice_now() - state.started_at >= NOTICE_RECOVERY_TIMEOUT_S then
    return notice_recovery_error(session, state, "recovery timed out after 20 seconds")
  end
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
  local pending = bus.notices[session]
  trace_notice_retry(session, pending, "prompt-" .. decision)
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
    if not redrawn then return notice_recovery_error(session, state, "Ctrl-L redraw failed") end
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
        "the existing Butler notice could not be submitted") end
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
    if not cleared then return notice_recovery_error(session, state, "the draft clear key failed") end
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
      log_notice_verify_mismatch(session, state, screen, text, state.notice,
        "existing notice did not leave composer")
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
        "the notice Return failed") end
      state.return_retried = true
      return false
    end
    if state.checks >= 12 then
      if decision == "EMPTY" then
        notice_fallback_or_fail(session, state, pending,
          "cap reached; prompt-empty; falling back to normal delivery")
        return false
      end
      log_notice_verify_mismatch(session, state, screen, text, state.notice,
        "notice submit could not be verified")
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
    recovering.started_at = recovering.started_at or notice_now()
    if notice_now() - recovering.started_at >= NOTICE_RECOVERY_TIMEOUT_S then
      if remuda._butler_notify_policy(session) then
        if not notice_fallback_or_fail(session, recovering, pending,
            "recovery-timeout; prompt-empty; falling-back-to-normal-delivery") then return false end
        recovering = nil
      else
        return notice_recovery_error(session, recovering, "recovery timed out after 20 seconds")
      end
    end
  end
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
    local state = { phase = "verify_notice", count = pending.count, notice = pending_notice_text(pending), checks = 0,
      started_at = notice_now() }
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
  local state = { phase = "probe", count = pending.count, checks = 0, started_at = notice_now() }
  state.message_ids = {}
  for _, id in ipairs(pending.message_order or {}) do state.message_ids[#state.message_ids + 1] = id end
  bus.notice_recoveries[session] = state
  return tick_notice_recovery(session, state)
end
function remuda._butler_notify(alias, notice, message_id)
  local _, recipient = mail_id(alias, false)
  if message_id and not mail.is_unread(recipient.id, message_id) then return true end
  local now = notice_now()
  if message_id then
    local seen = bus.notice_seen[recipient.id] or {}
    bus.notice_seen[recipient.id] = seen
    if seen[message_id] then return false end
    seen[message_id] = true
  end
  local pending = bus.notices[alias] or { count = 0 }
  bus.notice_retry_reasons[alias] = nil
  if message_id then
    pending.message_ids = pending.message_ids or {}
    pending.message_order = pending.message_order or {}
    if pending.message_ids[message_id] then return false end
    pending.message_ids[message_id] = notice
    pending.message_order[#pending.message_order + 1] = message_id
    pending.message_times = pending.message_times or {}
    pending.message_times[message_id] = now
  end
  pending.first_at = pending.first_at or now
  pending.last_at = now
  pending.due_at = math.min(now + NOTICE_QUIET_S, pending.first_at + NOTICE_MAX_WAIT_S)
  pending.count, pending.text = pending.count + 1, notice
  bus.notices[alias] = pending
  return false
end
local function seed_unread_notices(alias, previous_instance, instance, unread)
  local agent = bus.agents[alias]
  if not agent or not agent.id then return false end
  if unread <= 0 then return true end
  for _, message_id in ipairs(mailbox(agent.id)) do
    if mail.is_unread(agent.id, message_id) then
      local seen = bus.notice_seen[agent.id]
      local pending = bus.notices[alias]
      local already_pending = pending and pending.message_ids and pending.message_ids[message_id]
      local already_seen = seen and seen[message_id]
      if previous_instance ~= nil and previous_instance ~= instance
          and already_seen and not already_pending then
        -- A prior session may have recorded the deposit notice before its
        -- queue was cleared at exit. Replay that unread mail for this session.
        seen[message_id] = nil
        already_seen = false
      end
      if not already_pending and not already_seen then
        local message = mail.find_message(message_id) or {}
        local resent = bus.mail_resent[agent.id] and bus.mail_resent[agent.id][message_id]
        local detail
        if resent then
          local by = resent.from and (resent.from.alias or resent.from.session) or "outside"
          detail = "forwarded by " .. by
        end
        message.id = message.id or message_id
        remuda._butler_notify(alias, mail_notice_text(message, detail), message_id)
      end
    end
  end
  return true
end
local function notice_session_instance(alias, agent, session_instances)
  if type(agent.session_instance_id) == "string" and agent.session_instance_id ~= "" then
    return agent.session_instance_id
  end
  local instance = session_instances[alias]
  if type(instance) == "string" and instance ~= "" then
    return instance
  end
  -- Agent records are replaced when Butler relaunches a member, and survive
  -- a mod reload, so the record itself is the fallback instance token.
  return agent
end
function remuda._butler_deliver_notices()
  local now = notice_now()
  local session_instances = {}
  local listed, sessions = pcall(remuda.ls)
  if listed and type(sessions) == "table" then
    for _, session in ipairs(sessions) do
      if session.alive and type(session.name) == "string"
          and type(session.instance_id) == "string" and session.instance_id ~= "" then
        session_instances[session.name] = session.instance_id
      end
    end
  end
  -- Keep an exit marker through the gap before a member is relaunched. In
  -- particular, a Codex update reuses the same identity id, so losing this
  -- marker would make already-seen, still-unread mail look fully seeded.
  for alias, seeded in pairs(bus.unread_seeded) do
    if not bus.agents[alias] then
      if seeded ~= "exited" then
        bus.unread_seeded[alias] = "exited"
        bus.unread_seeded_exited_at[alias] = now
      else
        local since = bus.unread_seeded_exited_at[alias]
        if since == nil then
          bus.unread_seeded_exited_at[alias] = now
        elseif not session_instances[alias] and now - since >= 30 * 24 * 60 * 60 then
          bus.unread_seeded[alias] = nil
          bus.unread_seeded_exited_at[alias] = nil
        end
      end
    end
  end
  for alias, agent in pairs(bus.agents) do
    if agent then
      local instance = notice_session_instance(alias, agent, session_instances)
      local previous_instance = bus.unread_seeded[alias]
      local update = bus.codex_update_state
      local update_handoff = bus.codex_update_relaunches[alias]
        or update.owner == alias
        or (update.waiting and update.waiting[alias])
        or (update.restart_waiting and update.restart_waiting[alias])
      -- Check the policy only when unseeded: it captures the pane.
      -- A ready-looking prompt during a Codex update handoff belongs to the
      -- relaunch check. Seeding here can type over it after a task-poke timeout.
      -- A delegated task's startup probe owns the pane until the task clears.
      if previous_instance ~= instance and agent.id then
        local counted, unread = pcall(mail.unread, agent.id)
        if counted then
          if unread <= 0 then
            bus.unread_seeded[alias] = instance
            bus.unread_seeded_exited_at[alias] = nil
          elseif not bus.pending_tasks[alias] and not update_handoff
              and remuda._butler_notify_policy(alias, now) then
            local seeded, result = pcall(seed_unread_notices, alias, previous_instance, instance, unread)
            if seeded and result then
              bus.unread_seeded[alias] = instance
              bus.unread_seeded_exited_at[alias] = nil
            end
          end
        end
      end
    end
  end
  local sessions = {}
  for session in pairs(bus.notices) do sessions[#sessions + 1] = session end
  for _, session in ipairs(sessions) do
    local pending = bus.notices[session]
    if not bus.agents[session] then
      bus.notices[session] = nil
    elseif bus.notice_recoveries[session]
        or not pending or pending.due_at == nil or now >= pending.due_at then
      deliver_notice(session)
    end
  end
end
function remuda._butler_send(from, to, text)
  local _, recipient = mail_id(to, false)
  local sender = (from == "operator" or from == "outside") and mail_address(from)
    or mail_address(resolve(from))
  local envelope = { from = sender, to = mail_address(recipient.alias), text = text }
  local message = deliver_message(envelope)
  local notice = take_delivery_notice_result(message, recipient.alias)
  if not notice then
    notify_mail_delivery(envelope, message)
    notice = take_delivery_notice_result(message, recipient.alias)
  end
  if notice and notice.delivered then return "queued " .. message.id .. " and notified " .. recipient.alias end
  if notice and notice.error then
    return "queued " .. message.id .. " for " .. recipient.alias .. "; terminal delivery deferred: " .. tostring(notice.error)
  end
  return "queued " .. message.id .. " for " .. recipient.alias
    .. "; notice deferred: session " .. recipient.alias
    .. "; reason: waiting for the recipient's quiet delivery window"
end

remuda._butler_notice = {
  mail_notice_text = mail_notice_text,
  startup_action_safe = startup_action_safe,
  notice_recovery_error = notice_recovery_error,
}
