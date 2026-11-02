-- Run from the repository root: luajit tests/butler_notice_ghost_and_quoted_modal.lua
-- Two false positives held a leader's Matrix mail notices for up to ~45 minutes, then
-- dropped them after the retry limit:
-- 1. The retry probe judged the raw screen, so Claude's dim ghost suggestion read as a
--    draft (NON-EMPTY) on every attempt (the notice path of #372).
-- 2. The modal check matched the Teach title anywhere on screen, including the leader's
--    own report quoting it. A live modal is painted below the transcript; a quote is not.
_butler_session_trace = function() end
local now = 1000
local bus = {
  agents = { lead = { id = "lead-id", kind = "claude", parent = "root" } },
  notices = {}, pending_tasks = {}, notice_timers = {}, messages = {}, objects = {}, mail_delivered = {},
  codex_update_relaunches = {}, codex_update_state = {},
}
local startup = { claude = { modals = {} }, codex = { modals = {} } }
remuda = {
  _butler_agent_builders = {}, _butler_agent_startup = startup, _butler_telemetry_adapters = {},
  _butler_state = {}, _butler_compaction_state = {}, _butler_agent_support = {},
  _butler_test_mode = true, _butler_mail = {}, butler = {},
  _butler_system = {}, _butler_prompt_delivery = {},
}
dofile("packages/butler/agents/claudecode.lua")
dofile("packages/butler/sandbox.lua")
dofile("packages/butler/agents/codex.lua")
dofile("packages/butler/prompt.lua")
local function noop() end
local rows = {}
for _, kind in ipairs({ "claude", "codex" }) do
  rows[#rows + 1] = { id = kind, entry = { argv = { kind }, login = {}, dialogs = startup[kind].modals,
    ready = startup[kind].ready or function() return false end } }
end
remuda._butler_chooser_config = {
  bus = { agents = {} }, call_callback = function(fn, ...) return pcall(fn, ...) end,
  numbered_option = noop, bottom_screen_lines = function() return {} end,
  file_exists = noop, contributions = function() return rows end,
  startup_action_safe = function() return true end,
}
remuda._butler_contribute = noop
remuda.contribute = noop
dofile("packages/butler/agents_launch.lua")

local screen, ghost, typed = "", nil, {}
remuda._butler_notice_config = {
  bus = bus, resolve = function(n) return n end,
  mail_address = function(n) return { alias = n, id = n } end,
  mail_id = function(n) return n, { alias = n, id = n, kind = "claude" } end,
  mail = { mailbox = function() return {} end, is_unread = function() return true end,
    unread = function() return 1 end, find_message = function() return { from = { alias = "owner", id = "o" } } end },
  take_delivery_notice_result = noop, notify_mail_delivery = noop, deliver_message = noop,
}
remuda._butler_notice_clock = function() return now end
remuda._butler_session_trace = noop
remuda._butler_send = noop
remuda.ls = function() return { { name = "lead", alive = true, attached = false } } end
remuda.session = function() return { is_busy = false } end
remuda.capture = function() return screen end
-- Styled capture: the cursor sits on the last composer row; `ghost` is painted dim after "❯ ".
remuda.capture_styled = function()
  local out, cursor = {}, 1
  for line in (screen .. "\n"):gmatch("(.-)\n") do
    if line:sub(1, 3) == "❯" then
      cursor = #out + 1
      out[cursor] = ghost and { { text = "❯ " }, { text = ghost, dim = true } } or { { text = line } }
    else
      out[#out + 1] = { { text = line } }
    end
  end
  return { cursor = { row = cursor }, rows = out }
end
remuda.type_text = function(_, text) typed[#typed + 1] = text; return "submitted" end
remuda.key = function() error("notice delivery must not press keys here") end
dofile("packages/butler/notice.lua")
local deliver = remuda._butler_notice.deliver_notice

local function composer(text)
  return "────────────────────────────────────────\n❯ " .. (text or "")
    .. "\n────────────────────────────────────────\n  ⏵⏵ auto mode on · ← for agents"
end
local function reset(attempts, probing)
  typed, bus.notice_screens, bus.notice_fallbacks = {}, {}, {}
  bus.notices.lead = { count = 1, message_order = { "m1" }, message_ids = { m1 = "Butler message m1" },
    text = "Butler message m1", kind = "claude", delivery_attempts = attempts }
  bus.notice_recoveries = probing and { lead = { phase = "probe", count = 1, started_at = now,
    message_ids = { "m1" } } } or {}
end
local function read(path)
  local f = assert(io.open(path, "rb")); local text = f:read("*a"); f:close(); return text
end

-- 1. Ghost suggestion: a retry after a failed write, and a running probe, both deliver.
ghost = "check inbox and matrix messages"
screen = "⏺ Done.\n\n✻ Cooked for 14s\n\n" .. composer(ghost)
assert(remuda._butler_prompt_is_empty("claude", screen) == "NON-EMPTY", "raw read sees the ghost as text")
for _, case in ipairs({ { 1, false, "retry after a failed write" }, { 0, true, "running probe" } }) do
  reset(case[1], case[2])
  deliver("lead")
  assert(#typed == 1, case[3] .. ": a ghost suggestion must not block the notice")
  assert(bus.notice_recoveries.lead.phase == "verify_notice", case[3] .. ": submission is verified")
end
-- A real (non-dim) draft still blocks.
ghost = nil
screen = "⏺ Done.\n\n" .. composer("my half-typed reply")
reset(1, false)
deliver("lead")
assert(#typed == 0, "a real draft is never typed into")
print("ok - ghost suggestion no longer blocks notice retries")

-- 2. Quoted Teach title in the transcript, followed by more transcript rows: deliver.
local quote = "⏺ 4) Blocked: three members are stuck on the 'Teach auto mode' dialog\n"
  .. "  (Teach auto mode about your environment? Not now / Don't show again).\n\n"
  .. "✻ Churned for 4s · done 9:05 AM\n\n"
screen = quote .. composer()
reset(0, false)
deliver("lead")
assert(#typed == 1, "a quoted modal title in the transcript must not block the notice")
-- Quote followed by a tool result row only.
screen = "⏺ Bash(grep 'Teach auto mode' notes.md)\n  ⎿  Teach auto mode about your environment?\n  ⎿  done\n" .. composer()
reset(0, false)
deliver("lead")
assert(#typed == 1, "a quoted title inside tool output must not block the notice")
print("ok - quoted Teach title does not block notices")

-- 3. Live modals still block, including one painted below a quote of itself.
local fixtures = {
  "tests/fixtures/claude-teach-auto-mode-modal-transcript/modal-page1-win-styled.txt",
  "tests/fixtures/claude-teach-auto-mode-modal-transcript/modal-page2-lua-b06.txt",
  "tests/fixtures/claude-teach-auto-mode-modal-synthetic/narrow-page1.txt",
  "tests/fixtures/claude-teach-auto-mode-modal-synthetic/narrow-wrapped-page1.txt",
}
for _, path in ipairs(fixtures) do
  for _, prefix in ipairs({ "", quote }) do
    screen = prefix .. read(path)
    reset(0, false)
    deliver("lead")
    assert(#typed == 0, "live modal must block the notice: " .. path .. (prefix ~= "" and " (after a quote)" or ""))
  end
end
-- First-task delivery keeps the fail-closed matcher: a quote still counts there.
assert(remuda._butler_chooser.known_startup_modal(startup.claude, quote .. composer()),
  "first-task modal detection is unchanged")
print("ok - live Teach modal still blocks notices")
