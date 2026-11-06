-- Run from the repository root: luajit tests/butler_native_task.lua
-- New-task routing for known native-capable members: full durable mail, one
-- canonical notify with the same saved id, and a truthful report on storage
-- failure. Pure injected seams; no daemon or live text path.
remuda = {}
local module = dofile("packages/butler/native_task.lua")

-- 1. Route known three kinds and sticky native ownership. Unknown unbound keeps
-- the legacy typed path; unknown with a native binding never body-types.
assert(module.route({ native = { mode = "native" } }, "codex"), "native routes")
assert(module.route({ native = { mode = "disabled" } }, "opencode"), "disabled routes")
assert(module.route({}, "claude"), "unbound known kind routes")
assert(module.route({ native = { mode = "native" } }, "something"), "sticky unknown routes")
assert(not module.route({}, "something"), "unknown unbound keeps legacy")
assert(module.route({ native = { mode = "pty" } }, "codex"), "unbound known kind routes")

-- 2. The whole body is written once; the shared notify gets the same message.
local body = "do the full task\n" .. string.rep("x", 9000)
local calls = { queued = {}, notified = {}, sent = {}, traced = {} }
local self = {
  queue_message = function(from, to, text, subject)
    calls.queued[#calls.queued + 1] = { from = from, to = to, text = text, subject = subject }
    return { id = "msg_task_1", from = from, to = to, subject = subject }
  end,
  mail_address = function(name) return { alias = name, id = name } end,
  notify = function(message, delivered)
    calls.notified[#calls.notified + 1] = { message = message, delivered = delivered }
    return delivered
  end,
  send = function(from, to, text) calls.sent[#calls.sent + 1] = { from = from, to = to, text = text } end,
  trace = function(event, detail) calls.traced[#calls.traced + 1] = { event, detail } end,
}
local id, why, info = module.queue(self, "m1", "lead", body, "codex")
assert(id == "msg_task_1" and why == nil and info.saved == true, "durable id returned")
assert(#calls.queued == 1 and calls.queued[1].text == body,
  "exact full body, including newlines and length, is persisted once")
assert(calls.queued[1].to.alias == "m1" and calls.queued[1].from.alias == "lead"
  and calls.queued[1].subject == "Task", "mail goes leader -> member as a Task")
assert(#calls.notified == 1 and calls.notified[1].delivered.id == "msg_task_1",
  "the shared notify is called once with the same saved message")
assert(info.notice == "attempted" and #calls.sent == 0, "no fallback report on success")
assert(calls.traced[1][1] == "first_task_native_mail"
  and calls.traced[1][2]:find("msg_task_1", 1, true) ~= nil, "the write is traced")

-- 3. A storage failure is not a success: no notify, one truthful leader report.
local failed = {
  queue_message = function() return nil, "mailbox full" end,
  mail_address = function(name) return { alias = name, id = name } end,
  notify = function() calls.notified[#calls.notified + 1] = true end,
  send = function(from, to, text) calls.sent[#calls.sent + 1] = { from = from, to = to, text = text } end,
  trace = function(event, detail) calls.traced[#calls.traced + 1] = { event, detail } end,
}
calls.sent, calls.traced, calls.notified = {}, {}, {}
local failed_id, failed_why, failed_info = module.queue(failed, "m1", "lead", "a task", "codex")
assert(failed_id == nil and failed_info.saved == false and failed_info.stage == "storage",
  "storage failure is typed distinctly")
assert(#calls.notified == 0, "a storage failure never notifies")
assert(#calls.sent == 1 and calls.sent[1].to == "lead", "the leader is told once")
assert(calls.sent[1].text:find("not typed into the member session", 1, true) ~= nil,
  "the report explicitly says nothing was typed")
assert(calls.sent[1].text:find("mailbox full", 1, true) ~= nil, "the real reason is reported")
assert(calls.traced[1][1] == "first_task_native_mail_failed", "the failure is traced")

-- 4. A notify failure keeps the durable id and is reported as notify, not storage.
local notify_fail = {
  queue_message = function(from, to) return { id = "msg_task_2", from = from, to = to } end,
  mail_address = function(name) return { alias = name, id = name } end,
  notify = function() error("policy unavailable", 0) end,
  send = function() error("must not report storage failure") end,
  trace = function(event, detail) calls.traced[#calls.traced + 1] = { event, detail } end,
}
calls.traced = {}
local nid, nwhy, ninfo = module.queue(notify_fail, "m1", "lead", "task", "claude")
assert(nid == "msg_task_2" and nwhy == nil and ninfo.saved == true,
  "a notify failure keeps the saved id")
assert(ninfo.notice == "error" and ninfo.stage == "notify"
  and ninfo.notice_error:find("policy unavailable", 1, true),
  "notify failure is distinct from storage failure")
local traced_notify_failure = false
for _, row in ipairs(calls.traced) do
  if row[1] == "first_task_native_notify_failed" then traced_notify_failure = true end
end
assert(traced_notify_failure, "notify failure is traced")

-- 4b. A refused notify return is an error, not an attempted delivery.
local refused_sends = {}
local refused_notify = {
  queue_message = function(from, to) return { id = "msg_task_3", from = from, to = to } end,
  mail_address = function(name) return { alias = name, id = name } end,
  notify = function() return false, "policy_deferred" end,
  send = function(_, to, text) refused_sends[#refused_sends + 1] = { to = to, text = text } end,
  trace = function() end,
}
local rid, _, rinfo = module.queue(refused_notify, "m1", "lead", "task", "opencode")
assert(rid == "msg_task_3" and rinfo.notice == "error" and rinfo.stage == "notify"
  and rinfo.notice_error:find("policy_deferred", 1, true), "false notify is an error")
assert(#refused_sends == 1 and refused_sends[1].to == "lead"
  and refused_sends[1].text:find("saved as durable mail", 1, true), "the saved id is reported")

-- 4c. A nil notify return is unsupported, not an attempted delivery.
local nil_notify = {
  queue_message = function(from, to) return { id = "msg_task_4", from = from, to = to } end,
  mail_address = function(name) return { alias = name, id = name } end,
  notify = function() return nil end,
  send = function() end,
  trace = function() end,
}
local nid2, _, ninfo2 = module.queue(nil_notify, "m1", "lead", "task", "codex")
assert(nid2 == "msg_task_4" and ninfo2.notice == "error"
  and ninfo2.notice_error == "notify_unavailable" and ninfo2.stage == "notify",
  "a nil notify return is an error, never attempted")

-- 5. Missing or empty input never reaches a write.
assert(module.queue(self, "m1", "lead", "") == nil, "an empty task is refused")
assert(module.queue({}, "m1", "lead", "task") == nil, "missing mail seams are refused")

print("ok - new tasks are durable mail plus one same-id pointer, never body text")
