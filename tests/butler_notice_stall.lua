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
dofile("packages/butler/notice.lua")
remuda._butler_send = function(_, to, body) sent[#sent + 1] = { to, body } end

-- A codex pane with a warning row under an empty composer is still empty.
local decision = remuda._butler_prompt_is_empty("codex", "› \n⚠ 3 warnings · f2 to view\n")
assert(decision == "EMPTY", "a warning row below the composer is not composer text, got " .. decision)
local text_decision = remuda._butler_prompt_is_empty("codex", "› draft text\n⚠ 3 warnings · f2 to view\n")
assert(text_decision == "NON-EMPTY", "real composer text stays non-empty, got " .. text_decision)
local blank_draft = remuda._butler_prompt_is_empty("codex", "› \n⚠ my own note\n")
assert(blank_draft == "NON-EMPTY", "only the warning-count footer ends the composer, got " .. blank_draft)

-- A pane the policy never accepts (a human keeps typing) while its composer reads empty:
-- the stall becomes a failed attempt, then the retry schedule, then the sender's failure notice.
local deliver = remuda._butler_notice.deliver_notice
assert(not remuda._butler_notify_policy("lead", now), "policy is false while a human is active")
deliver("lead")
assert(bus.notices.lead.delivery_attempts == nil, "the first stalled tick only starts the clock")
now = now + 119
deliver("lead")
assert(bus.notices.lead.delivery_attempts == nil, "no attempt is charged before the stall limit")
now = now + 2
deliver("lead")
assert(bus.notices.lead.delivery_attempts == 1, "a stall past the limit is one failed attempt")
assert(bus.notices.lead.retry_at == now + 20, "the stall uses the retry schedule")
assert(#sent == 0, "no failure mail yet")
for attempt = 2, 4 do
  now = bus.notices.lead.retry_at
  deliver("lead")
  now = now + 121
  deliver("lead")
  assert(bus.notices.lead.delivery_attempts == attempt, "stall attempt " .. attempt)
end
now = bus.notices.lead.retry_at
deliver("lead")
now = now + 121
deliver("lead")
local to_alice
for _, row in ipairs(sent) do if row[1] == "alice" then to_alice = row end end
assert(to_alice, "after the last retry the sender gets the failure notice")

-- A pane that passes the policy clears the stall clock.
bus.notices.lead = { count = 1, message_order = { "m1" }, message_ids = { m1 = "notice" }, stalled_at = now - 500 }
human_idle = math.huge
remuda.type_text = function() return true end
deliver("lead")
assert(bus.notices.lead == nil or bus.notices.lead.stalled_at == nil, "delivery clears the stall clock")
print("ok - stalled notice delivery")
