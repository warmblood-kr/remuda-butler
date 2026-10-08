-- Mail notices: the typing policy, notice recovery, deposit debounce and
-- delivery, and _butler_send. main.lua passes its locals in (the mail.lua
-- pattern) and binds startup_action_safe back.
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

-- #201: the Codex sandbox blocks the CLI, so a Codex member is pointed at the MCP tool first.
local function inbox_hint(kind)
  return kind == "codex" and "MCP butler_inbox (or remuda butler inbox)" or "remuda butler inbox"
end
local function mail_notice_text(message, detail, kind)
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
  local notice = "Butler message " .. message.id .. " " .. detail .. " arrived. Read it: " .. inbox_hint(kind)
  if type(message.matrix) == "table" then
    notice = notice .. ". Next: remuda butler reply " .. message.id
  end
  return notice
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
bus.notice_sent_at = bus.notice_sent_at or {}
bus.notice_reminder_at = bus.notice_reminder_at or {}
bus.notice_deferred_by_task = bus.notice_deferred_by_task or {}
local NOTICE_STABLE_SECONDS = 3
local NOTICE_QUIET_S = 2
local NOTICE_MAX_WAIT_S = 10
local NOTICE_RECOVERY_TIMEOUT_S = 20
local NOTICE_RETRY_DELAYS = { 20, 60, 300, 900 }
-- A pane that never passes the delivery policy while its composer reads empty is reported as a
-- failed attempt after this long, so the retry schedule and the sender's failure notice apply.
local NOTICE_STALL_S = 120
local NOTICE_REMINDER_SECONDS = 10 * 60
-- os.time is whole seconds: quiet is 1-2 s, plus up to 1 s for the notice tick.
local function notice_now()
  local clock = remuda._butler_notice_clock
  if type(clock) == "function" then return clock() end
  return os.time()
end
-- Debounce timers (remuda.after, core #375) only run the poll's delivery check
-- early: due_at stays the truth, and the `butler-notices` poll still delivers
-- on a core without timers. Handles: bus.notice_timers[session] = { quiet, cap }.
local function cancel_notice_timers(session)
  local pair = bus.notice_timers[session]
  bus.notice_timers[session] = nil
  for _, handle in pairs(pair or {}) do pcall(function() handle:cancel() end) end
end
-- A reload cancels the mod's timers, so no handle survives it.
bus.notice_timers = bus.notice_timers or {}
for session in pairs(bus.notice_timers) do cancel_notice_timers(session) end

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
  local startup = remuda._butler_agent_startup[kind] or {}
  if kind == "codex" then
    for _, placeholder in ipairs(startup.placeholders or {}) do
      if text == placeholder then return "EMPTY", text end
    end
  end
  local parts = { text }
  for index = prompt_at + 1, #lines do
    local rest = lines[index]:gsub("^%s+", "")
    if rest:sub(1, 3) == "╰" or rest:sub(1, 3) == "└" or rest:sub(1, 3) == "─" then break end
    if rest:match("^%? for shortcuts")
        or (kind == "codex" and (rest:lower():find("context left", 1, true)
        or rest:match("^⚠%s+%d+%s+warning") or rest:match("^[^%s]+%s+[^%s]+%s+·"))) then
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
  -- Do not gate on session.is_busy: it can reflect background agents while
  -- this pane's prompt is idle. Require a known empty composer below, and an
  -- attached human's idle pause above, before any notice is typed.
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
  -- Conservative: a Teach-title screen is ongoing deferral (detect-only, never answered), so
  -- notice typing waits for as long as the title is on screen, like any other known modal.
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

-- The composer decision the policy makes, for callers that hold a raw screen (first-task
-- delivery): the cursor row without dim ghost text when the core can say so (#137, #372).
function remuda._butler_composer_decision(kind, session, screen)
  local raw, raw_text = remuda._butler_prompt_is_empty(kind, screen)
  -- Only a NON-EMPTY raw read can be a ghost, and the styled row can only upgrade it to EMPTY.
  if raw == "NON-EMPTY" and remuda.capture_styled then
    local ok, styled = pcall(remuda.capture_styled, session)
    local row = ok and styled and styled.cursor and styled.rows and styled.rows[styled.cursor.row]
    if row then
      local parts, dim = {}, {}
      for _, span in ipairs(row) do
        local list = span.dim and dim or parts
        list[#list + 1] = span.text
      end
      local decision, text = remuda._butler_prompt_is_empty(kind, table.concat(parts))
      -- The raw text must be exactly the dim ghost: continuation rows below an empty first
      -- line are a human's draft.
      local ghost = table.concat(dim):gsub("\194\160", " "):match("^%s*(.-)%s*$")
      if decision == "EMPTY" and ghost == raw_text then return decision, text end
    end
  end
  return raw, raw_text
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
  if pending.count == 1 then return pending.text end
  local reshown
  for _, id in ipairs(pending.message_order or {}) do
    if pending.reshow and pending.reshow[id] then reshown = id end
  end
  if reshown then
    local rest = pending.count - 1
    return rest .. " new Butler message" .. (rest == 1 and "" or "s") .. " arrived, and "
      .. (pending.message_ids[reshown]:gsub(" Read it: .*$", ""))
      .. " Read them: remuda butler inbox; remuda butler inbox " .. reshown
  end
  return pending.count .. " new Butler messages arrived. Read them: " .. inbox_hint(pending.kind)
end
local notice_recovery_error
local function input_was_busy(ok, result, detail)
  local message = tostring(ok and (detail or result) or result or "")
  local first_line = message:match("^[^\r\n]*") or ""
  return first_line:match("a session input write is already in flight$") ~= nil
end
local function refresh_pending_notice(session, pending)
  if not pending.message_order then return pending end
  local agent = bus.agents[session]
  local identity = agent and agent.id
  local order, notices, message_times, reminders = {}, {}, {}, {}
  for _, id in ipairs(pending.message_order) do
    local notice = pending.message_ids and pending.message_ids[id]
    if notice and identity and ((pending.reshow and pending.reshow[id]) or mail.is_unread(identity, id)) then
      order[#order + 1], notices[id] = id, notice
      message_times[id] = pending.message_times and pending.message_times[id]
      reminders[id] = pending.reminders and pending.reminders[id]
    end
  end
  pending.message_order, pending.message_ids, pending.message_times = order, notices, message_times
  pending.reminders = reminders
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
    bus.notices[session], bus.notice_recoveries[session] = nil, nil
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
notice_recovery_error = function(session, state, reason)
  state.failed = true
  _butler_session_trace("notice_recovery_failed", "message_ids="
    .. table.concat(state.message_ids or {}, ",") .. " session=" .. session .. " reason=" .. reason
    .. " draft_bytes=" .. tostring(notice_byte_length(state.draft)))
  bus.notice_retry_reasons[session] = nil
  local pending = bus.notices[session]
  if pending and pending.message_order then
    state.message_ids = {}
    for _, id in ipairs(pending.message_order) do state.message_ids[#state.message_ids + 1] = id end
  end
  local attempts = pending and (pending.delivery_attempts or 0) or 0
  local delay = NOTICE_RETRY_DELAYS[attempts + 1]
  if pending and delay then
    pending.delivery_attempts = attempts + 1
    pending.last_delivery_error = reason
    pending.retry_at = notice_now() + delay
    pending.due_at = pending.retry_at
    bus.notice_recoveries[session] = nil
    _butler_session_trace("notice_retry_scheduled", "message_ids="
      .. table.concat(state.message_ids or {}, ",") .. " session=" .. session
      .. " attempt=" .. tostring(pending.delivery_attempts) .. " delay=" .. tostring(delay))
    return false
  end
  local alerts = bus.notice_failure_alerts[session] or {}
  bus.notice_failure_alerts[session] = alerts
  if pending and not alerts.exhausted then
    alerts.exhausted = true
    if session ~= "butler" then
      local by_sender = {}
      for _, id in ipairs(state.message_ids or {}) do
        local message = mail.find_message and mail.find_message(id)
        local sender = message and message.from
        local alias = sender and (sender.alias or sender.session)
        if sender and alias and alias ~= "butler" and alias ~= session then
          local target, target_id = alias, sender.id
          if not target_id or target_id == "" then
            -- CLI/Matrix senders may not have a Butler mailbox identity. Tell
            -- the recipient's leader so the undelivered notice is actionable.
            local recipient = bus.agents[session]
            target = recipient and recipient.parent or "butler"
            local leader = bus.agents[target]
            target_id = leader and leader.id
            if not target_id or target_id == "" then
              target, leader = "butler", bus.agents.butler
              target_id = leader and leader.id
            end
          end
          if target_id and target_id ~= "" then
            local group = by_sender[target] or { id = target_id, message_ids = {} }
            by_sender[target] = group
            group.message_ids[#group.message_ids + 1] = id
          end
        end
      end
      for alias, group in pairs(by_sender) do
        local new_ids = {}
        -- Loading the sender's delivered set includes read messages. The
        -- marker in Butler's sent mail is the durable once-only record.
        if mail.unread then pcall(mail.unread, group.id) end
        local delivered_messages = bus.mail_delivered and bus.mail_delivered[group.id] or {}
        for _, id in ipairs(group.message_ids) do
          local already_notified = false
          for delivered_id in pairs(delivered_messages) do
            local prior = mail.find_message and mail.find_message(delivered_id)
            local object = prior and prior.body and bus.objects and bus.objects[prior.body.object_id]
            local marker = "[butler-notice-failure:" .. id .. "]"
            if prior and prior.from and prior.from.alias == "butler" and object
                and tostring(object.content):find(marker, 1, true) then
              already_notified = true
              break
            end
          end
          if not already_notified then new_ids[#new_ids + 1] = id end
        end
        if #new_ids > 0 then
          local quoted_session = tostring(session):gsub("\\", "\\\\"):gsub('"', '\\"')
          local command = 'remuda butler send "' .. quoted_session .. '" "read your inbox"'
          local markers = {}
          for _, id in ipairs(new_ids) do markers[#markers + 1] = "[butler-notice-failure:" .. id .. "]" end
          pcall(remuda._butler_send, "butler", alias,
            "Could not safely deliver queued Butler mail to " .. session .. " after "
            .. tostring(attempts + 1) .. " attempts (last error: " .. reason
            .. "). Inspect its composer, then run `" .. command .. "` to ask it to read its inbox. Message IDs: "
            .. table.concat(new_ids, ",") .. ". " .. table.concat(markers, " "))
        end
      end
    end
  end
  clear_notice_fallbacks(session, state.message_ids)
  bus.notices[session] = nil
  bus.notice_recoveries[session] = nil
  return false
end
local function complete_notice_recovery(session, state)
  local pending = bus.notices[session]
  local agent = bus.agents[session]
  if agent and agent.id then
    local sent_at = bus.notice_sent_at[agent.id] or {}
    bus.notice_sent_at[agent.id] = sent_at
    for _, id in ipairs(state.message_ids or {}) do sent_at[id] = notice_now() end
    bus.notice_reminder_at[session] = notice_now() + NOTICE_REMINDER_SECONDS
  end
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
      pending.delivery_attempts, pending.retry_at = 0, nil
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
local function defer_notice_busy(session)
  bus.notice_recoveries[session] = nil
  local pending = bus.notices[session]
  if pending then pending.due_at = notice_now() + 1 end
  return false, "busy"
end
local function begin_notice_submit(session, state)
  local pending = bus.notices[session]
  if not pending then bus.notice_recoveries[session] = nil; return true end
  if not remuda._butler_notify_policy(session) then
    bus.notice_recoveries[session] = nil
    return false
  end
  state.draft = nil
  state.count = pending.count
  state.message_ids = {}
  for _, id in ipairs(pending.message_order or {}) do state.message_ids[#state.message_ids + 1] = id end
  state.notice = pending_notice_text(pending)
  bus.notice_recoveries[session] = state
  local typed, result, why = pcall(remuda.type_text, session, state.notice, 0.1)
  if input_was_busy(typed, result, why) then
    return defer_notice_busy(session)
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
    return begin_notice_submit(session, state)
  end
  if state.phase == "probe" then
    if state.last_screen == normalized then state.stable = (state.stable or 0) + 1
    else state.last_screen, state.stable = normalized, 1 end
    if state.stable < 2 then return false end
    if decision == "EMPTY" then
      bus.notice_recoveries[session] = nil
      return begin_notice_submit(session, state)
    end
    -- An unrecognized or non-empty composer may be a human draft. Leave it
    -- untouched and let this attempt time out into the scheduled retry.
    state.draft = decision == "NON-EMPTY" and text or ""
    return false
  elseif state.phase == "redrawn" then
    if decision == "EMPTY" then
      return begin_notice_submit(session, state)
    end
    return notice_recovery_error(session, state, "legacy recovery state left the composer untouched")
  elseif state.phase == "verify_clear" then
    return notice_recovery_error(session, state, "legacy clear state left the composer untouched")
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
    pending.stalled_at = nil
    if (tonumber(pending.delivery_attempts) or 0) > 0 then
      local screen, decision = recovery_screen(session)
      if not screen or decision ~= "EMPTY" then
        local state = { phase = "probe", count = pending.count, started_at = notice_now() }
        state.message_ids = {}
        for _, id in ipairs(pending.message_order or {}) do state.message_ids[#state.message_ids + 1] = id end
        return notice_recovery_error(session, state,
          "composer was not empty after a failed notice write")
      end
    end
    local state = { phase = "verify_notice", count = pending.count, notice = pending_notice_text(pending), checks = 0,
      started_at = notice_now() }
    state.message_ids = {}
    for _, id in ipairs(pending.message_order or {}) do state.message_ids[#state.message_ids + 1] = id end
    local typed, result, why = pcall(remuda.type_text, session, state.notice, 0.1)
    if input_was_busy(typed, result, why) then
      return defer_notice_busy(session)
    end
    if not typed or result == false then
      bus.notice_recoveries[session] = state
      return notice_recovery_error(session, state, tostring(why or result or "the notice could not be typed"))
    end
    bus.notice_recoveries[session] = state
    return false
  end
  local screen, decision = recovery_screen(session)
  if not screen or decision == "EMPTY" then
    pending.stalled_at = pending.stalled_at or notice_now()
    if notice_now() - pending.stalled_at < NOTICE_STALL_S then return false end
    pending.stalled_at = nil
    local stalled = { phase = "probe", count = pending.count, started_at = notice_now(), message_ids = {} }
    return notice_recovery_error(session, stalled, "the pane did not become ready for a notice within "
      .. tostring(NOTICE_STALL_S) .. " seconds")
  end
  pending.stalled_at = nil
  local state = { phase = "probe", count = pending.count, checks = 0, started_at = notice_now() }
  state.message_ids = {}
  for _, id in ipairs(pending.message_order or {}) do state.message_ids[#state.message_ids + 1] = id end
  bus.notice_recoveries[session] = state
  return tick_notice_recovery(session, state)
end
-- The poll and the debounce timers share this check.
local function deliver_due_notice(session, now)
  local pending = bus.notices[session]
  if not bus.agents[session] then
    cancel_notice_timers(session)
    bus.notices[session] = nil
  elseif bus.notice_recoveries[session]
      or not pending or pending.due_at == nil or now >= pending.due_at then
    cancel_notice_timers(session)
    if pending and pending.retry_at and now >= pending.retry_at then pending.retry_at = nil end
    deliver_notice(session)
  end
end
local function arm_notice_timer(session, slot, seconds)
  local after = remuda._butler_notice_after or remuda.after
  if type(after) ~= "function" then return end
  local pair = bus.notice_timers[session] or {}
  if pair[slot] then pcall(function() pair[slot]:cancel() end) end
  local handle
  local ok, armed = pcall(after, seconds, function()
    local current = bus.notice_timers[session]
    -- A cancelled or replaced handle may still fire: it does nothing.
    if not current or current[slot] ~= handle then return end
    current[slot] = nil
    deliver_due_notice(session, notice_now())
  end)
  handle = ok and armed or nil
  pair[slot] = handle
  bus.notice_timers[session] = pair
end
function remuda._butler_notify(alias, notice, message_id, reshow, reminder)
  local _, recipient = mail_id(alias, false)
  if message_id and not reshow and not mail.is_unread(recipient.id, message_id) then return true end
  local now = notice_now()
  if message_id and not reshow then
    local seen = bus.notice_seen[recipient.id] or {}
    bus.notice_seen[recipient.id] = seen
    if seen[message_id] then return false end
    seen[message_id] = true
  end
  local pending = bus.notices[alias]
  if not pending then bus.notice_failure_alerts[alias] = nil end
  pending = pending or { count = 0 }
  bus.notice_retry_reasons[alias] = nil
  if message_id then
    pending.message_ids = pending.message_ids or {}
    pending.message_order = pending.message_order or {}
    if pending.message_ids[message_id] then return false end
    -- Start the unread reminder clock when a notice enters the queue. A
    -- delivery can exhaust its retries and discard this queue before
    -- complete_notice_recovery records a verified delivery time.
    local agent = bus.agents[alias]
    local recipient_id = agent and agent.id or recipient.id
    local sent_at = bus.notice_sent_at[recipient_id] or {}
    bus.notice_sent_at[recipient_id] = sent_at
    sent_at[message_id] = now
    pending.message_ids[message_id] = notice
    if reminder then
      pending.reminders = pending.reminders or {}
      pending.reminders[message_id] = true
    elseif reshow then
      pending.reshow = pending.reshow or {}
      pending.reshow[message_id] = true
    end
    pending.message_order[#pending.message_order + 1] = message_id
    pending.message_times = pending.message_times or {}
    pending.message_times[message_id] = now
  end
  local first = pending.first_at == nil
  pending.first_at = pending.first_at or now
  pending.last_at = now
  pending.due_at = math.min(now + NOTICE_QUIET_S, pending.first_at + NOTICE_MAX_WAIT_S)
  if pending.retry_at then pending.due_at = math.max(pending.due_at, pending.retry_at) end
  pending.count, pending.text, pending.kind = pending.count + 1, notice, recipient.kind
  bus.notices[alias] = pending
  if first then
    cancel_notice_timers(alias)
    arm_notice_timer(alias, "cap", NOTICE_MAX_WAIT_S)
  end
  arm_notice_timer(alias, "quiet", NOTICE_QUIET_S)
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
      if previous_instance ~= nil and previous_instance ~= "launched" and previous_instance ~= instance
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
        remuda._butler_notify(alias, mail_notice_text(message, detail, agent.kind), message_id)
      end
    end
  end
  return true
end
local function remind_unread_notices(alias, agent, now)
  if not agent.id or bus.pending_tasks[alias] then return end
  local due = bus.notice_reminder_at[alias]
  if due and now < due then return end
  bus.notice_reminder_at[alias] = now + NOTICE_REMINDER_SECONDS
  local sent_at = bus.notice_sent_at[agent.id]
  if not sent_at then return end
  local has_sent = false
  for message_id, last_sent in pairs(sent_at) do
    if mail.is_unread(agent.id, message_id) then
      has_sent = true
      if now - (tonumber(last_sent) or now) >= NOTICE_REMINDER_SECONDS then
        local message = mail.find_message(message_id) or { id = message_id }
        message.id = message.id or message_id
        remuda._butler_notify(alias, mail_notice_text(message, nil, agent.kind), message_id, true, true)
      end
    else
      sent_at[message_id] = nil
    end
  end
  if not has_sent then
    bus.notice_sent_at[agent.id] = nil
    bus.notice_reminder_at[alias] = nil
  end
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
-- After a compaction or a restart a member may have lost a leader message it
-- already read (the inbox then reads empty). Re-show the newest leader message
-- it never answered, the Welcome aside; unread mail replays through the seed.
-- ponytail: scans the delivered set and bus.messages; index them if members
-- accumulate thousands of messages.
local function last_unanswered_leader_message(alias, agent)
  local leader_alias = agent.parent or "butler"
  local leader = leader_alias ~= alias and bus.agents[leader_alias]
  if not leader or not leader.id then return nil end
  mail.unread(agent.id) -- loads the delivered set
  local newest
  for id in pairs(bus.mail_delivered[agent.id] or {}) do
    local message = mail.find_message(id)
    if message and message.from and message.from.id == leader.id
        and message.subject ~= "Welcome to Butler" and (not newest or id > newest.id) then
      newest = message
    end
  end
  if not newest or mail.is_unread(agent.id, newest.id) then return nil end
  -- Answered: a later message from the member in the leader's inbox log,
  -- which is durable (bus.messages starts empty after a daemon restart).
  mail.unread(leader.id) -- loads the leader's delivered set
  for id in pairs(bus.mail_delivered[leader.id] or {}) do
    if id > newest.id then
      local message = mail.find_message(id)
      if message and message.from and message.from.id == agent.id then return nil end
    end
  end
  return newest
end
local function reshow_leader_message(alias, message, why)
  local sender = message.from.alias or message.from.session or "your leader"
  remuda._butler_notify(alias, "Butler message " .. message.id .. " from " .. sender .. " re-shown after "
    .. why .. ". Read it: remuda butler inbox " .. message.id, message.id, true)
end
-- The one hook for any compaction (Butler's own, or the half-drop heuristic
-- below for the agent's auto-compact): the next tick re-seeds this member.
function remuda._butler_notice_compacted(alias)
  if bus.agents[alias] then bus.unread_seeded[alias] = "compacted" end
end
-- Half-drop heuristic for an agent's own compaction. A missing sample, the
-- first sample of a fresh instance, and samples during Butler's compaction
-- only set the baseline; it fires once per drop and re-arms when the context
-- rises again. A /clear that trips it costs one notice.
bus.context_samples = bus.context_samples or {}
local function note_context_drop(alias, agent, instance)
  local ok, telemetry = pcall(remuda._butler_telemetry_for, agent)
  local used = ok and type(telemetry) == "table" and tonumber(telemetry.context_used) or nil
  local sample = bus.context_samples[alias]
  if not sample or sample.instance ~= instance then
    bus.context_samples[alias] = { instance = instance, used = used, armed = true }
    return
  end
  local prior = sample.used
  sample.used = used
  if not used or not prior then return end
  local members = remuda._butler_compaction_members_state or {}
  if (members[agent.id] or {}).compaction_in_progress then sample.armed = false; return end
  if used > prior then sample.armed = true; return end
  if sample.armed and used < prior / 2 then
    sample.armed = false
    remuda._butler_notice_compacted(alias)
  end
end
function remuda._butler_deliver_notices()
  local now = notice_now()
  local session_instances = {}
  local live_sessions = {}
  local listed, sessions = pcall(remuda.ls)
  if listed and type(sessions) == "table" then
    for _, session in ipairs(sessions) do
      if session.alive and type(session.name) == "string" then
        live_sessions[session.name] = true
        if type(session.instance_id) == "string" and session.instance_id ~= "" then
          session_instances[session.name] = session.instance_id
        end
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
        elseif not live_sessions[alias] and now - since >= 30 * 24 * 60 * 60 then
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
      if agent.id then note_context_drop(alias, agent, instance) end
      if bus.pending_tasks[alias] then
        bus.notice_deferred_by_task[alias] = true
      elseif bus.notice_deferred_by_task[alias] then
        -- A task may have held unread mail out of the first prompt after the
        -- instance was already marked seeded (including an empty inbox).
        bus.notice_deferred_by_task[alias] = nil
        bus.unread_seeded[alias] = nil
      end
      previous_instance = bus.unread_seeded[alias]
      if previous_instance ~= instance and agent.id then
        local counted, unread = pcall(mail.unread, agent.id)
        local found, leader_message = false, nil
        -- A new member's first sight re-shows nothing: a brief it read while
        -- unseeded is not lost. nil (a daemon restart) still re-shows.
        if counted and live_sessions[alias] and previous_instance ~= "launched" then
          found, leader_message = pcall(last_unanswered_leader_message, alias, agent)
        end
        if not found then leader_message = nil end
        if counted then
          if unread <= 0 and not leader_message then
            bus.unread_seeded[alias] = instance
            bus.unread_seeded_exited_at[alias] = nil
          elseif not bus.pending_tasks[alias] and not update_handoff
              and remuda._butler_notify_policy(alias, now) then
            local seeded, result = pcall(seed_unread_notices, alias, previous_instance, instance, unread)
            if seeded and result then
              if leader_message then
                reshow_leader_message(alias, leader_message,
                  previous_instance == "compacted" and "compaction" or "restart")
              end
              bus.unread_seeded[alias] = instance
              bus.unread_seeded_exited_at[alias] = nil
            end
          end
        end
      end
      if not update_handoff then remind_unread_notices(alias, agent, now) end
    end
  end
  local sessions = {}
  for session in pairs(bus.notices) do sessions[#sessions + 1] = session end
  for _, session in ipairs(sessions) do deliver_due_notice(session, now) end
end
-- `inbox <message-id>`: print one message delivered to the caller again,
-- read or not, without changing read state (the owner check of reply).
function remuda._butler_inbox_message(caller, id)
  local owner = mail_id(caller, true)
  mail.unread(owner) -- loads the delivered set
  local message = (bus.mail_delivered[owner] or {})[id] and mail.find_message(id)
  local object = message and message.body and bus.objects[message.body.object_id]
  if not object then
    error("message " .. tostring(id) .. " was not delivered to you. Next: remuda butler inbox", 0)
  end
  local output = "[" .. message.id .. " from " .. tostring(message.from.host) .. "/" .. tostring(message.from.session)
    .. " · " .. tostring(message.created_at) .. "] " .. tostring(message.subject) .. "\n"
  local matrix_line = mail.matrix_header(message)
  if matrix_line ~= "" then output = output .. matrix_line .. "\n" .. mail.matrix_body_mark .. "\n" end
  return output .. object.content
end
local function send_envelope(envelope, recipient)
  local message = deliver_message(envelope)
  local notice = take_delivery_notice_result(message, recipient.alias)
  if not notice then
    notify_mail_delivery(envelope, message)
    notice = take_delivery_notice_result(message, recipient.alias)
  end
  if notice and notice.delivered then return "queued " .. message.id .. " and notified " .. recipient.alias, message.id end
  if notice and notice.error then
    return "queued " .. message.id .. " for " .. recipient.alias .. "; terminal delivery deferred: " .. tostring(notice.error),
      message.id
  end
  return "queued " .. message.id .. " for " .. recipient.alias
    .. "; notice deferred: session " .. recipient.alias
    .. "; reason: waiting for the recipient's quiet delivery window", message.id
end
function remuda._butler_send(from, to, text)
  local _, recipient = mail_id(to, false)
  local sender = (from == "operator" or from == "outside") and mail_address(from)
    or mail_address(resolve(from))
  return (send_envelope({ from = sender, to = mail_address(recipient.alias), text = text }, recipient))
end
-- Mail from the reserved sender `schedule`. The sender is fixed here and the
-- send function is an upvalue of the tick's env, never a `remuda` field.
-- `_butler_send` resolves a sender to a live session, and valid_child_name keeps
-- any session from taking the name `schedule`.
local SCHEDULE_SENDER = { host = "local", id = "", alias = "schedule", session = "schedule", kind = "", leader = "" }
local function schedule_send(to, text, subject)
  local _, recipient = mail_id(to, false)
  return send_envelope({ from = SCHEDULE_SENDER, to = mail_address(recipient.alias), text = text,
    subject = subject }, recipient)
end
-- The tick's env borrows the seams of remuda._butler_schedule_env (main.lua) and
-- adds `send`, which that table does not carry.
local tick_env = setmetatable({ send = schedule_send },
  { __index = function(_, key) return remuda._butler_schedule_env[key] end })
function remuda._butler_schedule_tick()
  local ok, err = pcall(remuda.butler.schedule.tick, tick_env)
  if not ok then remuda._butler_schedule_env.trace("schedule_tick_error", tostring(err)) end
end

remuda._butler_notice = {
  mail_notice_text = mail_notice_text,
  startup_action_safe = startup_action_safe,
  notice_recovery_error = notice_recovery_error,
  deliver_notice = deliver_notice,
}
