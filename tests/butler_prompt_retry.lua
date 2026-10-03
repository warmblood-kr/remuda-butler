-- Run with: luajit tests/butler_prompt_retry.lua
-- First-task delivery types once into an empty composer, retries a dropped
-- Return, and reports a write that never appeared only after 15 seconds.

_G.remuda = {}
local delivery = dofile("packages/butler/prompt.lua")

local function scenario(after_write, busy, working, expected_ok)
  local state = { now = 100, composer = "", captures = 0, writes = 0, keys = 0, done = false }
  local fake = {}
  function fake.schedule(spec) state.poll = spec.run; return "task-poll" end
  function fake.cancel(handle) assert(handle == "task-poll"); state.cancelled = true end
  function fake.capture()
    state.captures = state.captures + 1
    return "Ask Codex\n❯ " .. state.composer
  end
  function fake.type_text(_, text)
    state.writes = state.writes + 1
    state.composer = after_write == "task" and text or ""
    return true
  end
  function fake.key(_, key)
    assert(key == "RET")
    state.keys = state.keys + 1
    state.composer = ""
  end
  function fake.session() return { is_busy = busy == true } end
  delivery.schedule(fake, "codex", "member", "member", "leader", "first task", {
    detect_only = true,
    marker = "marker-1",
    now = function() return state.now end,
    same_launch = function() return true end,
    ready = function(screen) return screen:find("Ask Codex", 1, true) ~= nil end,
    allowed = function() return true end,
    empty = function(screen)
      local text = screen:match("❯%s*(.-)$") or ""
      return text == "" and "EMPTY" or "NON-EMPTY", text
    end,
    working = function() return working == true end,
    on_done = function(ok, reason) state.done, state.ok, state.reason = true, ok, reason end,
  })
  state.poll()
  assert(state.writes == 1, "ready empty composer did not receive exactly one write")
  assert(not state.done, "delivery finished before its one post-write look")
  if expected_ok == "retry" then
    for _ = 1, 8 do state.now = state.now + 0.5; state.poll() end
    assert(state.done and state.ok and state.keys == 1 and state.writes == 1,
      "a dropped Return was not retried once before acceptance")
    return
  end
  if expected_ok then
    state.poll()
    assert(state.done and state.ok and state.writes == 1, "an accepted task was not reported delivered")
    return
  end
  state.now = 114
  state.poll()
  assert(not state.done, "a lost write was reported before 15 seconds")
  state.now = 115
  state.poll()
  assert(state.done and state.cancelled and state.writes == 1 and state.keys == 0 and not state.ok,
    "a lost write was not reported after 15 seconds")
  assert(state.reason == "write returned success but the task never appeared", state.reason)
end

scenario("task", false, false, "retry")
scenario("blank", false, false, false)
scenario("blank", true, false, true)
scenario("blank", false, true, true)

do
  local state = { writes = 0 }
  local fake = {}
  function fake.schedule(spec) state.poll = spec.run; return "refused-poll" end
  function fake.cancel() state.cancelled = true end
  function fake.capture() return "Ask Codex\n❯ " end
  function fake.type_text()
    state.writes = state.writes + 1
    return "input write is already in flight"
  end
  delivery.schedule(fake, "codex", "member", "member", "leader", "first task", {
    detect_only = true,
    marker = "marker-refused",
    ready = function() return true end,
    empty = function() return "EMPTY", "" end,
    allowed = function() return true end,
    on_write = function(outcome, first) state.outcome, state.first = outcome, first end,
    on_done = function(ok) state.ok = ok end,
  })
  state.poll()
  assert(state.writes == 1 and state.cancelled and state.ok == false,
    "a refused write was treated as a successful delivery")
  assert(state.outcome == "refused" and state.first == "input write is already in flight",
    "the refused write outcome was not traced")
end

do
  local state = { writes = 0, now = 0 }
  local fake = {}
  function fake.schedule(spec) state.poll = spec.run; return "non-empty-poll" end
  function fake.cancel() state.cancelled = true end
  function fake.capture() return "Ask Codex\n❯ human draft" end
  function fake.type_text() state.writes = state.writes + 1 end
  delivery.schedule(fake, "codex", "member", "member", "leader", "first task", {
    detect_only = true,
    ready = function() return true end,
    empty = function() return "NON-EMPTY", "human draft" end,
    allowed = function() return true end,
    timeout = 1,
    on_done = function(ok) state.ok = ok end,
  })
  state.poll()
  state.poll()
  assert(state.writes == 0, "first task overwrote a non-empty composer")
  assert(state.ok == false, "non-empty composer did not produce a bounded failure")
end

print("butler_prompt_retry: ok")
