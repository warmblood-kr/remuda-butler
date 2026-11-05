-- Run from the repository root: luajit tests/butler_native_task.lua
-- Native first-task policy: full durable mail, no composer/helper text, and a
-- truthful report when the write fails. Pure injected seams; no daemon.
remuda = {}
local module = dofile("packages/butler/native_task.lua")

-- 1. Native and sticky-disabled bindings own the first task; a PTY session
-- keeps the legacy typed path.
assert(module.route({ native = { mode = "native" } }), "native routes to mail")
assert(module.route({ native = { mode = "disabled" } }), "disabled still routes to mail")
assert(not module.route({ native = { mode = "pty" } }), "PTY keeps the typed path")
assert(not module.route({}), "unbound keeps the typed path")

-- 2. The whole body is written to durable mail; nothing types it.
local body = "do the full task\n" .. string.rep("x", 9000)
local calls = { queued = {}, sent = {}, traced = {} }
local self = {
  queue_message = function(from, to, text, subject)
    calls.queued[#calls.queued + 1] = { from = from, to = to, text = text, subject = subject }
    return { id = "msg_task_1" }
  end,
  mail_address = function(name) return { alias = name, id = name } end,
  send = function(from, to, text) calls.sent[#calls.sent + 1] = { from = from, to = to, text = text } end,
  trace = function(event, detail) calls.traced[#calls.traced + 1] = { event, detail } end,
}
local id, why = module.queue(self, "m1", "lead", body)
assert(id == "msg_task_1" and why == nil, "the durable message id is returned")
assert(#calls.queued == 1 and calls.queued[1].text == body,
  "the exact full body, including newlines and length, is persisted")
assert(calls.queued[1].to.alias == "m1" and calls.queued[1].from.alias == "lead"
  and calls.queued[1].subject == "Task", "mail goes from the leader to the member as a Task")
assert(#calls.sent == 0, "a successful durable write sends no fallback report")
assert(calls.traced[1][1] == "first_task_native_mail"
  and calls.traced[1][2]:find("msg_task_1", 1, true) ~= nil, "the write is traced")

-- 3. A failed write is reported explicitly and never becomes a typed task.
local failed = {
  queue_message = function() return nil, "mailbox full" end,
  mail_address = function(name) return { alias = name, id = name } end,
  send = function(from, to, text) calls.sent[#calls.sent + 1] = { from = from, to = to, text = text } end,
  trace = function(event, detail) calls.traced[#calls.traced + 1] = { event, detail } end,
}
calls.sent, calls.traced = {}, {}
local failed_id = module.queue(failed, "m1", "lead", "a task")
assert(failed_id == nil, "a failed write returns no message id")
assert(#calls.sent == 1 and calls.sent[1].to == "lead", "the leader is told once")
assert(calls.sent[1].text:find("not typed into the native session", 1, true) ~= nil,
  "the report explicitly says nothing was typed")
assert(calls.sent[1].text:find("mailbox full", 1, true) ~= nil, "the real reason is reported")
assert(calls.traced[1][1] == "first_task_native_mail_failed", "the failure is traced")

-- 4. Missing or empty input never reaches a write.
assert(module.queue(self, "m1", "lead", "") == nil, "an empty task is refused")
assert(module.queue({}, "m1", "lead", "task") == nil, "missing mail seams are refused")

print("ok - native first tasks are durable mail only, never composer text")
