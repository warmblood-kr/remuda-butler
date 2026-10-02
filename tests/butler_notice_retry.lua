-- Run from the repository root: luajit tests/butler_notice_retry.lua
local now, sent = 1000, {}
_butler_session_trace = function() end
local bus = {
  agents = { lead = { id = "lead-id", kind = "codex", parent = "root" } },
  notices = { lead = { count = 1, message_order = { "m1" } } },
  pending_tasks = {}, notice_timers = {},
}
local mail_unread = true
local mail = {
  mailbox = {}, is_unread = function() return mail_unread end,
  unread = function() return mail_unread and 1 or 0 end,
}
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
  ls = function() return { { name = "lead", alive = true, attached = false } } end,
  capture = function() return "› Ask Codex to do anything" end,
  session = function() return { is_busy = true } end,
}
dofile("packages/butler/notice.lua")
remuda._butler_send = function(_, to, body) sent[#sent + 1] = { to, body } end
assert(remuda._butler_notify_policy("lead"), "an empty prompt stays eligible while background work reports busy")

local delays = { 20, 60, 300, 900 }
for attempt, delay in ipairs(delays) do
  local ok = remuda._butler_notice.notice_recovery_error("lead", {
    message_ids = { "m1" }, draft = "", phase = "probe",
  }, "recovery timed out")
  assert(ok == false, "failed recovery waits for its next scheduled attempt")
  assert(bus.notices.lead.delivery_attempts == attempt, "attempt count advances")
  assert(bus.notices.lead.due_at == now + delay, "attempt uses configured backoff")
  assert(#sent == 0, "no failure mail is sent before retries run out")
  if attempt == 1 then
    remuda._butler_notify("lead", "second message", "m2")
    assert(bus.notices.lead.due_at == now + delay, "new mail does not shorten the backoff")
  end
  now = now + delay
end
remuda._butler_notice.notice_recovery_error("lead", {
  message_ids = { "m1" }, draft = "", phase = "probe",
}, "recovery timed out")
assert(#sent == 1, "exhaustion sends one failure mail, got " .. #sent
  .. "; pending=" .. tostring(bus.notices.lead) .. "; attempts="
  .. tostring(bus.notices.lead and bus.notices.lead.delivery_attempts))
assert(sent[1][1] == "root", "failure mail goes to the sender's leader")
assert(sent[1][2]:find("Inspect the composer, then resend the notice", 1, true), "failure mail explains the next action")
assert(sent[1][2]:find("m2", 1, true), "failure mail covers notices coalesced during retries")
assert(bus.notices.lead == nil, "exhausted notice is removed")
remuda._butler_notice.notice_recovery_error("lead", { message_ids = { "m1" }, draft = "" }, "again")
assert(#sent == 1, "the exhausted notice alerts only once")

-- A human draft is left exactly where it is; recovery neither clears it nor types over it.
now, screen = now + 10, "› private draft"
local input_events = {}
remuda.capture = function() return screen end
remuda.key = function(_, key) input_events[#input_events + 1] = "key " .. key end
remuda.type_text = function(_, value) input_events[#input_events + 1] = "type " .. value end
remuda.after = nil
bus.agents.lead.id = nil
bus.notices.lead = nil
bus.notice_recoveries.lead = nil
bus.pending_tasks.lead = nil
bus.codex_update_state, bus.codex_update_relaunches = {}, {}
assert(not remuda._butler_notify("lead", "queued notice"))
now = now + 2
remuda._butler_deliver_notices()
remuda._butler_deliver_notices()
assert(#input_events == 0, "a non-empty composer receives no keys or typed text")
assert(bus.notices.lead and bus.notice_recoveries.lead.phase == "probe", "draft blocks the queued notice safely")
bus.notices.lead, bus.notice_recoveries.lead = nil, nil
bus.agents.lead.id, mail_unread = "lead-id", true
assert(not remuda._butler_notify("lead", "readable mail", "m3"))
mail_unread = false
now = now + 2
remuda._butler_deliver_notices()
assert(bus.notices.lead == nil and bus.notice_recoveries.lead == nil, "reading mail cancels queued retries")
bus.agents.lead.id = nil
mail_unread = true
assert(not remuda._butler_notify("lead", "mail for gone recipient", "m4"))
bus.agents.lead = nil
remuda._butler_deliver_notices()
assert(bus.notices.lead == nil, "recipient exit cancels queued retries")
print("ok - retries back off, respect empty busy prompt, and alert once on exhaustion")
