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
remuda._butler_telemetry_for = function() return { model = "m" } end

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
print("ok")
