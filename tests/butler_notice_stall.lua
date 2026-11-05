-- Run from the repository root: luajit tests/butler_notice_stall.lua
local now, sent = 1000, {}
_butler_session_trace = function() end
local bus = {
  agents = { lead = { id = "lead-id", kind = "codex", parent = "root" } },
  notices = { lead = { count = 1, message_order = { "m1" }, message_ids = { m1 = "notice" } } },
  pending_tasks = {}, notice_timers = {}, messages = {}, objects = {}, mail_delivered = {},
  codex_update_relaunches = {}, codex_update_state = {},
}
local stored_messages = { m1 = { from = { alias = "alice", id = "alice-id" } } }
local sender_inbox = {}
local mail = {
  mailbox = function(id) if id == "alice-id" then return sender_inbox end; return {} end,
  is_unread = function() return true end,
  unread = function() return 1 end,
  find_message = function(id) return stored_messages[id] end,
}
local human_idle = 0
remuda = {
  _butler_notice_config = {
    bus = bus, resolve = function(name) return name end,
    mail_address = function(name) return { alias = name, id = name } end,
    mail_id = function(name) return name, { alias = name, id = name, kind = "codex" } end,
    mail = mail, take_delivery_notice_result = function() end,
    notify_mail_delivery = function() end, deliver_message = function() end,
  },
  _butler_chooser = { known_startup_modal = function() return false end },
  _butler_agent_startup = { codex = { placeholders = { "Ask Codex to do anything" } } },
  _butler_notice_clock = function() return now end,
  _butler_session_trace = function() end,
  ls = function() return { { name = "lead", alive = true, attached = true, human_idle = human_idle } } end,
  capture = function() return "› Ask Codex to do anything" end,
  session = function() return { is_busy = false } end,
}
dofile("tests/notice_journal_stub.lua")
dofile("packages/butler/notice.lua")
remuda._butler_send = function(_, to, body) sent[#sent + 1] = { to, body } end

-- A codex pane with a warning row under an empty composer is still empty.
local decision = remuda._butler_prompt_is_empty("codex", "› \n⚠ 3 warnings · f2 to view\n")
assert(decision == "EMPTY", "a warning row below the composer is not composer text, got " .. decision)
local text_decision = remuda._butler_prompt_is_empty("codex", "› draft text\n⚠ 3 warnings · f2 to view\n")
assert(text_decision == "NON-EMPTY", "real composer text stays non-empty, got " .. text_decision)
local blank_draft = remuda._butler_prompt_is_empty("codex", "› \n⚠ my own note\n")
assert(blank_draft == "NON-EMPTY", "only the warning-count footer ends the composer, got " .. blank_draft)

-- No stall clock exists any more: the first due tick attempts the ordinary
-- atomic send, even while a human is attached (owner decision 2026-11-05).
-- Attachment is not an admission gate and there is no attachment stall record.
local deliver = remuda._butler_notice.deliver_notice
local sends = 0
remuda.send = function() sends = sends + 1 end
deliver("lead")
assert(sends == 1, "an attached pane receives the notice")
assert(bus.notices.lead == nil, "the attached delivery completes")
assert(bus.notice_stuck.lead == nil, "attachment creates no stuck record")
assert(#sent == 0, "no failure mail for an attached pane")

-- A dead session takes the bounded schedule and eventually alerts the sender.
bus.agents.lead.id = "lead-id"
remuda.ls = function() return { { name = "lead", alive = false, attached = false } } end
bus.notices.lead = { count = 1, message_order = { "m1" }, message_ids = { m1 = "notice" }, text = "notice" }
bus.notice_failure_alerts, bus.notice_stuck, bus.notice_uncertain_alerts = {}, {}, {}
remuda.send = function() error("must not send to a dead session") end
deliver("lead")
assert(bus.notices.lead.delivery_attempts == 1, "a dead pane starts the bounded schedule")
for attempt = 2, 4 do
  now = bus.notices.lead.retry_at
  deliver("lead")
  assert(bus.notices.lead.delivery_attempts == attempt, "dead-pane attempt " .. attempt)
end
now = bus.notices.lead.retry_at
deliver("lead")
assert(bus.notices.lead == nil, "an exhausted dead-pane notice leaves the queue")
local to_alice
for _, row in ipairs(sent) do if row[1] == "alice" then to_alice = row end end
assert(to_alice and to_alice[2]:find("Could not safely deliver", 1, true),
  "after the last retry the sender gets the failure notice")
print("ok - no stall clock: atomic sends, attachment refusal, bounded failure")
