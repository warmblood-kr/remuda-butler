-- Run from the repository root: luajit tests/butler_notice_no_idle_wait.lua
-- Owner decision, 2026-10-19: Claude Code and Codex both queue input typed while they
-- work, so a notice is submitted without waiting for the session to go idle. The one
-- exception is an open dialog: text typed into it is consumed as a choice.
-- 1. A busy session with an empty composer (also behind a dim ghost suggestion) submits.
-- 2. A session with a dialog open never submits, busy or idle.
-- 3. Typed text in the composer still blocks.
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

local screen, ghost, busy, typed = "", nil, true, {}
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
remuda.session = function() return { is_busy = busy } end
remuda.capture = function() return screen end
-- Styled capture: the cursor sits on the last row that starts with a prompt glyph (❯ or ›,
-- after indentation); `ghost` is painted dim after the glyph on that row.
remuda.capture_styled = function()
  local out, cursor = {}, 1
  for line in (screen .. "\n"):gmatch("(.-)\n") do
    local glyph = line:match("^%s*(❯)") or line:match("^%s*(›)")
    if glyph then cursor = #out + 1 end
    if glyph and ghost then
      out[#out + 1] = { { text = glyph .. " " }, { text = ghost, dim = true } }
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

local function read(path)
  local f = assert(io.open(path, "rb")); local text = f:read("*a"); f:close(); return text
end
local FX = "tests/fixtures/notice-working/"
local claude_working = read(FX .. "claude-2.1.300-working-empty.txt")
local claude_draft = read(FX .. "claude-2.1.300-working-draft.txt")
local codex_working = read(FX .. "codex-0.162.1-working-empty.txt")

-- Each path that can type a notice: a first write, a retry after a failed write, and a
-- recovery probe already running.
local PATHS = { { 0, false, "first write" }, { 1, false, "retry after a failed write" },
  { 0, true, "running probe" } }
local function attempt(kind, path)
  bus.agents.lead.kind = kind
  typed, bus.notice_screens, bus.notice_fallbacks, bus.notice_stuck = {}, {}, {}, {}
  bus.notices.lead = { count = 1, message_order = { "m1" }, message_ids = { m1 = "Butler message m1" },
    text = "Butler message m1", kind = kind, delivery_attempts = path[1] }
  bus.notice_recoveries = path[2] and { lead = { phase = "probe", count = 1, started_at = now,
    message_ids = { "m1" }, checks = 0 } } or {}
  deliver("lead")
  return #typed
end

-- 1. Busy + empty composer submits at once, for both agents, on every path.
busy = true
for _, case in ipairs({
  { "claude", claude_working, nil, "busy Claude, empty composer" },
  { "claude", claude_working, "check inbox and matrix messages", "busy Claude, dim ghost suggestion" },
  { "codex", codex_working, nil, "busy Codex, placeholder composer" },
}) do
  screen, ghost = case[2], case[3]
  for _, path in ipairs(PATHS) do
    assert(attempt(case[1], path) == 1, case[4] .. " (" .. path[3] .. "): the notice must be submitted now")
    assert(bus.notice_recoveries.lead.phase == "verify_notice", case[4] .. ": the submit is verified")
  end
end
ghost = nil
-- Busy telemetry that is missing, failing or partial does not hold the notice either.
screen = codex_working
for name, api in pairs({
  missing = false,
  throws = function() error("boom") end,
  nil_row = function() return nil end,
  nil_busy = function() return {} end,
}) do
  remuda.session = api or nil
  assert(attempt("codex", PATHS[1]) == 1, "Codex with busy telemetry " .. name .. " still submits")
end
remuda.session = function() return { is_busy = busy } end
print("ok - a busy session with an empty composer submits without waiting for idle")

-- 2. An open dialog never receives the notice, busy or idle.
local dialogs = {
  { "claude", "tests/fixtures/claude-teach-auto-mode-modal-transcript/modal-page1-win-styled.txt" },
  { "claude", "tests/fixtures/claude-teach-auto-mode-modal-synthetic/narrow-page1.txt" },
  { "claude", "tests/fixtures/claude-trust-dialog.txt" },
  { "codex", "tests/fixtures/codex-trust-dialog.txt" },
  { "codex", "tests/fixtures/codex-approval-command.txt" },
}
for _, state in ipairs({ true, false }) do
  busy = state
  for _, dialog in ipairs(dialogs) do
    screen = read(dialog[2])
    for _, path in ipairs(PATHS) do
      assert(attempt(dialog[1], path) == 0, "open dialog must not receive the notice: " .. dialog[2]
        .. " (" .. path[3] .. ", busy=" .. tostring(state) .. ")")
      assert(bus.notices.lead, "the notice stays queued behind the dialog")
    end
  end
end
print("ok - an open dialog blocks the notice whether or not the session is busy")

-- 3. Typed text still blocks while busy: the notice would be appended to the draft.
busy = true
screen = claude_draft
for _, path in ipairs(PATHS) do
  assert(attempt("claude", path) == 0, "a typed draft blocks the notice (" .. path[3] .. ")")
end
print("ok - typed text in the composer still blocks")
