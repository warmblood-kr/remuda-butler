-- Run from the repository root: luajit tests/butler_notice_stuck.lua
-- Retry exhaustion: one sender notice, no reminder re-arm, one deduped hourly leader report.
local now, sent, unread = 1000, {}, true
_butler_session_trace = function() end
local bus = {
  agents = { lead = { id = "lead-id", kind = "claude", parent = "root" }, root = { id = "root-id", kind = "claude" } },
  notices = { lead = { count = 1, message_order = { "m1" } } },
  pending_tasks = {}, notice_timers = {}, messages = {}, objects = {}, mail_delivered = {},
  codex_update_relaunches = {}, codex_update_state = {},
}
local mail = {
  mailbox = function() return {} end, is_unread = function() return unread end,
  unread = function() return unread and 1 or 0 end,
  find_message = function() return { from = { alias = "alice", id = "alice-id" } } end,
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
  _butler_agent_startup = { claude = {} },
  _butler_notice_clock = function() return now end,
  _butler_session_trace = function() end,
  ls = function() return {} end,
}
dofile("packages/butler/notice.lua")
remuda._butler_send = function(_, to, body) sent[#sent + 1] = { to, body } end
local N = remuda._butler_notice
local function exhaust()
  bus.notices.lead = { count = 1, message_order = { "m1" }, delivery_attempts = 4 }
  N.notice_recovery_error("lead", { message_ids = { "m1" }, draft = "" }, "recovery timed out")
end

exhaust()
local to_sender = #sent
assert(to_sender == 1 and sent[1][1] == "alice", "exhaustion sends one sender notice")
assert(bus.notice_stuck.lead, "exhaustion opens a stuck record")

-- Reminders no longer re-queue: the old path called _butler_notify and re-created bus.notices.lead.
bus.notice_sent_at = { ["lead-id"] = { m1 = now - 3600 } }
bus.notice_reminder_at.lead = nil
local agent = bus.agents.lead
N.remind_unread_notices("lead", agent, now)
assert(bus.notices.lead == nil, "no reminder re-arm after exhaustion")
assert(#sent == to_sender + 1 and sent[#sent][1] == "root", "first reminder tick reports once to the leader")
N.remind_unread_notices("lead", agent, now + 600)
N.remind_unread_notices("lead", agent, now + 3000)
assert(#sent == to_sender + 1, "report is deduped within the hour")
N.remind_unread_notices("lead", agent, now + 3601)
assert(#sent == to_sender + 2, "one report per hour")
-- Reading the mail closes the record and ends reports.
unread = false
N.remind_unread_notices("lead", agent, now + 8000)
assert(bus.notice_stuck.lead == nil and #sent == to_sender + 2, "read mail closes the stuck record")
print("ok")
