-- Run with: luajit tests/prompt_delivery.lua
-- Fake agent TUIs remain unavailable for 24 scheduler ticks, then expose
-- their kind-specific composer marker. Before readiness they keep only the
-- tail of an injected prompt, matching the observed first-prompt failure.

local prompt_module = "packages/butler/prompt.lua"
_G.remuda = {}
local M = dofile(prompt_module)
local main_file = assert(io.open("packages/butler/main.lua", "r"))
local main = main_file:read("*a")
main_file:close()
assert(main:find('remuda.exec("butler/prompt")', 1, true), "Butler does not load prompt delivery")
assert(main:find("PROMPT_DELIVERY.schedule(remuda, kind, actual, name, parent, task", 1, true),
  "agent launch bypasses the verified prompt delivery path")

local function count(text, needle)
  local n, at = 0, 1
  while true do
    at = text:find(needle, at, true)
    if not at then return n end
    n, at = n + 1, at + #needle
  end
end

local function exercise(kind, drop_submissions)
  local state = {
    tick = 0,
    ready_at = 24,
    composer = "",
    transcript = {},
    sends = 0,
    drop_submissions = drop_submissions,
    completed = false,
  }
  local ready_marker = kind == "codex" and "Ask Codex" or "─\n❯"
  local fake = {}
  function fake.schedule(spec)
    state.callback = spec.run
    return "fake-prompt-poll"
  end
  function fake.cancel(handle)
    assert(handle == "fake-prompt-poll")
    state.cancelled = true
  end
  function fake.capture()
    if state.tick < state.ready_at then return "agent is booting" end
    return ready_marker .. "\n" .. state.composer .. "\n" .. table.concat(state.transcript, "\n")
  end
  function fake.type_text(_, text)
    state.sends = state.sends + 1
    state.first_send_tick = state.first_send_tick or state.tick
    if state.tick < state.ready_at then
      state.composer = text:sub(-96)
      return
    end
    if not state.drop_submissions then
      state.transcript[#state.transcript + 1] = state.composer .. text
    end
    state.submits = (state.submits or 0) + 1
    if state.drop_submissions and state.submits == 1 then
      state.composer = text
    else
      state.composer = ""
    end
  end
  function fake.key(_, key)
    assert(key == "RET")
    state.returns = (state.returns or 0) + 1
    if state.returns == 1 then
      state.composer = ""
      state.transcript[#state.transcript + 1] = state.task
    end
  end
  fake.session = function() return { is_busy = false } end
  function fake._butler_send(_, parent, warning)
    state.failure = parent .. ": " .. warning
  end

  local task = "START-59-" .. kind .. "-marker\n" .. string.rep(
    "A delegated first task must arrive whole, in order, and be submitted exactly once. ",
    19
  ) .. "\nEND-59-" .. kind .. "-marker"
  state.task = task
  assert(#task >= 1600, "regression task must exercise a long first prompt")

  M.schedule(fake, kind, "member-session", "member", "leader", task, {
    ready = function(screen)
      local marker = kind == "codex" and "Ask Codex" or "─\n❯"
      return screen:find(marker, 1, true) ~= nil
    end,
    allowed = function() return true end,
    empty = function()
      return state.composer == "" and "EMPTY" or "NON-EMPTY"
    end,
    on_done = function(ok)
      state.completed = ok
    end,
  })
  for tick = 1, 120 do
    state.tick = tick
    if not state.cancelled then state.callback() end
  end

  local delivered = table.concat(state.transcript, "\n")
  assert(state.first_send_tick >= state.ready_at, kind .. " received input before its composer was ready")
  if drop_submissions then
    assert(state.completed, kind .. " did not clear pending delivery after retry acceptance")
    assert(not state.failure, state.failure)
    assert(state.sends == 1, kind .. " re-injected the task instead of retrying Return")
    assert(state.returns == 1, kind .. " did not retry a dropped Return exactly once")
    assert(#state.transcript == 1 and state.transcript[1] == task,
      kind .. " did not submit the complete task after retrying Return")
  else
    assert(not state.failure, state.failure)
    assert(#state.transcript == 1, kind .. " submitted the first task " .. #state.transcript .. " times")
    assert(state.sends == 1, kind .. " injected the first task " .. state.sends .. " times")
    assert(state.submits == 1, kind .. " submitted the prompt " .. tostring(state.submits) .. " times")
    assert(delivered == task, kind .. " changed or truncated the task")
    assert(count(delivered, "START-59-" .. kind .. "-marker") == 1, kind .. " lost or duplicated START")
    assert(count(delivered, "END-59-" .. kind .. "-marker") == 1, kind .. " lost or duplicated END")
  end
  assert(state.cancelled, kind .. " left its prompt poll running")
end

exercise("claude")
exercise("codex")
exercise("claude", true)

-- Known startup dialogs must be answered before the task is typed, and the
-- delivery poll must not replay the task while the prompt settles.
do
  local state = { keys = {}, typed = {}, cancelled = false }
  local fake = {}
  function fake.schedule(spec) state.callback = spec.run; return "modal-poll" end
  function fake.cancel(handle) assert(handle == "modal-poll"); state.cancelled = true end
  function fake.capture()
    if state.capture_queue and #state.capture_queue > 0 then
      return table.remove(state.capture_queue, 1)
    end
    if #state.keys == 0 then return "Update available\n2. Skip" end
    return "› Ask Codex to do anything\n❯ "
  end
  function fake.key(_, key) state.keys[#state.keys + 1] = key end
  function fake.type_text(_, task)
    state.typed[#state.typed + 1] = task
    state.capture_queue = { "› " .. task, "❯ " }
  end
  fake.session = function() return { is_busy = false } end
  local task = "task after startup modal"
  M.schedule(fake, "codex", "modal-session", "modal-member", "leader", task, {
    ready = function(screen) return screen:find("Ask Codex", 1, true) ~= nil end,
    modals = { { match = "2. Skip", keys = { "2" } } },
    empty = function() return "EMPTY" end,
    on_done = function(ok) state.completed = ok end,
  })
  for _ = 1, 20 do
    if not state.cancelled then state.callback() end
  end
  assert(state.keys[1] == "2", "Codex startup modal was not handled")
  assert(#state.typed == 1 and state.typed[1] == task, "task was not typed exactly once after modal")
  assert(state.completed and state.cancelled, "modal task delivery did not complete")
end
print("first prompt delivery passed for Claude and Codex")
