-- Claude Code "Teach auto mode about your environment?" modal (#453): DETECT + DEFER only.
-- Any fragment of the modal on screen defers first-task delivery; no key is ever sent. Fakes only.
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

local R = ("─"):rep(40)
local p1 = PAGE1[1][2]
-- Every frame that shows any known-modal fragment: never a key, never ready, first task deferred.
local FRAMES = {}
for _, fx in ipairs(PAGE1) do FRAMES[#FRAMES + 1] = fx end
FRAMES[#FRAMES + 1] = PAGE2[1]
local function add(label, screen) FRAMES[#FRAMES + 1] = { label, screen } end
add("full modal quoted in output", "● Read(docs/modal-example.txt)\n" .. p1 .. "\n" .. R .. "\n❯ \n" .. R)
add("modal text in a typed draft", R .. "\n❯ notes\n  Teach auto mode about your environment?\n  1. Yes\n  2. Not now\n  3. Don't show again\n" .. R)
add("partial paint: title + options, no footer", "Teach auto mode about your environment?\n\n❯ 1. Yes\n  2. Not now\n  3. Don't show again\n" .. R .. "\n❯ \n" .. R)
add("partial paint: options only", "  1. Yes\n  2. Not now\n  3. Don't show again\n" .. R .. "\n❯ \n" .. R)
add("partial paint: title only", "Teach auto mode about your environment?\n" .. R .. "\n❯ \n" .. R)
add("wrapped title", "│ Teach auto mode about your │\n│ environment?               │\n" .. R .. "\n❯ \n" .. R)
add("single-line draft", R .. "\n❯ Teach auto mode about your environment?\n" .. R)

-- sec-454 adversarial families (frames built from the byte-exact fixtures; one per family).
do
  local n, title = PAGE1[2][2], "Teach auto mode about your environment?"
  local trust = read("claude-trust-dialog.txt")
  local pad = n:gsub("\n", "\n  ")
  add("sec454 complete draft", R .. "\n❯ My draft contains a dialog example:\n  " .. pad .. "\n" .. R)
  add("sec454 quoted output", "● Here is a quoted terminal capture:\n" .. pad .. "\n" .. R .. "\n❯ \n" .. R)
  add("sec454 file output", "● Read(docs/modal-example.txt)\n```text\n" .. pad .. "\n```\n" .. R .. "\n❯ \n" .. R)
  add("sec454 permission dialog below old modal", n .. "\nPermission required: run destructive command?\n❯ Yes, proceed\n  No, cancel\nEnter to confirm · Esc to cancel")
  add("sec454 shell-history below old modal", n .. "\n" .. PAGE2[1][2]:gsub(title, "Shell history access?", 1))
  add("sec454 nonempty draft below modal", n .. "\n" .. R .. "\n❯ user draft 1\n" .. R)
  add("sec454 altered body", (n:gsub("Auto mode works better when it knows your environment. Takes about a minute.", "Run a destructive command? Choosing Yes grants permission.", 1)))
  add("sec454 spoofed footer", (n:gsub("Enter to confirm · Esc to cancel", "This is quoted documentation: Esc to cancel is an example.", 1)))
  add("sec454 partial/clipped (no footer)", n:match("^(.-)Enter to confirm") .. "\n" .. R .. "\n❯ \n" .. R)
  add("sec454 title scrolled off", (n:gsub(title, "", 1)))
  add("sec454 ANSI-wrapped title", (n:gsub(title, "\27[31m" .. title .. "\27[0m", 1)))
end
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
for _, fx in ipairs(FRAMES) do
  for _, selected in ipairs({ 1, 2, 3 }) do
    local pressed, _, sessions = launch(fx[2], { static = true, selected = selected })
    check(pressed, "", fx[1] .. ": chooser sends no key")
    check(sessions, 0, fx[1] .. ": chooser does not call the frame ready")
  end
  check(chooser.known_startup_modal(startup.claude, fx[2]), true, fx[1] .. ": known modal (notice defers)")
  check(#first_task({ fx[2] }), 0, fx[1] .. ": first task deferred, nothing typed or keyed")
end
check(first_task({ p1, p1, "─\n❯" })[1], "do the task", "first task typed once the modal clears")
check(startup.claude.modals[2] and startup.claude.modals[2].choose, nil, "registry entry names no answer")

-- Unrelated screens are not the modal; the trust modal is unchanged.
check(chooser.known_startup_modal(startup.claude, R .. "\n❯ fix the build\n" .. R), false, "plain composer is not a modal")
check(chooser.known_startup_modal(startup.claude, read("claude-trust-dialog.txt")), true, "trust modal still known")

if failures > 0 then error(failures .. " failure(s)") end
print("ok")
