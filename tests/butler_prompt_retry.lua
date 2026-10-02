-- Run from the repository root: luajit tests/butler_prompt_retry.lua
local now, alive, screen, input_calls = 100, true, "ready", 0
local done, retries = {}, {}
local poll
remuda = {
  schedule = function(spec) poll = { run = spec.run }; return poll end,
  cancel = function(handle) if handle then handle.cancelled = true end end,
  capture = function() return screen end,
  type_text = function() input_calls = input_calls + 1; error("write refused") end,
}
local prompt = dofile("packages/butler/prompt.lua")
local options = {
  ready = function() return true end,
  allowed = function() return true end,
  empty = function() return "EMPTY", "" end,
  recipient_alive = function() return alive end,
  now = function() return now end,
  on_retry = function(attempt, delay) retries[#retries + 1] = { attempt, delay } end,
  on_done = function(ok, reason) done[#done + 1] = { ok, reason } end,
}
prompt.schedule(remuda, "codex", "member", "member", "lead", "first task", options)
local delays = { 20, 60, 300, 900 }
for index, delay in ipairs(delays) do
  poll.run()
  assert(input_calls == index, "initial task text is retried after each failure")
  assert(#retries == index, "each failed attempt schedules a retry")
  assert(retries[index][1] == index and retries[index][2] == delay, "task retry uses backoff")
  now = now + delay - 1
  poll.run()
  assert(input_calls == index, "task is not typed before the backoff expires")
  now = now + 1
end
poll.run()
assert(input_calls == 5, "last attempt runs after the final backoff")
assert(#done == 1 and done[1][1] == false, "exhaustion completes once with failure")
assert(done[1][2]:find("type failed", 1, true), "failure identifies the last delivery error")
poll.run()
assert(#done == 1, "no duplicate failure callback after exhaustion")

-- A busy pane with an empty composer does not prove that the first task arrived.
now, alive, screen, input_calls, done, retries = 5000, true, "ready", 0, {}, {}
remuda.type_text = function() input_calls = input_calls + 1 end
remuda.session = function() return { is_busy = true } end
prompt.schedule(remuda, "codex", "member", "member", "lead", "first task", {
  ready = function() return true end,
  allowed = function() return true end,
  empty = function() return "EMPTY", "" end,
  recipient_alive = function() return alive end,
  now = function() return now end,
  submit_timeout = 1,
  on_done = function(ok, reason) done[#done + 1] = { ok, reason } end,
})
poll.run()
now = now + 1
poll.run()
assert(#done == 0, "background activity cannot falsely acknowledge unseen task text")
assert(input_calls == 1, "the retry waits instead of overwriting a nonempty composer")

alive = false
poll.run()
assert(#done == 1 and done[1][2] == "recipient gone", "recipient exit stops pending retries")

-- If text reached the composer but Return was dropped, retry Return without retyping.
now, alive, screen, input_calls, done, retries = 7000, true, "ready", 0, {}, {}
local return_calls = 0
remuda.session = function() return { is_busy = false } end
remuda.capture = function() return screen end
remuda.type_text = function(_, text) input_calls = input_calls + 1; screen = text end
remuda.key = function(_, key)
  if key == "RET" then return_calls = return_calls + 1; screen = "first task accepted" end
end
prompt.schedule(remuda, "codex", "member", "member", "lead", "first task", {
  ready = function() return true end,
  allowed = function() return true end,
  empty = function(value)
    if value == "first task" then return "NON-EMPTY", value end
    return "EMPTY", ""
  end,
  recipient_alive = function() return alive end,
  now = function() return now end,
  on_done = function(ok, reason) done[#done + 1] = { ok, reason } end,
})
poll.run()
for _ = 1, 4 do poll.run() end
assert(return_calls == 1, "the observed first task gets one safe Return retry")
poll.run()
assert(input_calls == 1 and #done == 1 and done[1][1] == true,
  "verified task delivery is successful without duplicate text")

-- A draft fails the empty-composer gate; retries never type into it.
now, alive, screen, input_calls, done = 9000, true, "draft", 0, {}
remuda.type_text = function() input_calls = input_calls + 1 end
prompt.schedule(remuda, "codex", "member", "member", "lead", "first task", {
  ready = function() return true end,
  allowed = function() return false end,
  empty = function() return "NON-EMPTY", "private draft" end,
  recipient_alive = function() return alive end,
  now = function() return now end,
  timeout = 1,
  retry_delays = { 0, 0, 0, 0 },
  on_done = function(ok, reason) done[#done + 1] = { ok, reason } end,
})
for _ = 1, 20 do poll.run(); now = now + 0.5 end
assert(input_calls == 0, "first task retries preserve a non-empty draft")
assert(#done == 1 and done[1][1] == false, "draft protection still ends in one failure notice")
assert(loadfile("packages/butler/launch.lua"), "Codex task launcher parses")
print("ok - first task retries until verified, exhaustion reports once, and exit cancels retries")
