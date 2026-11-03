-- Run from the repository root: luajit tests/butler_notice_idle_nonempty.lua
-- Two separate contracts used to be tangled here:
-- 1. Automatic mail wakeups no longer consult the composer at all (owner
--    decision 2026-11-03): a garbled or non-empty composer gets the same one
--    atomic send, and draft concatenation is accepted.
-- 2. `_butler_notify_policy` remains for independent workflows (Matrix owner
--    lines and first-task delivery) and keeps its draft/modal/human guards.
local now = 1000
_butler_session_trace = function() end
local bus = {
  agents = { lead = { id = "lead-id", kind = "claude", parent = "root", instance_id = "instance-1" } },
  notices = {}, pending_tasks = {}, notice_timers = {}, messages = {}, objects = {}, mail_delivered = {},
  codex_update_relaunches = {}, codex_update_state = {}, notice_seen = {}, unread_seeded = {}, mail_resent = {},
}
local mail = {
  mailbox = function() return {} end, is_unread = function() return true end,
  unread = function() return 1 end, find_message = function() return { from = { alias = "alice", id = "a" } } end,
}
local sends, captures, typed = {}, 0, {}
remuda = {
  _butler_notice_config = {
    bus = bus, resolve = function(n) return n end,
    mail_address = function(n) return { alias = n, id = n } end,
    mail_id = function(n) return n, { alias = n, id = n, kind = "claude" } end,
    mail = mail, take_delivery_notice_result = function() end,
    notify_mail_delivery = function() end, deliver_message = function() end,
  },
  _butler_chooser = { known_startup_modal = function() return remuda._test_modal() end },
  _test_modal = function() return false end,
  _butler_agent_startup = { claude = {}, codex = { placeholders = { "Ask Codex to do anything" } } },
  _butler_notice_clock = function() return now end,
  _butler_session_trace = function() end,
  ls = function() return { { name = "lead", alive = true, attached = false, human_idle = math.huge,
    instance_id = "instance-1" } } end,
  capture = function() captures = captures + 1; return remuda._screen end,
  capture_styled = function() return nil end,
  session = function() return { is_busy = false } end,
  type_text = function(_, text) typed[#typed + 1] = text; return "submitted" end,
  key = function() error("notice delivery must not press keys") end,
  butler = { dialogs = { check = function() return true end } },
}
dofile("packages/butler/notice.lua")
remuda._butler_send = function() end
local N = remuda._butler_notice
local deliver = N.deliver_notice
local garbled = "────\n❯ stale text model-refresh error: garbled input\n────"
local draft = "────\n❯ actual draft\n────\n  ⏵⏵ auto mode on"

-- 1. Automatic wakeup: garbled parseable text and real drafts both send once.
for _, screen in ipairs({ garbled, draft, "unrecognized garbled renderer", "" }) do
  sends = {}
  remuda._screen = screen
  bus.notices.lead = { count = 4, message_order = { "m1", "m2", "m3", "m4" },
    message_ids = { m1 = "one", m2 = "two", m3 = "three", m4 = "four" },
    text = "4 new Butler messages arrived", kind = "claude", delivery_attempts = 0 }
  bus.notice_recoveries, bus.notice_screens, bus.notice_fallbacks = {}, {}, {}
  remuda.send = function(_, text) sends[#sends + 1] = text end
  assert(deliver("lead") == true, "the notice is sent regardless of the composer")
  assert(#sends == 1 and bus.notices.lead == nil, "one coalesced send for: " .. screen)
end
assert(captures == 0, "automatic notice delivery never captures the screen")
assert(#typed == 0, "automatic notice delivery never uses type_text")

-- 2. `_butler_notify_policy` (owner lines / first task) keeps its guards.
remuda._screen = garbled
remuda.capture_styled = nil
assert(remuda._butler_prompt_is_empty("claude", garbled) == "NON-EMPTY")
remuda._test_modal = function() return false end
-- A parseable draft is still refused for independent workflows.
assert(remuda._butler_notify_policy("lead") == false, "a parseable draft is refused for owner input")
-- A known modal is refused.
bus.agents.lead.kind = "claude"
remuda._test_modal = function() return true end
assert(remuda._butler_notify_policy("lead") == false, "a known modal is refused")
remuda._test_modal = function() return false end
-- Human activity is refused.
remuda.ls = function() return { { name = "lead", alive = true, attached = true, human_idle = 0,
  instance_id = "instance-1" } } end
assert(remuda._butler_notify_policy("lead") == false, "recent human activity is refused")
-- Detached, empty composer: admitted.
remuda.ls = function() return { { name = "lead", alive = true, attached = false, human_idle = math.huge,
  instance_id = "instance-1" } } end
remuda._screen = "────\n❯ \n────"
assert(remuda._butler_notify_policy("lead") == true, "an empty composer is admitted for owner input")
-- A failed capture is refused (it may hold a draft).
remuda.capture = function() error("capture unavailable") end
assert(remuda._butler_notify_policy("lead") == false, "a capture failure is refused")
print("ok - notices ignore the composer; owner-line policy keeps its guards")
