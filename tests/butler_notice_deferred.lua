-- Run from the repository root: luajit tests/butler_notice_deferred.lua
local now = 1000
local unread_ids, delivered = {}, {}
local bus = {
  agents = { child = { id = "child-id", kind = "codex", parent = "butler", session_instance_id = "instance-1" } },
  notices = {}, pending_tasks = { child = true }, notice_timers = {}, messages = {}, objects = {},
  mail_delivered = {}, notice_seen = {}, unread_seeded = { child = "instance-1" },
  mail_resent = {},
  codex_update_relaunches = {}, codex_update_state = {},
}
local messages = {}
_butler_session_trace = function() end
local mail = {
  mailbox = function(id) return id == "child-id" and delivered or {} end,
  is_unread = function(id, message_id) return unread_ids[message_id] == true end,
  unread = function(id)
    if id ~= "child-id" then return 0 end
    local count = 0
    for message_id, unread in pairs(unread_ids) do if unread then count = count + 1 end end
    return count
  end,
  find_message = function(id) return messages[id] end,
}
remuda = {
  _butler_notice_config = {
    bus = bus,
    resolve = function(name) return name end,
    mail_address = function(name) return { alias = name, id = name } end,
    mail_id = function(name) return name, { alias = name, id = name, kind = "codex" } end,
    mail = mail, take_delivery_notice_result = function() end,
    notify_mail_delivery = function() end, deliver_message = function() end,
  },
  _butler_chooser = { known_startup_modal = function() return false end },
  _butler_agent_startup = { codex = { placeholders = { "Ask Codex to do anything" } } },
  _butler_notice_clock = function() return now end,
  _butler_session_trace = function() end,
  _butler_notify_policy = function() return true end,
  ls = function() return { { name = "child", alive = true, attached = false, instance_id = "instance-1" } } end,
  capture = function() return "› Ask Codex to do anything" end,
  session = function() return { is_busy = false } end,
}
dofile("packages/butler/notice.lua")
remuda._butler_notify_policy = function() return true end

-- Mail can arrive during the first task after an empty inbox was marked seeded.
-- Once the task completes, the same launch instance must seed that deferred mail.
local first = { id = "first-task-mail", from = { alias = "butler", id = "butler-id" } }
messages[first.id] = first
delivered[#delivered + 1], unread_ids[first.id] = first.id, true
remuda._butler_deliver_notices()
assert(bus.notices.child == nil, "a pending first task keeps mail notices out of the first prompt")
bus.pending_tasks.child = nil
remuda._butler_deliver_notices()
assert(bus.notices.child and bus.notices.child.message_ids[first.id],
  "mail that arrived during the first task is noticed after that task completes; seeded="
    .. tostring(bus.unread_seeded.child) .. ", unread=" .. tostring(mail.unread("child-id"))
    .. ", seen=" .. tostring(bus.notice_seen["child-id"] and bus.notice_seen["child-id"][first.id]))

-- A successfully delivered notice leaves a timestamp. Once unread for ten
-- minutes, it is queued again; a read message is never re-notified.
bus.notices.child = nil
bus.notice_recoveries.child = nil
bus.notice_seen["child-id"] = nil
bus.notice_sent_at = { ["child-id"] = { [first.id] = now - 600 } }
bus.notice_reminder_at = { child = now }
now = now + 600
remuda._butler_deliver_notices()
assert(bus.notices.child and bus.notices.child.reminders[first.id],
  "an unread mail is re-notified after ten minutes")

bus.notices.child = nil -- model the successful delivery of that reminder
bus.notice_sent_at["child-id"][first.id] = now
now = now + 599
remuda._butler_deliver_notices()
assert(bus.notices.child == nil, "the next reminder waits ten more minutes")
now = now + 1
remuda._butler_deliver_notices()
assert(bus.notices.child and bus.notices.child.reminders[first.id],
  "an unread mail is re-notified again after another ten minutes")

unread_ids[first.id] = false
now = now + 3
remuda._butler_deliver_notices()
assert(bus.notices.child == nil, "a read mail is not re-notified")
print("ok - deferred first-task mail and unread reminders")
