-- Mail notices: the typing policy, notice recovery, deposit debounce and
-- delivery, and _butler_send. main.lua passes its locals in (the mail.lua
-- pattern) and binds startup_action_safe back.

-- Diagnostics are observational: unavailable/broken recording cannot affect mail or control.
local function diagnostic(outcome, reason, correlation)
  local diagnostics = remuda._butler_diagnostics
  if diagnostics and type(diagnostics.record) == "function" then
    pcall(diagnostics.record, "notice", outcome, reason, correlation)
  end
end
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
-- The originating module identity, captured at load. Never read
-- remuda._butler_notice when deciding whether an attempt is still current.
local NOTICE_MODULE = {}

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
bus.notice_uncertain_alerts = bus.notice_uncertain_alerts or {}
bus.notice_journal_alerts = bus.notice_journal_alerts or {}
bus.notice_journal_failure_alerts = bus.notice_journal_failure_alerts or {}
bus.notice_native_alerts = bus.notice_native_alerts or {}
bus.notice_native_dispatching = bus.notice_native_dispatching or {}
-- Durable-for-this-image uncertainty tombstones: recipient identity id ->
-- message id. They outlive the report/stuck record and are never cleared by
-- reads or reminders, so a compaction re-show or a preserved-bus reload cannot
-- blindly resend bytes that may already have landed. A daemon restart clears
-- this in-memory map (documented at-least-once behavior).
bus.notice_uncertain = bus.notice_uncertain or {}
bus.notice_sent_at = bus.notice_sent_at or {}
bus.notice_reminder_at = bus.notice_reminder_at or {}
-- session -> { ids, since, reason, reported_at }: mail whose notice ran out of retries.
bus.notice_stuck = bus.notice_stuck or {}
bus.notice_deferred_by_task = bus.notice_deferred_by_task or {}
-- Human-pause/startup stability only (owner lines, first task, startup actions).
-- Notice delivery no longer consults the screen at all.
local NOTICE_STABLE_SECONDS = 3
local NOTICE_QUIET_S = 2
local NOTICE_MAX_WAIT_S = 10
-- Bounded retry for an explicit refusal that wrote nothing ("not typed", gone).
local NOTICE_RETRY_DELAYS = { 20, 60, 300, 900 }
local NOTICE_REMINDER_SECONDS = 10 * 60
local NOTICE_STUCK_REPORT_SECONDS = 60 * 60
local NOTICE_BUSY_CAP_S = 15 * 60
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
  local startup = remuda._butler_agent_startup[kind] or {}
  if kind == "opencode" then
    -- OpenCode's parser is mandatory: a missing or failing parser must not fall
    -- through to the generic glyph grammar (history/typed text could read EMPTY).
    if type(startup.empty) ~= "function" then return "UNPARSEABLE", "" end
    local ok, decision, value = pcall(startup.empty, screen)
    if ok and (decision == "EMPTY" or decision == "NON-EMPTY" or decision == "UNPARSEABLE") then
      return decision, value or ""
    end
    return "UNPARSEABLE", ""
  end
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

-- Heuristic for a screen with no composer glyph that is really a dialog:
-- numbered choices or a confirm/cancel hint. Not exhaustive; unlisted dialogs
-- are the residual risk of admitting UNPARSEABLE on an idle client.
local function looks_like_dialog(screen)
  local lower = screen:lower()
  for _, marker in ipairs({ "(y/n)", "[y/n]", "esc to cancel", "enter to confirm", "press enter",
      "do you want", "do you trust", "allow " }) do
    if lower:find(marker, 1, true) then return true end
  end
  return ("\n" .. screen):find("\n%s*[❯›>]?%s*%d+[%.%)]%s") ~= nil
end

-- A Claude transcript row: assistant output, tool result, or turn footer.
local function claude_transcript_row(line)
  local rest = line:gsub("^[%s\194\160]+", "")
  return rest:sub(1, 3) == "⏺" or rest:sub(1, 3) == "✻" or rest:sub(1, 3) == "⎿"
end
-- The startup-modal matcher counts modal text anywhere on screen. For notices, a Claude
-- modal whose last match is followed by transcript rows is a quote in the conversation
-- (e.g. a report about members stuck on the Teach modal), not a live modal: a live one
-- is painted below the transcript. Without this, quoting the title blocks every notice.
local function live_startup_modal(kind, screen)
  local startup = remuda._butler_agent_startup[kind] or {}
  if not known_startup_modal(startup, screen) then return false end
  if kind ~= "claude" then return true end
  local lines = {}
  for line in (tostring(screen):gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  -- Start of the last match: the shortest suffix that still matches.
  local start = 1
  for index = #lines, 1, -1 do
    if known_startup_modal(startup, table.concat(lines, "\n", index)) then start = index; break end
  end
  for index = start + 1, #lines do
    if claude_transcript_row(lines[index]) then return false end
  end
  return true
end

-- Notice admission preserves the live-session and human-pause guards. An
-- explicitly idle client may receive input into an EMPTY or UNPARSEABLE
-- composer; a parseable NON-EMPTY draft, a dialog-looking screen or a failed
-- capture is refused, since type_text inserts at the cursor. Busy clients still require EMPTY.
function remuda._butler_notify_policy(session, now)
  now = now or os.time()
  local row
  for _, candidate in ipairs(remuda.ls()) do
    if candidate.name == session then row = candidate end
  end
  if not row or not row.alive then return false end
  local attached = row.attached
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
  -- Use the shared exception classifier before either admission path. Its
  -- session identity, current-instance, audit and modal restrictions still apply.
  local dialogs = remuda.butler and remuda.butler.dialogs
  if dialogs and type(dialogs.check) == "function" then
    local checked, allowed = pcall(dialogs.check, session)
    if not checked or not allowed then return false end
  end
  local idle = false
  if type(remuda.session) == "function" then
    local checked, state = pcall(remuda.session, session)
    idle = checked and type(state) == "table" and state.is_busy == false
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
  -- An unseen composer may hold a draft: fail closed on a malformed capture.
  if type(full_screen) ~= "string" then return false end
  prompt_screen = prompt_screen or full_screen
  local agent = bus.agents[session]
  local kind = agent and agent.kind or ""
  -- Conservative: a Teach-title screen is ongoing deferral (detect-only, never answered), so
  -- notice typing waits for as long as the modal is on screen, like any other known modal.
  if live_startup_modal(kind, full_screen) then
    _butler_session_trace("notice_deferred_modal", session .. " " .. kind)
    return false
  end
  -- OpenCode's composer spans continuation rows; its parser must see the full
  -- screen, not just a styled cursor row that may sit on the placeholder.
  local policy_screen = kind == "opencode" and full_screen or prompt_screen
  local decision, text = remuda._butler_prompt_is_empty(kind, policy_screen)
  -- During a fresh redraw the cursor may still sit on a footer or banner.
  -- A cursor row with no composer glyph supplies no input evidence: use the
  -- full parser only when it independently identifies an empty composer.
  if decision == "UNPARSEABLE" and policy_screen ~= full_screen then
    local full_decision, full_text = remuda._butler_prompt_is_empty(kind, full_screen)
    if full_decision == "EMPTY" then decision, text = full_decision, full_text end
  end
  -- An explicitly idle client also admits UNPARSEABLE, except where the cursor
  -- row says it is off the prompt (styled core) or the screen looks like a dialog.
  -- OpenCode fails closed: no composer evidence must never admit typing.
  local admit_unparseable = idle and policy_screen == full_screen and not looks_like_dialog(full_screen)
  if kind == "opencode" then admit_unparseable = false end
  if decision == "UNPARSEABLE" and idle and not admit_unparseable then decision = "DIALOG" end
  if seen.decision ~= decision then -- once per change, not every retry
    seen.decision = decision
    if decision ~= "EMPTY" and not (decision == "UNPARSEABLE" and admit_unparseable) then
      diagnostic("deferred", "prompt_policy", session)
    end
    _butler_session_trace("notice_prompt", "message_ids="
      .. table.concat(bus.notices[session] and bus.notices[session].message_order or {}, ",")
      .. " session=" .. session .. " kind=" .. kind .. " decision=" .. decision
      .. " composer_bytes=" .. tostring(#text) .. (idle and " idle=true" or ""))
  end
  return decision == "EMPTY" or (decision == "UNPARSEABLE" and admit_unparseable)
end

-- The composer decision the policy makes, for callers that hold a raw screen (first-task
-- delivery): the cursor row without dim ghost text when the core can say so (#137, #372).
-- OpenCode is excluded: its composer can span continuation rows, so a cursor-only row
-- cannot override the full-screen parser.
function remuda._butler_composer_decision(kind, session, screen)
  local raw, raw_text = remuda._butler_prompt_is_empty(kind, screen)
  -- Only a NON-EMPTY raw read can be a ghost, and the styled row can only upgrade it to EMPTY.
  if raw == "NON-EMPTY" and remuda.capture_styled and kind ~= "opencode" then
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

-- Owner-approved exact text has its own admission policy. Rendering uncertainty
-- allows input; only positive draft/human/modal evidence blocks it. Recent output
-- is not a turn signal and never establishes that a composer cannot receive input.
-- Menu rows can share a prompt glyph with drafts. Establish evidence around
-- the LAST prompt, so historical menus/borders cannot erase a current draft.
local function current_composer_evidence(kind, screen)
  local lines, prompt_at = {}, nil
  for line in (screen .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
    local rest = line:gsub("^%s+", ""):gsub("^│%s*", "")
    for _, glyph in ipairs(PROMPT_GLYPHS) do
      if rest:sub(1, #glyph) == glyph then prompt_at = #lines; break end
    end
  end
  if not prompt_at then return false, false end
  local option_start, preceding_options = prompt_at, 0
  local selected_row = lines[prompt_at]:gsub("^%s+", ""):gsub("^│%s*", "")
  for _, glyph in ipairs(PROMPT_GLYPHS) do
    if selected_row:sub(1, #glyph) == glyph then
      selected_row = selected_row:sub(#glyph + 1):gsub("^%s+", "")
      break
    end
  end
  if selected_row:match("^%d+[%.)]%s*%S") then
    for i = prompt_at - 1, 1, -1 do
      local rest = lines[i]:gsub("^%s+", ""):gsub("^│%s*", "")
      if not rest:match("^%d+[%.)]%s*%S") then break end
      preceding_options, option_start = preceding_options + 1, i
    end
  end
  local before = (lines[option_start - 1] or ""):gsub("^%s+", "")
  local top = before:match("^─")
  local boxed = false
  for i = option_start - 1, 1, -1 do
    local rest = lines[i]:gsub("^%s+", "")
    local first = rest:sub(1, 3)
    if first == "╭" or first == "┌" or first == "╔" then boxed = true; break end
    if first ~= "│" then break end
  end
  local bounded, closed_box, options, selected_option = false, false, preceding_options, false
  for i = prompt_at, #lines do
    local rest = lines[i]:gsub("^%s+", ""):gsub("^│%s*", ""):gsub("│%s*$", "")
    local selected = false
    for _, glyph in ipairs(PROMPT_GLYPHS) do
      if rest:sub(1, #glyph) == glyph then
        selected = true
        rest = rest:sub(#glyph + 1):gsub("^%s+", "")
        break
      end
    end
    if rest:match("^%d+[%.)]%s*%S") then
      options = options + 1
      if selected then selected_option = true end
    end
    if rest:match("^%? for shortcuts")
        or (kind == "codex" and rest:lower():find("context left", 1, true))
        or (kind == "claude" and (rest:find("auto mode on", 1, true)
          or rest:find("shift+tab to cycle", 1, true))) then bounded = true end
    local first = rest:sub(1, 3)
    if first == "╰" or first == "└" or first == "╚" then closed_box = true end
    if i > prompt_at and (rest:match("^─") or closed_box) and top then bounded = true end
  end
  -- Scan the full current region, not compaction's last-eight-line window.
  -- A lone numbered prefix is insufficient; an enclosing generic box or a
  -- selected row plus another numbered option supplies menu uncertainty.
  return bounded, (boxed and closed_box) or (selected_option and options >= 2)
end

function remuda._butler_approved_text_policy(session, now, owned_composer)
  local agent = bus.agents[session]
  if not agent then
    for _, candidate in pairs(bus.agents) do
      if candidate.session_name == session then agent = candidate; break end
    end
  end
  local kind = agent and agent.kind or ""
  local lifecycle = remuda._butler_state or remuda._butler_compaction_state or {}
  if agent and lifecycle.compaction_fleet_active == (agent.id or agent.session_name) then
    return false, "workflow_owned"
  end
  local row
  for _, candidate in ipairs(remuda.ls()) do
    if candidate.name == session then row = candidate end
  end
  if not row or not row.alive then return false, "session_not_live" end
  if row.attached and type(row.human_idle) == "number"
      and row.human_idle < (remuda._butler_notice_human_idle or 10) then
    return false, "human_active"
  end
  if row.attached and row.human_idle == nil then
    -- Legacy core has no human-input clock. Preserve its independent pause
    -- guard, without calling an unknown composer busy.
    now = now or os.time()
    local captured, screen = pcall(remuda.capture, session)
    if not captured or type(screen) ~= "string" then return false, "human_pause_pending" end
    local seen = bus.notice_screens[session] or {}
    bus.notice_screens[session] = seen
    if seen.approved_screen ~= screen then
      seen.approved_screen, seen.approved_since = screen, now
      return false, "human_pause_pending"
    end
    if now - seen.approved_since < NOTICE_STABLE_SECONDS then return false, "human_pause_pending" end
  end
  local dialogs = remuda.butler and remuda.butler.dialogs
  if not dialogs or type(dialogs.check) ~= "function" then return false, "input_policy_unavailable" end
  local allowed, state = dialogs.check(session)
  if not allowed then
    local reason = state and state.id
    if reason == "session_unavailable" or reason == "session_replaced" then return false, reason end
    return false, "known_modal"
  end
  local captured, screen = pcall(remuda.capture, session)
  if not captured or type(screen) ~= "string" then
    -- OpenCode fails closed when its composer cannot be read; owner-approved
    -- text may still proceed on other kinds' renderer-unknown path.
    if kind == "opencode" then return false, "renderer_unknown" end
    return true, "renderer_unknown"
  end
  local startup = remuda._butler_agent_startup[kind] or {}
  if startup.picker and startup.picker(screen) then return false, "known_modal" end
  local parsed, decision, text = pcall(remuda._butler_composer_decision, kind, session, screen)
  if parsed and decision == "NON-EMPTY" then
    -- Only the internal post-write Return stage supplies this proof. Keep all
    -- independent human/workflow/modal guards above; never match history text.
    if type(owned_composer) == 'function' and owned_composer(text) == true then
      return true, 'owned_composer'
    end
    local bounded, menu_like = current_composer_evidence(kind, screen)
    if kind ~= "opencode" and menu_like and not bounded then
      return true, "renderer_unknown"
    end
    return false, "composer_nonempty"
  end
  if kind == "opencode" then
    -- Unknown/error never admits OpenCode input; only a parsed empty composer
    -- (or the exact owned NON-EMPTY above) does.
    if parsed and decision == "EMPTY" then return true, "composer_empty" end
    return false, "renderer_unknown"
  end
  return true, parsed and decision == "EMPTY" and "composer_empty" or "renderer_unknown"
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
-- Automatic mailbox wakeups: one atomic core send; see deliver_notice below.
local notice_recovery_error, notice_delivery_uncertain
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
-- Automatic mailbox wakeups use one ordinary atomic core `remuda.send` (text
-- and Return in a single burst) through the dialogs module's narrow
-- `automatic_notice_send` capability. The old empty-composer/modal/idle
-- predictions, probe, 20-second recovery and extra Return are gone (owner
-- decisions 2026-11-03 and 2026-11-05). Attachment, busy state and composer
-- contents are not admission gates; the capability keeps a live-session and
-- bound-instance preflight, its own audit and the agent/generation recheck;
-- it bypasses only the modal *prediction* gate, and only for generated notice
-- text. A core accept means the write path returned; it never means the agent
-- read the mail. Only an inbox read drains mail. Known residual race: the core
-- send word is name-addressed, so a human attaching, or a name being reused,
-- between the preflight and the write is not excluded atomically.
local function first_line(value)
  local line = tostring(value or ""):match("^[^\r\n]*") or ""
  return line:gsub("[\r\n]+", " "):gsub("%s+$", "")
end
local function notice_byte_length(value)
  return #tostring(value or "")
end
-- One trace line per deferral transition, like the old prompt-NON-EMPTY line.
local function trace_notice_defer(session, pending, kind)
  if bus.notice_retry_reasons[session] == kind then return end
  bus.notice_retry_reasons[session] = kind
  _butler_session_trace("notice_retry", "message_ids="
    .. table.concat(pending and pending.message_order or {}, ",")
    .. " session=" .. session .. " reason=" .. tostring(kind))
end

-- `remuda.send` raises; its message is the only outcome channel. A refusal
-- that wrote nothing may be retried on the bounded schedule. Anything that may
-- have put bytes in the pane is uncertain: report the IDs and never resend
-- blindly, because a second copy could follow a delivery that did land.
-- Order matters. Detail is checked before the generic `send_refused:` prefix,
-- because a legacy false result may carry a late/partial/unconfirmed/busy
-- reason that says nothing was written (safe) or may have been (uncertain).
local NOTICE_SEND_OUTCOMES = {
  -- Core refusals that wrote nothing.
  { kind = "busy", pattern = "session input is busy" },
  { kind = "busy", pattern = "session input write is already in flight" },
  { kind = "busy", pattern = "a session input write is already in flight" },
  -- Core transport limitation, not a policy gate on human attachment: the
  -- notice is still admitted and written; if the core refuses, nothing was
  -- written and the explicit transport reason is retried like busy.
  { kind = "transport_attached", pattern = "a human is attached to this session" },
  { kind = "dialog", pattern = "butler dialog blocked" },
  { kind = "dialog", pattern = "butler dialog audit unavailable" },
  { kind = "dialog", pattern = "butler dialog target is not registered" },
  { kind = "rate", pattern = "session input rate limit exceeded" },
  { kind = "gone", pattern = "agent process has exited" },
  { kind = "gone", pattern = "no such session" },
  -- LateSubmitAbandoned: the earlier stalled write never got its Return and
  -- this text was not typed, so a retry cannot duplicate anything.
  { kind = "not_typed", pattern = "this text was not typed" },
  -- SubmitPending / SubmitUncertain / WriteTimeout / Io: bytes may be in the pane.
  { kind = "uncertain", pattern = "text is still being written to a slow pane" },
  { kind = "uncertain", pattern = "submission is unconfirmed" },
  { kind = "uncertain", pattern = "delivery may be partial or late" },
  { kind = "uncertain", pattern = "agent io error" },
  { kind = "uncertain", pattern = "input outcome is uncertain" },
  -- Native outcomes are prefixed, so they win over the generic session words.
  { kind = "native_dead", pattern = "native_dead" },
  { kind = "native_pending", pattern = "native_pending" },
  { kind = "native_not_written", pattern = "native_not_written" },
  { kind = "uncertain", pattern = "native_uncertain" },
  -- Preflight/refusal tokens from the dialogs capability and the local fallback.
  { kind = "transport_attached", pattern = "human_attached" },
  { kind = "gone", pattern = "session_not_live" },
  { kind = "gone", pattern = "session_replaced" },
  { kind = "gone", pattern = "session_instance_missing" },
  { kind = "gone", pattern = "session_changed" },
  { kind = "gone", pattern = "session_unknown" },
  { kind = "journal", pattern = "journal_generation_changed" },
  { kind = "journal", pattern = "attempt_replaced" },
  { kind = "journal", pattern = "journal_replaced" },
  { kind = "not_typed", pattern = "audit_unavailable" },
  { kind = "not_typed", pattern = "send_unavailable" },
  { kind = "not_typed", pattern = "dialogs_unavailable" },
  { kind = "not_typed", pattern = "invalid_notice" },
  -- A bare legacy false result proves nothing was written only when its detail
  -- says so; without such detail it must be uncertain, never retried blindly.
  { kind = "uncertain", pattern = "send_refused" },
}
local function notice_send_error_kind(err)
  local text = tostring(err or ""):lower():gsub("[\r\n]+", " ")
  for _, rule in ipairs(NOTICE_SEND_OUTCOMES) do
    if text:find(rule.pattern, 1, true) then return rule.kind end
  end
  -- Unknown after dispatch: assume bytes may be in the pane.
  return "uncertain"
end
local function clear_notice_fallbacks(session, ids)
  local fallback = bus.notice_fallbacks[session]
  if not fallback then return end
  for _, id in ipairs(ids or {}) do fallback[id] = nil end
  if next(fallback) == nil then bus.notice_fallbacks[session] = nil end
end
-- Open or merge into the session's stuck record (IDs union, since and report throttle kept).
function remuda._butler_notice_open_stuck(session, ids, reason)
  local stuck = bus.notice_stuck[session]
  local agent_id = bus.agents[session] and bus.agents[session].id
  if not stuck or stuck.agent_id ~= agent_id then
    stuck = { ids = {}, since = notice_now(), agent_id = agent_id }
    bus.notice_stuck[session] = stuck
  end
  local known = {}
  for _, id in ipairs(stuck.ids) do known[id] = true end
  for _, id in ipairs(ids or {}) do
    if not known[id] then stuck.ids[#stuck.ids + 1] = id end
  end
  stuck.reason = reason
end
-- Group the undelivered IDs by the person to tell. A sender without a Butler
-- mailbox identity (CLI or Matrix) is reported to the recipient's leader.
local function notice_alert_groups(session, ids)
  local groups = {}
  if session == "butler" then return groups end
  for _, id in ipairs(ids or {}) do
    local message = mail.find_message and mail.find_message(id)
    local sender = message and message.from
    local alias = sender and (sender.alias or sender.session)
    if sender and alias and alias ~= "butler" and alias ~= session then
      local target, target_id = alias, sender.id
      if not target_id or target_id == "" then
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
        local group = groups[target] or { id = target_id, message_ids = {} }
        groups[target] = group
        group.message_ids[#group.message_ids + 1] = id
      end
    end
  end
  return groups
end
local function notice_alert_already_sent(target_id, marker, id)
  if not (mail.find_message and bus.objects) then return false end
  for delivered_id in pairs(bus.mail_delivered and bus.mail_delivered[target_id] or {}) do
    local prior = mail.find_message(delivered_id)
    local object = prior and prior.body and bus.objects[prior.body.object_id]
    if prior and prior.from and prior.from.alias == "butler" and object
        and tostring(object.content):find("[" .. marker .. ":" .. id .. "]", 1, true) then
      return true
    end
  end
  return false
end
-- One alert per recipient, deduplicated by the marker already in Butler's own
-- sent mail so a daemon restart cannot repeat it.
local function send_notice_alert(session, ids, marker, body)
  for alias, group in pairs(notice_alert_groups(session, ids)) do
    if mail.unread then pcall(mail.unread, group.id) end
    local fresh = {}
    for _, id in ipairs(group.message_ids) do
      if not notice_alert_already_sent(group.id, marker, id) then fresh[#fresh + 1] = id end
    end
    if #fresh > 0 then
      local markers = {}
      for _, id in ipairs(fresh) do markers[#markers + 1] = "[" .. marker .. ":" .. id .. "]" end
      pcall(remuda._butler_send, "butler", alias, body(fresh) .. " " .. table.concat(markers, " "))
    end
  end
end
local function quoted_session(session)
  return tostring(session):gsub("\\", "\\\\"):gsub('"', '\\"')
end
-- An explicit refusal that wrote nothing: bounded retry through the existing
-- 20s/60s/300s/900s schedule, then one failure alert with the exact action.
notice_recovery_error = function(session, state, reason)
  state = type(state) == "table" and state or {}
  state.failed = true
  diagnostic("error", "delivery_failed", session)
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
    diagnostic("retry", "retry_scheduled", session)
    pending.diagnostic_reason = nil
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
    -- Reminders must not re-arm this notice; remind_unread_notices reports hourly instead.
    -- A later exhaustion merges into the open record so older unread IDs and the
    -- report throttle survive.
    remuda._butler_notice_open_stuck(session, state.message_ids, reason)
    send_notice_alert(session, state.message_ids, "butler-notice-failure", function(ids)
      return "Could not safely deliver queued Butler mail to " .. session .. " after "
        .. tostring(attempts + 1) .. " attempts (last error: " .. reason
        .. "). Inspect its composer, then run `remuda butler send \"" .. quoted_session(session)
        .. "\" \"read your inbox\"` to ask it to read its inbox. Message IDs: "
        .. table.concat(ids, ",") .. "."
    end)
  end
  clear_notice_fallbacks(session, state.message_ids)
  bus.notices[session] = nil
  bus.notice_recoveries[session] = nil
  return false
end
-- The write path returned but the outcome is unknown. The mail is untouched and
-- durable; the sender gets the IDs once, and no immediate resend or Return runs.
notice_delivery_uncertain = function(session, state, why)
  state = type(state) == "table" and state or {}
  local reason = first_line(why)
  if reason == "" then reason = "the send outcome is unknown" end
  local ids = state.message_ids or {}
  state.failed = true
  diagnostic("error", "delivery_uncertain", session)
  _butler_session_trace("notice_delivery_uncertain", "message_ids=" .. table.concat(ids, ",")
    .. " session=" .. session .. " reason=" .. reason)
  bus.notice_retry_reasons[session] = nil
  local agent = bus.agents[session]
  if agent and agent.id then
    local uncertain = bus.notice_uncertain[agent.id] or {}
    bus.notice_uncertain[agent.id] = uncertain
    for _, id in ipairs(ids) do uncertain[id] = reason end
  end
  remuda._butler_notice_open_stuck(session, ids, "uncertain: " .. reason)
  -- Manual-only recovery in this runtime: the unread stuck record drives the
  -- hourly leader report, and the sender alert names the IDs. Deliberately no
  -- reminder clock and no automatic resend, because the write may have landed.
  -- A full daemon restart loses the in-memory stuck record and may nudge the
  -- still-unread mail again (documented duplicate potential, not exactly-once).
  local alerts = bus.notice_uncertain_alerts[session] or {}
  bus.notice_uncertain_alerts[session] = alerts
  if not alerts.exhausted then
    alerts.exhausted = true
    send_notice_alert(session, ids, "butler-notice-uncertain", function(fresh)
      return "Could not confirm delivery of queued Butler mail to " .. session
        .. " (send outcome uncertain: " .. reason .. "). The mail is still unread in its inbox."
        .. " Inspect its pane, then run `remuda butler send \"" .. quoted_session(session)
        .. "\" \"read your inbox\"` if it is missing. Message IDs: " .. table.concat(fresh, ",") .. "."
    end)
  end
  bus.notices[session] = nil
  bus.notice_recoveries[session] = nil
  return false
end
-- Busy, attached or dialog-blocked: nothing was written, and the condition is
-- not the notice's fault. Recheck in one second without spending an attempt;
-- the same bounded busy cap still opens the hourly stuck record.
local function defer_notice_send(session, pending, kind, why)
  bus.notice_recoveries[session] = nil
  if pending then
    pending.due_at = notice_now() + 1
    pending.busy_since = pending.busy_since or notice_now()
    if notice_now() - pending.busy_since >= NOTICE_BUSY_CAP_S then
      remuda._butler_notice_open_stuck(session, pending.message_order,
        kind .. ": " .. first_line(why))
    end
    local reason = kind == "transport_attached" and "attach_refused"
      or kind == "dialog" and "dialog_blocked"
      or kind == "native_disabled" and "native_disabled"
      or kind == "native_pending" and "native_startup_pending"
      or kind == "target_changed" and "target_changed"
      or kind == "journal" and "journal_blocked" or "prompt_busy"
    if pending.diagnostic_reason ~= reason then
      diagnostic(kind == "journal" and "error" or "deferred", reason, session)
      pending.diagnostic_reason = reason
    end
    if kind == "native_disabled" then
      local alerts = bus.notice_native_alerts[session] or {}
      bus.notice_native_alerts[session] = alerts
      if not alerts.disabled then
        alerts.disabled = true
        send_notice_alert(session, pending.message_order, "butler-notice-native-disabled", function(ids)
          return "Native delivery to " .. session .. " is disabled ("
            .. first_line(why) .. "). No PTY fallback was attempted; mail stays unread until a"
            .. " later launch or inspection. Message IDs: " .. table.concat(ids, ",") .. "."
        end)
      end
      trace_notice_defer(session, pending, kind)
      return false, kind
    end
    if kind == "journal" then
      _butler_session_trace("notice_journal_blocked", "message_ids="
        .. table.concat(pending.message_order or {}, ",") .. " session=" .. session
        .. " reason=" .. first_line(why))
      local alerts = bus.notice_journal_alerts[session] or {}
      bus.notice_journal_alerts[session] = alerts
      if not alerts.reported then
        alerts.reported = true
        send_notice_alert(session, pending.message_order, "butler-notice-journal", function(ids)
          return "Automatic mail delivery to " .. session .. " is blocked by its delivery journal ("
            .. first_line(why) .. "). No bytes were written. Inspect `remuda butler doctor`; "
            .. "mail stays unread. Message IDs: " .. table.concat(ids, ",") .. "."
        end)
      end
    end
    trace_notice_defer(session, pending, kind)
  end
  return false, kind
end
-- The core accepted the write (submitted or unverified). This is transport
-- acceptance, never receipt: mail stays unread until its inbox is read, and
-- the reminder/stuck machinery keeps running for it.
complete_notice_recovery = function(session, state)
  state = type(state) == "table" and state or {}
  diagnostic("submitted", "transport_accepted", session)
  _butler_session_trace("notice_transport_accepted", "message_ids="
    .. table.concat(state.message_ids or {}, ",") .. " session=" .. session)
  local pending = bus.notices[session]
  if pending then pending.diagnostic_reason = nil end
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
      pending.delivery_attempts, pending.retry_at, pending.busy_since = 0, nil, nil
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
  bus.notice_journal_alerts[session] = nil
  bus.notice_journal_failure_alerts[session] = nil
  bus.notice_native_alerts[session] = nil
  local stuck = bus.notice_stuck[session]
  if stuck then
    -- Close only what this delivery covered; other stuck mail keeps its record and throttle.
    local delivered = {}
    for _, id in ipairs(state.message_ids or {}) do delivered[id] = true end
    local rest = {}
    for _, id in ipairs(stuck.ids) do
      if not delivered[id] then rest[#rest + 1] = id end
    end
    stuck.ids = rest
    if #rest == 0 then bus.notice_stuck[session] = nil end
  end
  clear_notice_fallbacks(session, state.message_ids)
  return true
end
-- The durable delivery journal is the authority for automatic attempts. It is
-- required: without it, or while it is blocked/corrupt/full, no automatic write
-- happens (explicit status, no PTY bypass). Helpers stay small and file-scope.
local function notice_journal()
  return remuda._butler_delivery_journal
end
local function notice_recipient_id(session)
  local agent = bus.agents[session]
  return agent and agent.id
end
local function notice_row(session)
  local listed, rows = pcall(remuda.ls)
  if not listed or type(rows) ~= "table" then return nil end
  for _, row in ipairs(rows) do
    if row.name == session then return row end
  end
end
local function notice_journal_record(session, state, text, snapshot)
  local agent = (snapshot and snapshot.agent) or bus.agents[session]
  local recipient_id = agent and agent.id
  if not recipient_id then return nil, "recipient_unknown" end
  local row
  if not snapshot then row = notice_row(session) end
  return { recipient_id = recipient_id, message_ids = state.message_ids,
    protocol = (snapshot and snapshot.protocol) or "pty",
    instance = (snapshot and snapshot.instance)
      or agent.instance_id or (row and row.instance_id),
    row_id = (snapshot and snapshot.row_id) or (row and row.id), body = text }
end
local function notice_journal_begin(session, state, text, snapshot)
  local journal = notice_journal()
  if not journal or type(journal.begin) ~= "function" then return nil, "journal_unavailable" end
  local record, record_err = notice_journal_record(session, state, text, snapshot)
  if not record then return nil, record_err end
  local ok, entry, err = pcall(journal.begin, record)
  if not ok then return nil, tostring(entry) end
  return entry, err, journal
end
-- The attempt's generation claim: the same journal object, the same entry in
-- it, still DISPATCHING, and the journal still current. Checked immediately
-- before any raw transport and again after an audit yield.
-- Everything the attempt decided BEFORE any yield: the originating notice
-- module, the exact agent object, instance/row identity, frozen body and the
-- full ID list. Capturing after journal.begin would let a writer-yield reload
-- or same-id agent replacement become the "current" identity.
local function frozen_native_binding(native)
  if type(native) ~= "table" or native.mode ~= "native" then return nil end
  return { mode = "native", kind = native.kind, path = native.path, nonce = native.nonce,
    row_id = native.row_id, instance = native.instance,
    awaiting_publication = native.awaiting_publication,
    awaiting_since = native.awaiting_since }
end

local function same_native_binding(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.path == right.path and left.nonce == right.nonce
    and left.row_id == right.row_id and left.instance == right.instance
    and left.kind == right.kind
end

-- A dead result belongs to the binding that was dispatched. The reservation
-- release yields, so only disable if the same generation and binding are still
-- in place; never mutate a replacement agent.
local function disable_native_if_current(session, snapshot, why)
  if not snapshot or not snapshot.native then return false end
  local agent = bus.agents[session]
  if agent ~= snapshot.agent or remuda._butler_notice ~= snapshot.generation then
    return false
  end
  if not same_native_binding(snapshot.native, frozen_native_binding(agent.native)) then
    return false
  end
  if remuda.butler and remuda.butler.native_launch then
    remuda.butler.native_launch.disable(agent, why)
  end
  return true
end

-- The same decision that chose the text must still belong to this agent. A
-- change before the first yield is stale, even if it looks more capable.
local function freeze_decision(agent, native_decision)
  if agent.native ~= native_decision then return nil, false end
  local frozen = frozen_native_binding(native_decision)
  if type(native_decision) == "table" and not frozen then return nil, false end
  return frozen, true
end

local function attempt_identity_unchanged(agent, session, recipient_id, instance, generation)
  return remuda._butler_notice == generation and bus.agents[session] == agent
    and agent.id == recipient_id and agent.instance_id == instance
end

local NATIVE_REQUEST_BYTES = 16
-- A fresh launch may race manifest/MCP publication. Only that binding may park
-- on `binding_missing`, and only for a bounded startup window: a missing
-- manifest on an adopted/reloaded binding is dead, not indefinite startup.
local NATIVE_STARTUP_WINDOW_S = 120
local CLAUDE_STARTUP_WINDOW_S = 30 * 60
-- A per-dispatch claim from the existing OS CSPRNG seam. The ID is frozen with
-- the attempt before the reservation and the first yield, so two notices in the
-- same second (for example an intentional re-show) never share a claim. It is
-- not derived from mail IDs or the clock and is never reused.
local function new_native_request_id()
  if type(remuda.random_bytes) ~= "function" then return nil end
  local ok, bytes = pcall(remuda.random_bytes, NATIVE_REQUEST_BYTES)
  if not ok or type(bytes) ~= "string" or #bytes < NATIVE_REQUEST_BYTES then return nil end
  local hex = {}
  for index = 1, NATIVE_REQUEST_BYTES do
    hex[index] = string.format("%02x", bytes:byte(index))
  end
  return "msg_" .. table.concat(hex)
end

-- Revalidate after the listing even for a PTY snapshot: a pty->bound change
-- under the frozen text is just as stale as a native->disabled change.
local function binding_unchanged_after_ls(agent, frozen)
  if frozen then
    return same_native_binding(frozen, frozen_native_binding(agent.native))
  end
  return type(agent.native) ~= "table"
end

local function notice_attempt_snapshot(session, state, text, native_decision)
  local agent = bus.agents[session]
  if not agent or not agent.id then return nil end
  local recipient_id, agent_instance = agent.id, agent.instance_id
  local generation = NOTICE_MODULE
  if remuda._butler_notice ~= generation then return nil end
  -- The decision and its whole binding are frozen BEFORE the first yield
  -- (remuda.ls), so the listing cannot change native/PTY under chosen text.
  local frozen, consistent = freeze_decision(agent, native_decision)
  if not consistent then return nil end
  -- The transport claim belongs to this attempt: generated before the first
  -- yield and before the journal reservation, carried unchanged to the helper.
  local request_id = frozen and new_native_request_id() or nil
  local row = notice_row(session) -- remuda.ls may yield
  if not attempt_identity_unchanged(agent, session, recipient_id, agent_instance,
      generation) then return nil end
  if not binding_unchanged_after_ls(agent, frozen) then return nil end
  local ids = {}
  for _, id in ipairs(state.message_ids or {}) do ids[#ids + 1] = id end
  return { generation = generation, agent = agent, session = session,
    protocol = frozen and "native" or "pty", native = frozen,
    request_id = request_id,
    agent_instance = agent_instance,
    recipient_id = recipient_id, instance = agent_instance or (row and row.instance_id),
    row_instance = row and row.instance_id,
    row_id = row and row.id, body = text, message_ids = ids }
end

local function notice_attempt_current(journal, entry, snapshot, observed)
  if not journal or not entry or not snapshot then return false end
  if remuda._butler_notice ~= snapshot.generation then return false end
  local live_agent = bus.agents[snapshot.session]
  if live_agent ~= snapshot.agent then return false end
  if live_agent.id ~= snapshot.recipient_id then return false end
  if snapshot.agent.instance_id ~= snapshot.agent_instance then return false end
  if snapshot.native then
    -- A replaced binding is a different generation: never send to it, and
    -- never fall back to PTY with text frozen for native delivery.
    if not same_native_binding(snapshot.native, frozen_native_binding(live_agent.native)) then
      return false
    end
  elseif type(live_agent.native) == "table" then
    -- A previously unbound (PTY) attempt cannot become bound mid-write.
    return false
  end
  if notice_journal() ~= journal then return false end
  if entry.state ~= "dispatching" then return false end
  if entry.recipient_id ~= snapshot.recipient_id then return false end
  if entry.body ~= snapshot.body then return false end
  if entry.instance ~= "" and snapshot.instance and entry.instance ~= snapshot.instance then
    return false
  end
  if snapshot.row_instance and entry.instance ~= snapshot.row_instance then return false end
  if entry.row_id ~= "" and snapshot.row_id and entry.row_id ~= snapshot.row_id then
    return false
  end
  if #entry.message_ids ~= #snapshot.message_ids then return false end
  for index, id in ipairs(snapshot.message_ids) do
    if entry.message_ids[index] ~= id then return false end
  end
  if type(journal.current) == "function" then
    local ok, current = pcall(journal.current)
    if not ok or current ~= true then return false end
  end
  -- The pre-transport preflight must observe the same target as the snapshot.
  -- This is what catches a legacy nil agent.instance_id whose row instance
  -- changed while the agent record stayed identical.
  if observed then
    if observed.recipient_id ~= snapshot.recipient_id then return false end
    if observed.agent_instance ~= snapshot.agent_instance then return false end
    if observed.instance ~= snapshot.instance then return false end
    if snapshot.row_id and observed.row_id ~= snapshot.row_id then return false end
  end
  local ok, found = pcall(journal.find, entry.recipient_id, entry.message_ids[1])
  return ok and found == entry
end
local function notice_journal_mutable(journal, entry)
  if not journal or not entry or notice_journal() ~= journal then return false, "attempt_replaced" end
  if type(journal.current) == "function" then
    local ok, current = pcall(journal.current)
    if not ok or current ~= true then return false, "attempt_replaced" end
  end
  return true
end
local function notice_journal_accepted(entry, journal)
  local mutable, why = notice_journal_mutable(journal, entry)
  if not mutable then return false, why end
  local ok, result, err
  if entry.protocol == "native" then
    ok, result, err = pcall(journal.mark, entry, "accepted_unread", "native accepted")
    if not ok then return false, tostring(result) end
    return result, err
  end
  ok, result, err = pcall(journal.retire, entry)
  if not ok then return false, tostring(result) end
  return result, err
end
local function notice_journal_uncertain(entry, why, journal)
  local mutable, replaced = notice_journal_mutable(journal, entry)
  if not mutable then return false, replaced end
  local ok, result, err = pcall(journal.mark, entry, "uncertain", first_line(why))
  if not ok then return false, tostring(result) end
  return result, err
end
local function notice_journal_abandon(entry, journal)
  local mutable, replaced = notice_journal_mutable(journal, entry)
  if not mutable then return false, replaced end
  local ok, result, err = pcall(journal.retire, entry, { restore = true })
  if not ok then return false, tostring(result) end
  return result, err
end
-- A resolution write can fail after the transport already ran (disk full, a
-- reload mid-save). Surface it explicitly instead of swallowing pcall results;
-- the entry stays reserved, so no automatic resend follows.
local function notice_journal_resolve_failed(session, ids, stage, why)
  diagnostic("error", "journal_resolve_failed", session)
  _butler_session_trace("notice_journal_resolve_failed", "message_ids="
    .. table.concat(ids or {}, ",") .. " session=" .. session .. " stage=" .. stage
    .. " reason=" .. first_line(why))
  local alerts = bus.notice_journal_failure_alerts[session] or {}
  bus.notice_journal_failure_alerts[session] = alerts
  if alerts.reported then return end
  alerts.reported = true
  local advice = {
    accepted = "The transport write was accepted, but its journal outcome could not be"
      .. " recorded. Legacy unread reminders may still run, and a restart may treat the"
      .. " attempt as uncertain.",
    uncertain = "The send outcome is uncertain and could not be recorded. The attempt"
      .. " stays reserved for this runtime, and a restart keeps it uncertain.",
    release = "A pre-write refusal could not release its reservation, so it is kept"
      .. " conservatively; no automatic resend runs until the journal is repaired.",
  }
  send_notice_alert(session, ids, "butler-notice-journal-failure", function(fresh)
    return "Butler could not record the " .. stage .. " outcome for automatic mail to "
      .. session .. " (" .. first_line(why) .. "). " .. (advice[stage] or "")
      .. " Inspect `remuda butler doctor`. Message IDs: " .. table.concat(fresh, ",") .. "."
  end)
end
local function notice_journal_suppressed(journal, recipient_id, message_id)
  local ok, value = pcall(journal.suppresses, recipient_id, message_id)
  return ok and value == true
end
-- A pending queue can outlive a reload. Drop IDs the journal already owns
-- (DISPATCHING/UNCERTAIN/accepted) before building a new attempt.
local function pending_without_reserved(session, pending)
  local journal = notice_journal()
  if not journal or not pending or not pending.message_order then return pending end
  local recipient_id = notice_recipient_id(session)
  if not recipient_id then return pending end
  local keep, dropped = {}, false
  for _, id in ipairs(pending.message_order) do
    if notice_journal_suppressed(journal, recipient_id, id) then dropped = true
    else keep[#keep + 1] = id end
  end
  if not dropped then return pending end
  if #keep == 0 then
    bus.notices[session], bus.notice_recoveries[session] = nil, nil
    bus.notice_retry_reasons[session] = nil
    return nil
  end
  local rebuilt = { count = #keep, message_ids = {}, message_order = keep,
    message_times = {}, reshow = {}, reminders = {}, kind = pending.kind,
    first_at = pending.first_at, last_at = pending.last_at, due_at = pending.due_at,
    delivery_attempts = pending.delivery_attempts, retry_at = pending.retry_at,
    busy_since = pending.busy_since, text = pending.message_ids[keep[#keep]] }
  for _, id in ipairs(keep) do
    rebuilt.message_ids[id] = pending.message_ids[id]
    rebuilt.message_times[id] = pending.message_times and pending.message_times[id]
    if pending.reshow and pending.reshow[id] then rebuilt.reshow[id] = true end
    if pending.reminders and pending.reminders[id] then rebuilt.reminders[id] = true end
  end
  bus.notices[session] = rebuilt
  return rebuilt
end
-- Native pointer text is frozen by the core contract: no sender detail, a
-- fixed MCP-first hint, and the original ID for a re-show.
local NATIVE_INBOX = "MCP butler_inbox (or remuda butler inbox)"
local function native_notice_text(pending)
  if pending.count == 1 then
    local id = pending.message_order[#pending.message_order]
    return "Butler message " .. id .. " arrived. Read it: " .. NATIVE_INBOX
  end
  return pending.count .. " new Butler messages arrived. Read them: " .. NATIVE_INBOX
end
local function native_state(session)
  local agent = bus.agents[session]
  local native = agent and agent.native
  if type(native) == "table" and (native.mode == "native" or native.mode == "disabled") then
    return native
  end
end
-- A usable native transport must never wait behind a typing-only gate.
local function native_immediate(session)
  local native = native_state(session)
  return native ~= nil and native.mode == "native"
end

local function native_row(session, native)
  local row = {}
  local listed, rows = pcall(remuda.ls)
  -- A listing failure wrote nothing and says nothing about the binding, so it
  -- is retryable; only a confirmed missing/stale target disables.
  if not listed or type(rows) ~= "table" then return nil, "session_unverified" end
  for _, candidate in ipairs(rows) do
    if candidate.name == session then row = candidate end
  end
  if not row.name or not row.alive then return nil, "session_not_live" end
  if type(native.row_id) ~= "string" or row.id ~= native.row_id then
    return nil, "target_missing"
  end
  if type(native.instance) ~= "string" or row.instance_id ~= native.instance then
    return nil, "stale_binding"
  end
  return row
end
local DEAD_BUILD_REASONS = { invalid_binding = true, invalid_nonce = true,
  invalid_session = true, invalid_instance = true }

local function native_target(session, native, still_current)
  local row, row_why = native_row(session, native)
  if not row then
    if row_why == "session_unverified" then
      return false, "native_not_written: " .. row_why
    end
    return false, "native_dead: " .. row_why
  end
  if type(still_current) == "function" then
    local ok, current = pcall(still_current)
    if not ok or current ~= true then return false, "journal_generation_changed" end
  end
  return row
end

local function native_request(native, text, ids, request_id)
  local dispatch = remuda.butler and remuda.butler.native_dispatch
  if not dispatch or type(dispatch.build) ~= "function" then
    return nil, nil, "native_uncertain: dispatch_unavailable"
  end
  if type(request_id) ~= "string" or request_id == "" then
    return nil, nil, "native_not_written: request_id_unavailable"
  end
  local request, why = dispatch.build({ binding = native.path, nonce = native.nonce,
    session = native.row_id, instance = native.instance,
    request_id = request_id, text = text, message_ids = ids })
  if not request then
    -- A broken binding target disables the session; anything else is a local
    -- preflight refusal that wrote nothing and may use the bounded schedule.
    if DEAD_BUILD_REASONS[why] then
      return nil, nil, "native_dead: " .. tostring(why)
    end
    return nil, nil, "native_not_written: " .. tostring(why)
  end
  return request, dispatch
end

local function startup_window(kind)
  return kind == "claude" and CLAUDE_STARTUP_WINDOW_S or NATIVE_STARTUP_WINDOW_S
end

-- A proven pre-write `binding_missing` parks only a freshly launched binding,
-- inside its bounded publication window. Anything else treats it as a dead
-- binding: a formerly-published manifest cannot vanish into endless waiting.
local function missing_manifest_is_startup(native)
  if type(native) ~= "table" or native.awaiting_publication ~= true then return false end
  local since = tonumber(native.awaiting_since)
  if not since then return false end
  return notice_now() - since <= startup_window(native.kind)
end

-- Only the core's typed `binding_missing` may park. A generic
-- `invalid_binding`/malformed/wrong-owner binding is dead and must disable:
-- absence and corruption are not interchangeable.
local function startup_shape(native, result)
  return result.startup_pending == true
    and (result.outcome == "not_written" or result.outcome == "dead_binding")
end

local function native_outcome(result, native)
  if type(result) ~= "table" then return false, "native_uncertain: dispatch_failed" end
  if result.outcome == "accepted" then return true end
  if startup_shape(native, result) then
    if missing_manifest_is_startup(native) then
      return false, "native_pending: " .. tostring(result.reason)
    end
    return false, "native_dead: binding_missing_after_startup"
  end
  if result.outcome == "dead_binding" then
    return false, "native_dead: " .. tostring(result.reason)
  end
  if result.outcome == "not_written" then
    return false, "native_not_written: " .. tostring(result.reason)
  end
  return false, "native_uncertain: " .. tostring(result.reason or "unknown")
end

-- The first answer that is not `binding_missing` proves the helper reached a
-- binding (or a real refusal). Clear the fresh-launch marker on the live agent
-- so a later disappearance is never treated as startup.
local function clear_publication_wait(session, native)
  local agent = bus.agents[session]
  local live = agent and agent.native
  if type(live) ~= "table" or live.mode ~= "native" then return end
  if not same_native_binding(frozen_native_binding(live), native) then return end
  live.awaiting_publication, live.awaiting_since = nil, nil
end

-- One helper invocation; every response is mapped to the existing notice
-- outcome classes. Never a PTY fallback and never a guessed success.
local function native_notice_send(session, native, text, ids, still_current, request_id)
  local row, target_why = native_target(session, native, still_current)
  if not row then return false, target_why end
  local request, dispatch, request_why = native_request(native, text, ids, request_id)
  if not request then return false, request_why end
  local result = dispatch.dispatch(request, { json = remuda.json,
    runner = remuda.process and remuda.process.run, remuda = "remuda",
    kind = native.kind })
  local sent, why = native_outcome(result, native)
  -- Clear the fresh-launch marker only on a proven typed answer (accepted or a
  -- real dead/not-written refusal). An uncertain runner/spawn failure says
  -- nothing about publication, and a pending answer keeps waiting.
  local typed = sent or tostring(why):find("^native_dead:", 1) ~= nil
    or tostring(why):find("^native_not_written:", 1) ~= nil
  if typed then clear_publication_wait(session, native) end
  return sent, why
end
-- The dialogs module's narrow automatic-wakeup capability is the only path
-- that bypasses the modal prediction gate. Without that module (isolated
-- tests or an older image) the raw core word is used after the same
-- live-session/bound-instance preflight and, when supplied, the generation
-- fence. Attachment itself is not an admission gate.
local function notice_send(session, text, ids, still_current, frozen_native, request_id)
  -- Only the frozen decision can select native: a mode change during the
  -- journal write must never turn this attempt into a PTY write.
  local native = frozen_native
  if native and native.mode == "native" then
    return native_notice_send(session, native, text, ids, still_current, request_id)
  end
  local dialogs = remuda.butler and remuda.butler.dialogs
  if dialogs and type(dialogs.automatic_notice_send) == "function" then
    local ok, sent, reason = pcall(dialogs.automatic_notice_send, session, text, ids, still_current)
    if not ok then return false, tostring(sent) end
    return sent == true, reason
  end
  local agent = bus.agents[session]
  if not agent then return false, "session_unknown" end
  local row
  for _, candidate in ipairs(remuda.ls()) do
    if candidate.name == session then row = candidate end
  end
  if not row or not row.alive then return false, "session_not_live" end
  local expected, actual = agent.instance_id, row.instance_id
  if type(expected) == "string" and expected ~= "" then
    -- A bound instance with no readable row instance cannot be verified.
    if type(actual) ~= "string" or actual == "" then return false, "session_instance_missing" end
    if actual ~= expected then return false, "session_replaced" end
  end
  if type(remuda.send) ~= "function" then return false, "send_unavailable" end
  if type(still_current) == "function" then
    local ok_guard, current = pcall(still_current, { recipient_id = agent.id,
      agent_instance = agent.instance_id, instance = actual, row_id = row.id })
    if not ok_guard or current ~= true then return false, "journal_generation_changed" end
  end
  local ok, result, detail = pcall(remuda.send, session, text)
  if ok and result ~= false then return true end
  if ok then return false, "send_refused: " .. tostring(detail or result or "refused") end
  return false, tostring(result or "send error")
end
-- One send per coalesced notice. No screen parsing, no composer prediction,
-- no modal prediction, no Return retry: the live-session/bound-instance
-- preflight, the generation fence and the core's in-flight write guard decide.
local function deliver_notice(session)
  local pending = bus.notices[session]
  if not pending then return true end
  pending = refresh_pending_notice(session, pending)
  pending = pending and pending_without_reserved(session, pending)
  if not pending then return true end
  local native = native_state(session)
  if native and native.mode == "disabled" then
    return defer_notice_send(session, pending, "native_disabled",
      native.reason or "native delivery is disabled")
  end
  -- A pending delegated task owns the PTY pane; it does not own a native
  -- helper queue. Native delivery is never deferred behind task typing.
  if bus.pending_tasks[session] and not (native and native.mode == "native") then
    return false
  end
  local state = { count = pending.count, message_ids = {} }
  for _, id in ipairs(pending.message_order or {}) do state.message_ids[#state.message_ids + 1] = id end
  local text = native and native_notice_text(pending) or pending_notice_text(pending)
  -- DISPATCHING is persisted before any bytes are written; without that write
  -- there is no dispatch at all (no PTY bypass).
  local snapshot = notice_attempt_snapshot(session, state, text, native)
  if not snapshot then
    return defer_notice_send(session, pending, "journal", "journal_generation_changed")
  end
  local entry, journal_why, journal = notice_journal_begin(session, state, text, snapshot)
  if not entry then
    return defer_notice_send(session, pending, "journal", journal_why)
  end
  local function still_current(observed)
    return notice_attempt_current(journal, entry, snapshot, observed)
  end
  local sent, why = notice_send(session, text, state.message_ids, still_current,
    snapshot.native, snapshot.request_id)
  if sent then
    local recorded, record_err = notice_journal_accepted(entry, journal)
    if not recorded then
      notice_journal_resolve_failed(session, state.message_ids, "accepted", record_err)
    end
    return complete_notice_recovery(session, state)
  end
  local kind = notice_send_error_kind(why)
  if kind == "uncertain" then
    local recorded, record_err = notice_journal_uncertain(entry, why, journal)
    if not recorded then
      notice_journal_resolve_failed(session, state.message_ids, "uncertain", record_err)
    end
    return notice_delivery_uncertain(session, state, why)
  end
  -- Everything else provably wrote nothing, so its reservation is released.
  if kind == "native_dead" then
    local released, release_err = notice_journal_abandon(entry, journal)
    if not released then
      notice_journal_resolve_failed(session, state.message_ids, "release", release_err)
    end
    if disable_native_if_current(session, snapshot, why) then
      return defer_notice_send(session, pending, "native_disabled", why)
    end
    return defer_notice_send(session, pending, "target_changed", why)
  end
  if kind == "native_pending" or kind == "native_not_written" then
    local released, release_err = notice_journal_abandon(entry, journal)
    if not released then
      notice_journal_resolve_failed(session, state.message_ids, "release", release_err)
    end
    if kind == "native_pending" then
      return defer_notice_send(session, pending, "native_pending", why)
    end
    return notice_recovery_error(session, state, why)
  end
  if kind == "journal" and why and tostring(why):find("journal_generation_changed", 1, true) then
    -- An invalidated attempt stays reserved. If this journal object is still the
    -- owner, mark it UNCERTAIN now; a replacement journal already recovered it
    -- from DISPATCHING on load, so never retire or abandon it here.
    local mutable = notice_journal_mutable(journal, entry)
    if mutable then pcall(journal.mark, entry, "uncertain", "journal_generation_changed") end
    return defer_notice_send(session, pending, "journal", "journal_generation_changed")
  end
  local released, release_err = notice_journal_abandon(entry, journal)
  if not released then
    notice_journal_resolve_failed(session, state.message_ids, "release", release_err)
    return defer_notice_send(session, pending, "journal", release_err)
  end
  if kind == "busy" or kind == "transport_attached" or kind == "dialog" or kind == "rate" then
    return defer_notice_send(session, pending, kind, why)
  end
  -- not_typed / gone: nothing was written, so the bounded schedule owns it.
  return notice_recovery_error(session, state,
    kind == "gone" and "the recipient session is gone" or "the notice write was abandoned before typing")
end
-- The poll and the debounce timers share this check.
local function deliver_due_notice(session, now)
  local pending = bus.notices[session]
  if not bus.agents[session] then
    cancel_notice_timers(session)
    bus.notices[session] = nil
  elseif native_immediate(session) then
    -- No quiet window or task gate for a native queue. A proven pre-write
    -- refusal keeps its bounded retry backoff.
    if pending and pending.retry_at and now < pending.retry_at then return end
    cancel_notice_timers(session)
    if pending and pending.retry_at then pending.retry_at = nil end
    deliver_notice(session)
  elseif bus.notice_recoveries[session]
      or not pending or pending.due_at == nil or now >= pending.due_at then
    cancel_notice_timers(session)
    if pending and pending.retry_at and now >= pending.retry_at then pending.retry_at = nil end
    deliver_notice(session)
  end
end
-- One immediate native handoff. A mail arrival during the journal/helper yield
-- is queued while this guard is held; the completion keeps that remainder, so
-- drain it now instead of waiting for a poll or quiet window.
local function deliver_native_now(session)
  local sent = false
  for _ = 1, 8 do
    if bus.notice_native_dispatching[session] then break end
    bus.notice_native_dispatching[session] = true
    local ok, result = pcall(deliver_notice, session)
    bus.notice_native_dispatching[session] = nil
    if not ok then
      _butler_session_trace("notice_native_immediate_failed", session .. " " .. tostring(result))
      break
    end
    sent = sent or result == true
    if result ~= true or not bus.notices[session] then break end
  end
  return sent
end

-- Lifecycle owners call this when a binding may have just been published
-- (launch completion, successful adoption). It performs one fresh helper
-- attempt, so the helper - not a file read - is the authority. It is an
-- explicit event entrypoint; the bounded notice tick remains the fallback when
-- a publication happens outside any Butler-visible lifecycle step.
local function native_publication(alias)
  if not native_immediate(alias) then return false end
  return deliver_native_now(alias)
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
-- An automatic wakeup for an ID that is already stuck for this recipient (an
-- uncertain send, or a busy/dialog deferral past the cap) is suppressed here,
-- the single admission point. That covers arrivals, reshow-after-compaction and
-- reminders alike, so a second compaction or a preserved-bus reload cannot
-- blindly resend the same possibly-written ID. New message IDs are unaffected.
local function notice_id_stuck(alias, message_id)
  if not message_id then return false end
  local agent = bus.agents[alias]
  local recipient_id = agent and agent.id or mail_id(alias, false)
  if type(recipient_id) ~= "string" then return false end
  local journal = notice_journal()
  if journal and type(journal.suppresses) == "function"
      and notice_journal_suppressed(journal, recipient_id, message_id) then
    return true
  end
  local uncertain = bus.notice_uncertain[recipient_id]
  if uncertain and uncertain[message_id] then return true end
  local stuck = bus.notice_stuck[alias]
  if not stuck or type(stuck.ids) ~= "table" then return false end
  if agent and stuck.agent_id and stuck.agent_id ~= agent.id then return false end
  for _, id in ipairs(stuck.ids) do
    if id == message_id then return true end
  end
  return false
end
function remuda._butler_notify(alias, notice, message_id, reshow, reminder)
  local _, recipient = mail_id(alias, false)
  if notice_id_stuck(alias, message_id) then return false end
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
  pending.count, pending.text, pending.kind = pending.count + 1, notice, recipient.kind
  bus.notices[alias] = pending
  local native = native_immediate(alias)
  if native then
    -- Immediate native handoff: no quiet/max-wait/debounce. The journal and
    -- identity fences still run inside deliver_notice; a proven pre-write
    -- refusal keeps its explicit retry_at.
    pending.due_at = pending.retry_at and math.max(now, pending.retry_at) or now
    cancel_notice_timers(alias)
    return deliver_native_now(alias)
  end
  pending.due_at = math.min(now + NOTICE_QUIET_S, pending.first_at + NOTICE_MAX_WAIT_S)
  if pending.retry_at then pending.due_at = math.max(pending.due_at, pending.retry_at) end
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
  local stuck = bus.notice_stuck[alias]
  local uncertain = {}
  if stuck and stuck.agent_id == agent.id then
    for _, id in ipairs(stuck.ids or {}) do uncertain[id] = true end
  end
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
      if not already_pending and not already_seen and not uncertain[message_id] then
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
-- One report per hour per stuck session to its leader; the record closes once its mail is read.
local function report_stuck_notice(alias, agent, stuck, now)
  local unread = {}
  for _, id in ipairs(stuck.ids) do
    if mail.is_unread(agent.id, id) then unread[#unread + 1] = id end
  end
  if #unread == 0 then bus.notice_stuck[alias] = nil; return end
  if stuck.reported_at and now - stuck.reported_at < NOTICE_STUCK_REPORT_SECONDS then return end
  stuck.reported_at = now
  local leader = agent.parent
  if not leader or leader == alias or not bus.agents[leader] then leader = "butler" end
  if leader == alias then return end
  pcall(remuda._butler_send, "butler", leader, "Stuck Butler mail for " .. alias .. ": "
    .. #unread .. " unread message(s) (" .. table.concat(unread, ",") .. ") undelivered for "
    .. math.floor((now - stuck.since) / 60) .. " min (last error: "
    .. tostring(stuck.reason) .. "). Inspect its composer, then `remuda butler send \"" .. alias
    .. "\" \"read your inbox\"`.")
end
local function prune_accepted_entries(agent)
  local journal = notice_journal()
  if not journal or not agent.id or type(journal.prune_accepted) ~= "function" then return end
  pcall(journal.prune_accepted, agent.id, function(message_id)
    return not mail.is_unread(agent.id, message_id)
  end)
end
local function remind_unread_notices(alias, agent, now)
  if not agent.id then return end
  if bus.pending_tasks[alias] and not native_immediate(alias) then return end
  prune_accepted_entries(agent)
  local stuck = bus.notice_stuck[alias]
  if stuck and stuck.agent_id ~= agent.id then bus.notice_stuck[alias], stuck = nil, nil end -- relaunched member
  if stuck then return report_stuck_notice(alias, agent, stuck, now) end
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
      -- Seeding no longer reads the composer (owner decision 2026-11-03): the
      -- queued notice is delivered by the ordinary atomic send below. A Codex
      -- update handoff and a delegated startup task still own the pane.
      if agent.id then note_context_drop(alias, agent, instance) end
      local native_now = native_immediate(alias)
      if bus.pending_tasks[alias] and not native_now then
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
          elseif (not bus.pending_tasks[alias] or native_now)
              and (not update_handoff or native_now) then
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
      if not update_handoff or native_now then remind_unread_notices(alias, agent, now) end
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
    .. "; notice queued for its next eligible delivery", message.id
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

NOTICE_MODULE.mail_notice_text = mail_notice_text
NOTICE_MODULE.startup_action_safe = startup_action_safe
NOTICE_MODULE.notice_recovery_error = notice_recovery_error
NOTICE_MODULE.deliver_notice = deliver_notice
NOTICE_MODULE.native_publication = native_publication
NOTICE_MODULE.remind_unread_notices = remind_unread_notices
NOTICE_MODULE.complete_notice_recovery = complete_notice_recovery
remuda._butler_notice = NOTICE_MODULE
