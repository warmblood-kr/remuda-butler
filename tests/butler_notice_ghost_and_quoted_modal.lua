-- Run from the repository root: luajit tests/butler_notice_ghost_and_quoted_modal.lua
-- Two false positives used to hold a leader's Matrix mail notices for up to ~45
-- minutes, then drop them after the retry limit:
-- 1. The retry probe read the raw screen, so Claude's dim ghost suggestion was
--    taken as a draft.
-- 2. The modal check matched the Teach title anywhere on screen, including the
--    leader's own report quoting it.
-- Automatic wakeups no longer read the screen or predict modals at all
-- (owner decision 2026-11-03). Only the attached/live/instance preflight and
-- the audited dialog gate for general writes remain.
_butler_session_trace = function() end
local now = 1000
local sent, screens, captures = {}, {}, 0
local bus = {
  agents = { lead = { id = "lead-id", kind = "claude", parent = "root", instance_id = "instance-1" } },
  notices = {}, pending_tasks = {}, notice_timers = {}, messages = {}, objects = {}, mail_delivered = {},
  codex_update_relaunches = {}, codex_update_state = {}, notice_seen = {}, unread_seeded = {}, mail_resent = {},
}
local mail = {
  mailbox = function() return {} end, is_unread = function() return true end,
  unread = function() return 1 end, find_message = function() return { from = { alias = "owner", id = "o" } } end,
}
remuda = {
  _butler_notice_config = {
    bus = bus, resolve = function(n) return n end,
    mail_address = function(n) return { alias = n, id = n } end,
    mail_id = function(n) return n, { alias = n, id = n, kind = "claude" } end,
    mail = mail, take_delivery_notice_result = function() end,
    notify_mail_delivery = function() end, deliver_message = function() end,
  },
  _butler_chooser = { known_startup_modal = function() return false end },
  _butler_agent_startup = { claude = { placeholders = {} } },
  _butler_notice_clock = function() return now end,
  _butler_session_trace = function() end,
  ls = function() return { { name = "lead", alive = true, attached = false, instance_id = "instance-1" } } end,
  capture = function() captures = captures + 1; return screens.lead end,
  capture_styled = function() captures = captures + 1; return { cursor = { row = 1 }, rows = {} } end,
  session = function() error("notice delivery must not read busy telemetry") end,
  key = function() error("notice delivery must never press a key") end,
  type_text = function() error("notice delivery must use one atomic send") end,
}
dofile("tests/notice_journal_stub.lua")
dofile("packages/butler/notice.lua")
dofile("tests/notice_policy_stub.lua")
remuda._butler_send = function(_, to, body) sent[#sent + 1] = { to, body } end
local deliver = remuda._butler_notice.deliver_notice

local function composer(text)
  return "────────────────────────────────────────\n❯ " .. (text or "")
    .. "\n────────────────────────────────────────\n  ⏵⏵ auto mode on · ← for agents"
end
local function reset(screen, attempts)
  bus.notices.lead = { count = 1, message_order = { "m1" }, message_ids = { m1 = "Butler message m1" },
    text = "Butler message m1", kind = "claude", delivery_attempts = attempts }
  bus.notice_recoveries, bus.notice_screens, bus.notice_fallbacks = {}, {}, {}
  screens.lead = screen
  remuda.send = function(_, text) sent[#sent + 1] = { text = text } end
end
sent = {}

-- 1. A dim ghost suggestion (raw parser reads NON-EMPTY) must not block a
-- retry after a failed write, nor a running probe.
for _, attempts in ipairs({ 1, 0 }) do
  reset("⏺ Done.\n\n✻ Cooked for 14s\n\n" .. composer("check inbox and matrix messages"), attempts)
  assert(deliver("lead") == true, "a ghost suggestion cannot block the notice (attempts=" .. attempts .. ")")
  assert(bus.notices.lead == nil, "the notice is sent and cleared")
end

-- 2. A real draft no longer blocks an automatic wakeup either (owner accepted
-- detached-draft concatenation); it is still one atomic send.
reset("⏺ Done.\n\n" .. composer("my half-typed reply"), 0)
assert(deliver("lead") == true, "a real draft no longer traps the notice")
assert(#sent == 3, "the draft screen produced exactly one more send")

-- 3. A quoted Teach title, with or without following transcript rows, sends.
local quote = "⏺ 4) Blocked: three members are stuck on the 'Teach auto mode' dialog\n"
  .. "  (Teach auto mode about your environment? Not now / Don't show again).\n\n"
  .. "✻ Churned for 4s · done 9:05 AM\n\n"
reset(quote .. composer(), 0)
assert(deliver("lead") == true, "a quoted modal title cannot block the notice")
reset("⏺ Bash(grep 'Teach auto mode' notes.md)\n  ⎿  Teach auto mode about your environment?\n  ⎿  done\n"
  .. composer(), 0)
assert(deliver("lead") == true, "a quoted title inside tool output cannot block the notice")
assert(#sent == 5, "every case sends exactly once")
assert(captures == 0, "automatic notice delivery never captured the screen")
print("ok - ghost suggestions and quoted modal titles cannot block automatic notices")
