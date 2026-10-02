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
  on_done = function(ok, reason, attempts) done[#done + 1] = { ok, reason, attempts } end,
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
assert(done[1][3] == 5, "five actual prompt attempts are reported accurately")
poll.run()
assert(#done == 1, "no duplicate failure callback after exhaustion")

-- Codex startup and shared prompt delivery consume one retry budget, so the
-- prompt callback adds its remaining attempts to failures already used.
now, alive, screen, input_calls, done = 3000, true, "ready", 0, {}
remuda.type_text = function() input_calls = input_calls + 1; error("write refused") end
prompt.schedule(remuda, "codex", "member", "member", "lead", "first task", {
  ready = function() return true end,
  allowed = function() return true end,
  empty = function() return "EMPTY", "" end,
  recipient_alive = function() return alive end,
  now = function() return now end,
  prior_failures = 2,
  retry_delays = { 0 },
  on_done = function(ok, reason, attempts) done[#done + 1] = { ok, reason, attempts } end,
})
poll.run()
poll.run()
assert(input_calls == 2 and #done == 1 and done[1][3] == 4,
  "the prompt shares prior Codex failures and reports the combined attempt count")

now, alive, screen, input_calls, done = 4000, true, "ready", 0, {}
remuda.type_text = function()
  input_calls = input_calls + 1
  if input_calls == 1 then return false end
  return "submitted"
end
prompt.schedule(remuda, "codex", "member", "member", "lead", "first task", {
  ready = function() return true end,
  allowed = function() return true end,
  empty = function() return "EMPTY", "" end,
  recipient_alive = function() return alive end,
  now = function() return now end,
  retry_delays = { 0 },
  on_done = function(ok, reason) done[#done + 1] = { ok, reason } end,
})
poll.run()
poll.run()
poll.run()
assert(input_calls == 2 and #done == 1 and done[1][1] == true,
  "a false write result retries before being counted as delivered")

-- A successful task write followed by an empty composer proves that the TUI
-- accepted it, even if the first capture missed the text while background
-- activity made the pane report busy.
now, alive, screen, input_calls, done, retries = 5000, true, "ready", 0, {}, {}
remuda.type_text = function() input_calls = input_calls + 1; return "submitted" end
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
assert(#done == 1 and done[1][1] == true, "successful write plus empty composer is accepted")
assert(input_calls == 1, "an empty composer after an accepted write is never retyped")

alive = false
poll.run()
assert(#done == 1, "completed delivery does not emit another callback after recipient exit")

-- A fast Codex submit can empty the composer before the first verification
-- capture. Once type_text returned successfully, that empty composer proves
-- acceptance and must never trigger a second write after submit_timeout.
now, alive, screen, input_calls, done, retries = 6000, true, "ready", 0, {}, {}
local busy = true
remuda.session = function() return { is_busy = busy } end
remuda.type_text = function() input_calls = input_calls + 1; busy = true; return "submitted" end
prompt.schedule(remuda, "codex", "member", "member", "lead", string.rep("long first task\n", 80), {
  ready = function() return true end,
  allowed = function() return true end,
  empty = function() return "EMPTY", "" end,
  recipient_alive = function() return alive end,
  now = function() return now end,
  submit_timeout = 1,
  retry_delays = { 0, 0, 0, 0 },
  on_done = function(ok, reason) done[#done + 1] = { ok, reason } end,
})
poll.run()
now = now + 1
poll.run()
assert(input_calls == 1, "successful write was duplicated when the first poll saw an empty composer")
assert(#done == 1 and done[1][1] == true, "empty composer after a successful write is delivered")

-- If text reached the composer but Return was dropped, retry Return without retyping.
now, alive, screen, input_calls, done, retries = 7000, true, "ready", 0, {}, {}
local return_calls = 0
remuda.session = function() return { is_busy = false } end
remuda.capture = function() return screen end
remuda.type_text = function(_, text) input_calls = input_calls + 1; screen = text; return "submitted" end
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

-- A submit timeout keeps successful writes in the verification path. The
-- retry may press Return once when our exact task is still in the composer.
now, alive, screen, input_calls, done = 8000, true, "ready", 0, {}
return_calls = 0
remuda.type_text = function(_, text) input_calls = input_calls + 1; screen = text end
remuda.key = function(_, key)
  assert(key == "RET")
  return_calls = return_calls + 1
  screen = "accepted task"
end
prompt.schedule(remuda, "codex", "member", "member", "lead", "retry task", {
  ready = function(value) return value == "ready" end,
  allowed = function() return true end,
  empty = function(value)
    if value == "retry task" then return "NON-EMPTY", value end
    return "EMPTY", ""
  end,
  recipient_alive = function() return alive end,
  now = function() return now end,
  submit_timeout = 1,
  retry_delays = { 0 },
  on_done = function(ok) done[#done + 1] = ok end,
})
poll.run()
now = now + 1
poll.run() -- verification times out and schedules retry
for _ = 1, 4 do poll.run() end
assert(input_calls == 1 and return_calls == 1,
  "successful write retry must submit once without typing the task twice")
poll.run()
assert(#done == 1 and done[1] == true, "retry Return completes delivery")

-- An unverified write plus a blank capture is ambiguous: the task may still
-- be sitting in the composer, so Butler must not report it delivered.
now, alive, screen, input_calls, done = 8500, true, "ready", 0, {}
remuda.type_text = function() input_calls = input_calls + 1; return "unverified" end
prompt.schedule(remuda, "codex", "member", "member", "lead", "ambiguous task", {
  ready = function() return true end,
  allowed = function() return true end,
  empty = function() return "EMPTY", "" end,
  recipient_alive = function() return alive end,
  now = function() return now end,
  submit_timeout = 1,
  retry_delays = { 0, 0, 0, 0 },
  on_done = function(ok, reason) done[#done + 1] = { ok, reason } end,
})
poll.run()
poll.run()
assert(input_calls == 1 and #done == 0,
  "blank capture after an unverified write must not count as delivered")
now = now + 1
poll.run()
assert(input_calls == 1 and #done == 1 and done[1][1] == false and done[1][2] == "submit",
  "an unverified write ends once at the first submit timeout without a false success")
poll.run()
assert(input_calls == 1 and #done == 1, "submit timeout does not start a 46-minute retry loop")

-- If the unverified write is still represented by a paste placeholder, seeing
-- it in the composer counts as our task being observed. A later blank capture
-- then verifies that it was submitted without typing it again.
now, alive, screen, input_calls, done = 8550, true, "ready", 0, {}
remuda.capture = function() return screen end
remuda.type_text = function()
  input_calls = input_calls + 1
  screen = "Ask Codex\n❯ [Pasted text #1 +2 lines]"
  return "unverified"
end
prompt.schedule(remuda, "codex", "member", "member", "lead", "paste task\nsecond line", {
  ready = function() return true end,
  allowed = function() return true end,
  empty = function(value)
    local composer = value:match("❯ (.*)$") or ""
    if composer:find("[Pasted text #1 +2 lines]", 1, true) then return "NON-EMPTY", composer end
    return "EMPTY", ""
  end,
  recipient_alive = function() return alive end,
  now = function() return now end,
  submit_timeout = 10,
  on_done = function(ok, reason) done[#done + 1] = { ok, reason } end,
})
poll.run()
poll.run()
screen = "Ask Codex\n❯ "
poll.run()
assert(input_calls == 1 and #done == 1 and done[1][1] == true,
  "observed paste placeholder followed by blank composer confirms one delivery")

-- The core's submitted status is sufficient confirmation of an empty prompt.
now, alive, screen, input_calls, done = 8600, true, "ready", 0, {}
remuda.type_text = function() input_calls = input_calls + 1; return "submitted" end
prompt.schedule(remuda, "codex", "member", "member", "lead", "confirmed task", {
  ready = function() return true end,
  allowed = function() return true end,
  empty = function() return "EMPTY", "" end,
  recipient_alive = function() return alive end,
  now = function() return now end,
  on_done = function(ok) done[#done + 1] = ok end,
})
poll.run()
poll.run()
assert(input_calls == 1 and #done == 1 and done[1] == true,
  "submitted write status confirms an empty composer")

-- A quote-prefixed task can look like transcript text to the composer parser.
-- That ambiguous NON-EMPTY screen is not proof that a dropped Return worked.
now, alive, screen, input_calls, done = 9000, true, "ready", 0, {}
remuda.type_text = function(_, text) input_calls = input_calls + 1; screen = "› " .. text end
remuda.key = function() end
prompt.schedule(remuda, "codex", "member", "member", "lead", "> quoted task", {
  ready = function(value) return value == "ready" or value:find("› ", 1, true) ~= nil end,
  allowed = function() return true end,
  empty = function(value)
    if value == "› > quoted task" then return "NON-EMPTY", "quoted task" end
    return "EMPTY", ""
  end,
  recipient_alive = function() return alive end,
  now = function() return now end,
  submit_timeout = 100,
  on_done = function(ok) done[#done + 1] = ok end,
})
poll.run()
for _ = 1, 5 do poll.run() end
assert(input_calls == 1 and #done == 0,
  "quoted task visible as a composer tail is not verified delivery")

-- A draft fails the empty-composer gate; retries never type into it.
now, alive, screen, input_calls, done = 10000, true, "draft", 0, {}
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
local launch_file = assert(io.open("packages/butler/launch.lua", "r"))
local launch_source = launch_file:read("*a")
launch_file:close()
assert(launch_source:find('if detail == "submit" then detail = "submission could not be verified" end', 1, true),
  "task submission failures explain that submission could not be verified")
print("ok - first task retries until verified, exhaustion reports once, and exit cancels retries")
