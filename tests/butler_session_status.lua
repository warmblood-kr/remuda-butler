-- The per-session status word in the pane's detail line. Run from the repo root:
--   luajit tests/butler_session_status.lua

local startup = { claude = { modals = {} }, codex = { modals = {} } }
local remuda = {
  _butler_agent_builders = {}, _butler_agent_startup = startup, _butler_telemetry_adapters = {},
  _butler_state = {}, _butler_compaction_state = {}, _butler_agent_support = {},
  _butler_test_mode = true, _butler_mail = {}, butler = {},
  _butler_system = {}, _butler_prompt_delivery = {},
}
_G.remuda = remuda
dofile("packages/butler/agents/claudecode.lua")
dofile("packages/butler/sandbox.lua")
dofile("packages/butler/agents/codex.lua")
dofile("packages/butler/agents/monocle.lua")

local bus = { agents = {} }
local function noop() end
remuda._butler_chooser_config = {
  bus = bus, call_callback = noop, numbered_option = noop, bottom_screen_lines = function() return {} end,
  file_exists = noop, contributions = noop,
}
remuda._butler_contribute = noop
remuda.contribute = noop
dofile("packages/butler/agents_launch.lua")

-- The same ready/working probes init.lua registers, called as main.lua does.
local entries = {
  claude = {
    ready = function(_, screen) return screen:find("─\n❯", 1, true) ~= nil end,
    working = function(_, screen) return screen:find("esc to interrupt", 1, true) ~= nil end,
  },
  codex = {
    ready = function(_, screen) return startup.codex.ready(screen) end,
    working = function(_, screen) return startup.codex.working(screen) end,
  },
  monocle = {
    ready = function(_, screen) return startup.monocle.ready(screen) end,
    working = function(_, screen) return startup.monocle.working(screen) end,
  },
}
local function call_callback(fn, ...)
  local args = { ... }
  return pcall(fn, remuda, table.unpack and table.unpack(args) or unpack(args))
end
local sessions_config = {
  bus = bus, mail = { unread = function() return 0 end }, json_field = noop,
  registered_agent_kind = function(kind) return entries[kind] end, call_callback = call_callback,
}
remuda._butler_sessions_config = sessions_config
local hooks = {}
local context = {}
remuda._butler_telemetry_for = function(agent)
  local extra = context[agent] or {}
  return { model = "m", hook_state = hooks[agent].state, hook_at = hooks[agent].at,
    context_used = extra.context_used, context_window = extra.context_window,
    context_percent = extra.context_percent }
end
setmetatable(hooks, { __index = function() return {} end })

local screens, captures, now = {}, 0, 100
remuda._butler_status_now = function() return now end
remuda.capture = function(name)
  captures = captures + 1
  local screen = screens[name]
  if type(screen) == "function" then return screen() end
  return screen
end
dofile("packages/butler/sessions.lua")

local seq = 0
local function status_of(kind, screen)
  seq = seq + 1
  local name = "s" .. seq
  bus.agents[name] = { kind = kind }
  screens[name] = screen
  return remuda.session_detail({ name = name }):match("^(.-) · ")
end
local function check(got, want, what) assert(got == want, what .. ": expected " .. want .. ", got " .. tostring(got)) end

local claude_idle = "done\n─\n❯ \n"
check(status_of("claude", "thinking\nesc to interrupt\n"), "working", "claude working")
check(status_of("claude", claude_idle), "idle", "claude idle")
check(status_of("claude", "Quick safety check: trust this folder?\n"), "needs you", "claude dialog")
check(status_of("claude", "some other screen"), "other", "claude unrecognised screen")
check(status_of("codex", "Working\nesc to interrupt\n"), "working", "codex working")
check(status_of("codex", "Ask Codex to do anything\n"), "idle", "codex idle")
check(status_of("codex", "Update available\n1. Update now\n2. Skip\n"), "needs you", "codex update dialog")
check(status_of("monocle", "busy output\n"), "other", "monocle is never working")
check(status_of("monocle", "❯ \n"), "other", "monocle ready is still other")
entries.gemini = entries.claude
check(status_of("gemini", "esc to interrupt"), "other", "unknown kind with probes")
check(status_of("claude", function() error("esc to interrupt") end), "other", "capture error")
check(status_of("claude", nil), "other", "capture returns nothing")

entries.claude.working = function() error("probe broke") end
check(status_of("claude", claude_idle), "other", "probe raising")
local lookup = sessions_config.registered_agent_kind
sessions_config.registered_agent_kind = function(kind) if kind == "claude" then error("lookup broke") end return lookup(kind) end
check(status_of("claude", claude_idle), "other", "lookup raising")
sessions_config.registered_agent_kind = lookup
entries.claude.working = function(_, screen) return screen:find("esc to interrupt", 1, true) ~= nil end
local detail = remuda.session_detail({ name = "s1" })
assert(detail:find("^working · claude · m"), "the status leads the detail line: " .. detail)

local detail_agent = { kind = "codex" }
bus.agents.detail = detail_agent
context[detail_agent] = { context_used = 123456, context_window = 258400, context_percent = 47 }
detail = remuda.session_detail({ name = "detail" })
assert(detail:find("123K 47%%", 1, false), "detail shows percent beside token count: " .. detail)
context[detail_agent] = { context_window = 258400, context_percent = 47 }
detail = remuda.session_detail({ name = "detail" })
assert(detail:find("~121K 47%%", 1, false), "derived token count is marked approximate: " .. detail)
assert(not detail:find("123K", 1, true), "derived count is not the measured one")
for _, bad in ipairs({ 1001, -1, math.huge, 0 / 0 }) do
  context[detail_agent] = { context_window = 258400, context_percent = bad }
  detail = remuda.session_detail({ name = "detail" })
  assert(not detail:find("%d%%") and not detail:find("%dK") and not detail:find("?", 1, true),
    "out-of-range percent is unknown: " .. tostring(bad) .. " " .. detail)
end
context[detail_agent] = { context_window = 0, context_percent = 12 }
detail = remuda.session_detail({ name = "detail" })
assert(not detail:find("0K 12%%", 1, false), "zero window omits derived token count: " .. detail)
assert(detail:find(" · 12%%", 1, false), "zero window still shows the known percentage: " .. detail)
context[detail_agent] = { context_used = "?", context_window = "?", context_percent = "?" }
detail = remuda.session_detail({ name = "detail" })
assert(not detail:find("?", 1, true), "unknown context stays quiet: " .. detail)

-- One capture per session per listing window; a later listing captures again.
bus.agents.c = { kind = "claude" }
screens.c = claude_idle
captures = 0
remuda.session_detail({ name = "c" })
now = now + 1
remuda.session_detail({ name = "c" })
check(captures, 1, "two listings within 1s capture once")
now = now + 2
screens.c = "x\nesc to interrupt"
check(remuda.session_detail({ name = "c" }):match("^(.-) · "), "working", "status refreshes after the window")
check(captures, 2, "a listing after 2s captures again")

-- A session name reused by a new agent within the window never shows the old status.
bus.agents.r = { kind = "claude", id = "A" }
screens.r = claude_idle
captures = 0
check(remuda.session_detail({ name = "r" }):match("^(.-) · "), "idle", "first agent")
bus.agents.r = { kind = "claude", id = "B" }
screens.r = "x\nesc to interrupt"
check(remuda.session_detail({ name = "r" }):match("^(.-) · "), "working", "reused name shows the new agent")
check(captures, 2, "reused name is probed again within the window")

-- Hook state: fresh wins, stale or absent falls back to the screen.
local function hooked(state, age, screen)
  seq = seq + 1
  local name = "h" .. seq
  local agent = { kind = "claude" }
  bus.agents[name], screens[name] = agent, screen
  hooks[agent] = { state = state, at = age and (now - age) or nil }
  captures = 0
  return remuda.session_detail({ name = name }):match("^(.-) · ")
end
check(hooked("working", 5, claude_idle), "working", "fresh working hook beats an idle screen")
check(captures, 0, "a fresh working hook needs no capture")
check(hooked("working", 601, claude_idle), "idle", "stale working hook falls back to the screen")
check(hooked("needs you", 5, claude_idle), "needs you", "fresh needs-you hook beats an idle screen")
check(hooked("needs you", 5, "some other screen"), "needs you", "fresh needs-you hook beats an unknown screen")
check(hooked("idle", 5, "x\nesc to interrupt"), "working", "a working screen beats an idle hook")
check(hooked("needs you", 5, "x\nesc to interrupt"), "working", "a working screen beats a needs-you hook")
check(hooked("idle", 3601, "x\nesc to interrupt"), "working", "stale idle hook falls back to the screen")
check(hooked("idle", 3601, "some other screen"), "other", "stale idle hook falls back to an unknown screen")
check(hooked("idle", 3599, "some other screen"), "idle", "idle hook is trusted for an hour")
check(hooked(nil, nil, claude_idle), "idle", "no hook file falls back to the screen")
check(hooked("working", -50, claude_idle), "idle", "a hook from the future is ignored")
check(hooked("bogus", 5, claude_idle), "idle", "unknown hook word is ignored")
print("ok")
