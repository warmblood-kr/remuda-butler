-- Run from the repository root: luajit tests/butler_notice_retry.lua
local now, sent = 1000, {}
_butler_session_trace = function() end
local bus = {
  agents = { lead = { id = "lead-id", kind = "codex", parent = "root" } },
  notices = { lead = { count = 1, message_order = { "m1" } } },
  pending_tasks = {}, notice_timers = {}, messages = {}, objects = {}, mail_delivered = {},
  codex_update_relaunches = {}, codex_update_state = {},
}
local mail_unread = true
local stored_messages = {
  m1 = { from = { alias = "alice", id = "alice-id" } },
  m2 = { from = { alias = "alice", id = "alice-id" } },
}
local sender_inbox = {}
local mail = {
  mailbox = function(id) if id == "alice-id" then return sender_inbox end; return {} end,
  is_unread = function() return mail_unread end,
  unread = function(id)
    if id == "alice-id" then
      bus.mail_delivered[id] = bus.mail_delivered[id] or {}
      for _, message_id in ipairs(sender_inbox) do bus.mail_delivered[id][message_id] = true end
    end
    return mail_unread and 1 or 0
  end,
  find_message = function(id) return stored_messages[id] end,
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
local failure_id = 0
remuda._butler_send = function(_, to, body)
  sent[#sent + 1] = { to, body }
  if to == "alice" then
    failure_id = failure_id + 1
    local id, object_id = "failure-" .. failure_id, "failure-object-" .. failure_id
    sender_inbox[#sender_inbox + 1] = id
    bus.mail_delivered["alice-id"] = bus.mail_delivered["alice-id"] or {}
    bus.mail_delivered["alice-id"][id] = true
    stored_messages[id] = { from = { alias = "butler" }, body = { object_id = object_id } }
    bus.objects[object_id] = { content = body }
  end
end
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
assert(sent[1][1] == "alice", "failure mail goes to the sender of the original mail")
assert(sent[1][2]:find('remuda butler send "lead" "read your inbox"', 1, true),
  "failure mail contains an exact action command")
assert(sent[1][2]:find("m2", 1, true), "failure mail covers notices coalesced during retries")
assert(bus.notices.lead == nil, "exhausted notice is removed")
remuda._butler_notice.notice_recovery_error("lead", { message_ids = { "m1" }, draft = "" }, "again")
assert(#sent == 1, "the exhausted notice alerts only once")

-- Re-seeded unread mail after a daemon restart still finds the durable marker
-- in the sender's delivered mail, so it cannot create another failure notice.
bus.notice_failure_alerts, bus.notice_delivery_failures = {}, {}
bus.notices.lead = { count = 1, message_order = { "m1" }, delivery_attempts = 4 }
remuda._butler_notice.notice_recovery_error("lead", { message_ids = { "m1" }, draft = "" }, "again after restart")
assert(#sent == 1, "a restart does not send a second failure notice for the same original mail")

-- A failure notice to the root Butler is recorded locally instead of mailing
-- itself and re-queuing the same failure indefinitely.
bus.agents.butler = { id = "butler-id", kind = "claude" }
bus.notices.butler = { count = 1, message_order = { "m1" }, delivery_attempts = 4 }
remuda._butler_notice.notice_recovery_error("butler", { message_ids = { "m1" }, draft = "" }, "root failure")
assert(#sent == 1 and bus.notice_delivery_failures.butler,
  "root Butler records failure state without sending itself failure mail")

-- A sender without a Butler mailbox identity receives the failure through
-- the recipient's leader instead of silently losing the alert.
bus.agents.root = { id = "root-id", kind = "codex" }
stored_messages.m3 = { from = { alias = "matrix", id = "" } }
bus.notice_failure_alerts.lead = nil
bus.notices.lead = { count = 1, message_order = { "m3" }, delivery_attempts = 4 }
remuda._butler_notice.notice_recovery_error("lead", {
  message_ids = { "m3" }, draft = "",
}, "recovery timed out")
assert(sent[#sent][1] == "root",
  "id-less CLI/Matrix sender failure falls back to recipient leader")
bus.agents.orphan = { id = "orphan-id", kind = "codex" }
stored_messages.m4 = { from = { alias = "operator", id = "" } }
bus.notice_failure_alerts.orphan = nil
bus.notices.orphan = { count = 1, message_order = { "m4" }, delivery_attempts = 4 }
remuda._butler_notice.notice_recovery_error("orphan", {
  message_ids = { "m4" }, draft = "",
}, "recovery timed out")
assert(sent[#sent][1] == "butler", "leaderless recipient failure falls back to root Butler")

-- If type_text reports another write in flight, a later non-empty composer is
-- re-probed before any retry; another sender's task or human draft is untouched.
now, screen = now + 10, "› Ask Codex to do anything"
bus.agents.lead.id = "lead-id"
bus.notices.lead, bus.notice_recoveries.lead = nil, nil
remuda._butler_human_active = function() return false end
remuda.session = function() return { is_busy = false } end
local type_attempts, unsafe_writes = 0, {}
remuda.capture = function() return screen end
remuda.key = function(_, key) unsafe_writes[#unsafe_writes + 1] = "key " .. key end
remuda.type_text = function(_, value)
  type_attempts = type_attempts + 1
  if type_attempts == 1 then error("a session input write is already in flight") end
  unsafe_writes[#unsafe_writes + 1] = "type " .. value
end
assert(not remuda._butler_notify("lead", "queued notice"))
now = now + 2
remuda._butler_deliver_notices()
assert(type_attempts == 1 and bus.notice_recoveries.lead == nil,
  "busy input does not retain an unconditional retry_type phase")
screen = "› another sender's task text / human draft"
now = now + 1.1
remuda._butler_deliver_notices()
assert(type_attempts == 1 and #unsafe_writes == 0,
  "a retry never types or submits into the non-empty composer")

-- A successful manual mail resend clears the matching failed first-task marker.
bus.notices.lead, bus.notice_recoveries.lead = nil, nil
bus.task_poke_failures = { lead = { task = "manual resend body", reason = "submit" } }
bus.task_poke_failure_alerts = { lead = true }
stored_messages.m5 = { body = { object_id = "manual-resend-object" } }
bus.objects["manual-resend-object"] = { content = "manual resend body" }
remuda._butler_notice.complete_notice_recovery("lead", { message_ids = { "m5" } })
assert(bus.task_poke_failures.lead == nil and bus.task_poke_failure_alerts.lead == nil,
  "verified manual resend clears the task-failed marker and alert guard")

-- A human draft is left exactly where it is; recovery neither clears it nor types over it.
now, screen = now + 10, "› private draft"
local input_events = {}
remuda.capture = function() return screen end
remuda.key = function(_, key) input_events[#input_events + 1] = "key " .. key end
remuda.type_text = function(_, value) input_events[#input_events + 1] = "type " .. value end
remuda.session = function() return { is_busy = true } end
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
