-- Claude Code "Teach auto mode about your environment?" modal (#453): answered
-- by option TEXT ("Not now"), never "Yes"/"Don't show again"/shell-history
-- "Continue"; the follow-up screen is never answered. Fakes only.
-- Run from the repo root: luajit tests/butler_teach_auto_mode_modal.lua
-- Fixtures: TRANSCRIPTS (verbatim capture text, not raw, ~120 cols) are primary;
-- SYNTHETIC narrow layouts are extra variants. See the fixture READMEs.
local startup = { claude = { modals = {} }, codex = { modals = {} } }
local remuda = {
  _butler_agent_builders = {}, _butler_agent_startup = startup, _butler_telemetry_adapters = {},
  _butler_state = {}, _butler_compaction_state = {}, _butler_agent_support = {},
  _butler_test_mode = true, _butler_mail = {}, butler = {},
  _butler_system = {}, _butler_prompt_delivery = {},
}
_G.remuda = remuda
local repo = "."
dofile(repo .. "/packages/butler/agents/claudecode.lua")
dofile(repo .. "/packages/butler/sandbox.lua")
dofile(repo .. "/packages/butler/agents/codex.lua")
dofile(repo .. "/packages/butler/prompt.lua")

local function noop() end
local function bottom_screen_lines(screen, limit)
  local lines = {}
  for line in (screen .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  while #lines > 0 and lines[#lines]:match("^%s*$") do lines[#lines] = nil end
  local out = {}
  for i = math.max(1, #lines - limit + 1), #lines do out[#out + 1] = lines[i] end
  return out
end
local rows = {}
for _, kind in ipairs({ "claude", "codex" }) do
  rows[#rows + 1] = { id = kind, entry = { argv = { kind }, login = {}, dialogs = startup[kind].modals,
    ready = startup[kind].ready or function() return false end } }
end
remuda._butler_chooser_config = {
  bus = { agents = {} }, call_callback = function(fn, ...) return pcall(fn, ...) end,
  numbered_option = noop, bottom_screen_lines = bottom_screen_lines,
  file_exists = noop, contributions = function() return rows end,
  startup_action_safe = function() return true end,
}
remuda._butler_contribute = noop
remuda.contribute = noop
dofile(repo .. "/packages/butler/agents_launch.lua")
local chooser = remuda._butler_chooser

local failures = 0
local function check(actual, expected, label)
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end
local function read(path)
  local f = assert(io.open(repo .. "/tests/fixtures/" .. path, "rb")); local s = f:read("*a"); f:close(); return s
end
local TRANSCRIPT = "claude-teach-auto-mode-modal-transcript/"
local SYNTHETIC = "claude-teach-auto-mode-modal-synthetic/"
-- One line per fixture: adding a real capture later is one more row.
local PAGE1 = {
  { "TRANSCRIPT page1 (~120 cols)", read(TRANSCRIPT .. "modal-page1-win-styled.txt") },
  { "SYNTHETIC narrow page1", read(SYNTHETIC .. "narrow-page1.txt") },
  { "SYNTHETIC narrow wrapped page1 + idle composer", read(SYNTHETIC .. "narrow-wrapped-page1.txt") },
}
local PAGE2 = { { "TRANSCRIPT page2 (shell history)", read(TRANSCRIPT .. "modal-page2-lua-b06.txt") } }

-- Move the selection marker to option N (1..3) in a page-1 screen.
local function with_marker(screen, n)
  local out = screen:gsub("❯ (%d%. )", "  %1")
  return (out:gsub("  (" .. n .. "%. )", "❯ %1", 1))
end
-- Launch-chooser run with a stub that records exact keystrokes.
local function launch(screen, opts)
  opts = opts or {}
  local pressed, sessions, result = {}, 0, nil
  local sel, done = opts.selected or 1, false
  local function paint() return done and "─\n❯" or with_marker(screen, sel) end
  if opts.static then paint = function() return screen end end
  remuda.new = function(name) return name end
  remuda.ls = function() return { { name = "m", alive = true } } end
  remuda.capture = paint
  remuda.close = noop
  remuda.cancel = noop
  remuda.key = function(_, key)
    pressed[#pressed + 1] = key
    if key == "<down>" then sel = sel + 1 elseif key == "<up>" then sel = sel - 1
    elseif key == "RET" then done = true end
    return true
  end
  local tick
  remuda.schedule = function(spec) tick = spec.run; return 1 end
  chooser.choose({ "claude" }, { name = "m", cwd = "/p/work", argv = { "claude" },
    spec = function() return {} end, env = function() return {} end, timeout = 60 },
    function(name, id, attempts) sessions = sessions + 1; result = { name = name, id = id, attempts = attempts } end)
  for _ = 1, 12 do if tick and sessions == 0 then tick() end end
  return table.concat(pressed, ","), result, sessions
end

for _, fx in ipairs(PAGE1) do
  local pressed, result = launch(fx[2])
  check(pressed, "<down>,RET", fx[1] .. ": selects 'Not now' by text, then confirms")
  check(result and result.name, "m", fx[1] .. ": launch proceeds after the modal is answered")
  check(select(1, launch(fx[2], { selected = 3 })), "<up>,RET", fx[1] .. ": marker on 'Don't show again' moves up")
  check(select(1, launch(fx[2], { selected = 2 })), "RET", fx[1] .. ": already on 'Not now': confirm only")
  for _, bad in ipairs({ "1", "2", "3", "y", "Y", "Continue" }) do
    check(pressed:find(bad, 1, true), nil, fx[1] .. ": never sends " .. bad)
  end
  check(chooser.known_startup_modal(startup.claude, fx[2]), true, fx[1] .. ": known modal (notice defers)")
end
for _, fx in ipairs(PAGE2) do
  local pressed, _, sessions = launch(fx[2], { static = true })
  check(pressed, "", fx[1] .. ": follow-up screen is never answered")
  check(sessions, 0, fx[1] .. ": follow-up screen defers (no ready, no failure)")
  check(chooser.known_startup_modal(startup.claude, fx[2]), true, fx[1] .. ": known modal (notice defers)")
end

-- Keys are re-derived from the CURRENT screen every tick (never cached): the marker
-- jumps around between ticks (a key lost, then an external move) and each answer
-- follows what is on screen at that moment.
do
  local script, tick_no, pressed, sessions = { 1, 1, 3, 2 }, 0, {}, 0 -- marker seen per capture
  remuda.new = function(name) return name end
  remuda.ls = function() return { { name = "m", alive = true } } end
  remuda.capture = function()
    tick_no = tick_no + 1
    local sel = script[math.min(tick_no, #script)]
    return tick_no > #script + 1 and "─\n❯" or with_marker(PAGE1[1][2], sel)
  end
  remuda.close, remuda.cancel = noop, noop
  remuda.key = function(_, key) pressed[#pressed + 1] = key; return true end
  local tick
  remuda.schedule = function(spec) tick = spec.run; return 1 end
  chooser.choose({ "claude" }, { name = "m", cwd = "/p/work", argv = { "claude" },
    spec = function() return {} end, env = function() return {} end, timeout = 60 },
    function() sessions = sessions + 1 end)
  for _ = 1, 3 do tick() end
  check(table.concat(pressed, ","), "<down>,<down>,<up>", "keys follow the current marker position each tick")
  tick()
  check(pressed[#pressed], "RET", "confirm only when the current screen shows the marker on 'Not now'")
end

-- Lookalikes: the title in a user's draft without the modal layout.
local R = ("─"):rep(40)
local lookalikes = {
  { "single-line draft", R .. "\n❯ Teach auto mode about your environment?\n" .. R },
  { "multi-line draft with options text", R .. "\n❯ notes\n  Teach auto mode about your environment?\n  1. Yes\n  2. Not now\n  3. Don't show again\n" .. R },
  { "transcript text quoted in output", "● The dialog says Teach auto mode about your environment? and offers Yes/Not now\n" .. R .. "\n❯ \n" .. R },
}
for _, la in ipairs(lookalikes) do
  local pressed, _, sessions = launch(la[2], { static = true })
  check(pressed, "", la[1] .. ": no keystroke")
  check(chooser.known_startup_modal(startup.claude, la[2]), false, la[1] .. ": not a known modal")
end
check(select(3, launch(lookalikes[1][2], { static = true })), 1, "draft with title: launch still ready")

-- Regression: the trust modal is still recognized and unchanged.
local trust = read("claude-trust-dialog.txt")
check(chooser.known_startup_modal(startup.claude, trust), true, "trust modal still known")

-- First-task path: nothing is typed while the modal is up; delivery proceeds once cleared.
local function first_task(screens)
  local typed, i = {}, 0
  local fake = { capture = function() i = i + 1; return screens[math.min(i, #screens)] end,
    key = function(_, k) typed[#typed + 1] = "key:" .. k; return true end,
    type_text = function(_, text) typed[#typed + 1] = text; return true end,
    schedule = function(spec) for _ = 1, 8 do spec.run() end; return 1 end,
    cancel = noop, log = noop }
  remuda._butler_prompt_delivery.schedule(fake, "claude", "m", "m", nil, "do the task", {
    ready = startup.claude.ready, modals = startup.claude.modals, ready_timeout = 100,
    trust_dialog = function(screen) local m = chooser.startup_modal(startup.claude, screen); return m ~= nil and (m.trust ~= nil or m.title ~= nil) end,
    on_done = noop })
  return typed
end
local page1 = PAGE1[3][2]
local typed = first_task({ page1, page1, "─\n❯" })
check(typed[1], "do the task", "first task typed only after the modal clears")
check(#first_task({ page1 }), 0, "first task: nothing typed while the modal stays up")
check(#first_task({ PAGE2[1][2] }), 0, "first task: nothing typed on the follow-up screen")

if failures > 0 then error(failures .. " failure(s)") end
print("ok")
