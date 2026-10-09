-- Folder-trust dialog: the option is chosen by its TEXT, and only for sessions
-- this Butler launched in a guarded directory. Fakes only, no syscalls. Run from the repo root:
--   luajit tests/butler_trust_dialog.lua

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

local function noop() end
local function bottom_screen_lines(screen, limit)
  local lines = {}
  for line in (screen .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  while #lines > 0 and lines[#lines]:match("^%s*$") do lines[#lines] = nil end
  local out = {}
  for i = math.max(1, #lines - limit + 1), #lines do out[#out + 1] = lines[i] end
  return out
end
local bus = { agents = {} }
local rows = {}
for _, kind in ipairs({ "claude", "codex" }) do
  rows[#rows + 1] = { id = kind, entry = { argv = { kind }, login = {}, dialogs = startup[kind].modals,
    ready = function() return false end } }
end
remuda._butler_chooser_config = {
  bus = bus, call_callback = function(fn, ...) return pcall(fn, ...) end,
  numbered_option = noop, bottom_screen_lines = bottom_screen_lines,
  file_exists = noop, contributions = function() return rows end,
  startup_action_safe = function() return true end,
}
remuda._butler_contribute = noop
remuda.contribute = noop
dofile("packages/butler/agents_launch.lua")
local chooser = remuda._butler_chooser

local failures = 0
local function check(actual, expected, label)
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

-- Fake dialogs ---------------------------------------------------------------
local YES = "Yes, I trust this folder"
local function claude_screen(labels, selected, path)
  local out = { "────────────", " Accessing workspace:", "", " " .. (path or "/p/work"), "",
    " Quick safety check: Is this a project you trust?", "" }
  for index, label in ipairs(labels) do out[#out + 1] = (index == selected and " ❯ " or "   ") .. label end
  out[#out + 1] = ""
  out[#out + 1] = " Enter to confirm · Esc to cancel"
  return table.concat(out, "\n")
end
local function codex_screen(labels, selected, path)
  local out = { "  Folder access", "  " .. (path or "/p/work"), "",
    "  Trust this folder? Codex can read, edit, and run files here.", "" }
  for index, label in ipairs(labels) do out[#out + 1] = (index == selected and "› " or "  ") .. index .. ". " .. label end
  out[#out + 1] = ""
  out[#out + 1] = "  enter continue · esc back"
  return table.concat(out, "\n")
end
local function keys_of(plan) return plan and table.concat(plan.moves, ",") or "nil" end
local function trust_modal(kind) for _, m in ipairs(startup[kind].modals) do if m.trust then return m end end end
local claude, codex = trust_modal("claude"), trust_modal("codex")

-- 1. Key sequence from the CURRENT marker to the matching text -------------
local labels3 = { "No, exit", YES, "Maybe later" }
check(keys_of(chooser.trust_plan(claude, claude_screen({ YES, "No, exit" }, 2))), "<up>", "claude yes at 1, marker at 2")
check(keys_of(chooser.trust_plan(claude, claude_screen({ "No, exit", YES }, 1))), "<down>", "claude yes at 2, marker at 1")
check(keys_of(chooser.trust_plan(claude, claude_screen({ "No, exit", YES }, 2))), "", "claude already selected")
check(keys_of(chooser.trust_plan(claude, claude_screen({ "No, exit", "Maybe later", YES }, 1))), "<down>,<down>", "claude yes at 3, marker at 1")
check(keys_of(chooser.trust_plan(claude, claude_screen(labels3, 3))), "<up>", "claude yes at 2, marker at 3")
check(keys_of(chooser.trust_plan(claude, claude_screen({ YES, "No, exit", "Maybe later" }, 3))), "<up>,<up>", "claude yes at 1, marker at 3")
check(keys_of(chooser.trust_plan(codex, codex_screen({ "Trust and continue", "Back to Agent Command Center" }, 1))), "", "codex trust at 1 selected")
check(keys_of(chooser.trust_plan(codex, codex_screen({ "Back to Agent Command Center", "Trust and continue" }, 1))), "<down>", "codex trust at 2")
check(keys_of(chooser.trust_plan(codex, codex_screen({ "Back", "Other", "Trust and continue" }, 1))), "<down>,<down>", "codex trust at 3")
check(chooser.trust_modal_state(claude, claude_screen({ "No, exit", YES }, 1)), "safe", "state safe")
check(chooser.trust_modal_state(claude, claude_screen({ "No, exit", YES }, 2)), "safe_selected", "state selected")

-- 2. No exact match, or an odd structure: no plan ---------------------------
for label, screen in pairs({
  claude_lowercase = claude_screen({ "No, exit", "yes, i trust this folder" }, 1),
  claude_suffix = claude_screen({ "No, exit", YES .. " and my settings" }, 1),
  claude_two_matches = claude_screen({ YES, YES }, 1),
  claude_one_option = claude_screen({ YES }, 1),
  claude_five_options = claude_screen({ "a", "b", "c", "d", YES }, 1),
}) do
  check(chooser.trust_plan(claude, screen), nil, label .. " has no plan")
  check(chooser.trust_modal_state(claude, screen), "human", label .. " is for a human")
end
check(chooser.trust_modal_state(claude, claude_screen({ "No, exit", YES }, 0)), "pending", "no marker yet is a partial frame")
check(chooser.trust_plan(codex, codex_screen({ "Trust", "Back" }, 1)), nil, "codex near-miss text")
check(chooser.trust_plan(codex, codex_screen({ "Trust and continue (recommended)", "Back" }, 1)), nil, "codex suffix")

-- 3. Eligibility matrix ------------------------------------------------------
local files, real = {}, {}
local env = {
  home = "/h", project_home = "/h/projects", protected = { "/h/.local/share", "/h/.local/share/remuda/butler" },
  realpath = function(path) return real[path] or (files[path] ~= nil and path) or (path:match("^/[%w/._-]*$") and path) or nil end,
  is_dir = function(path) return files[path] == "dir" end,
  read_file = function(path) return type(files[path]) == "string" and files[path] ~= "dir" and files[path] or nil end,
}
local function dir(path) files[path] = "dir" end
for _, path in ipairs({ "/", "/h", "/h/projects", "/h/projects/po-x", "/h/other", "/h/.local/share",
  "/h/.local/share/remuda/butler", "/h/.local/share/remuda/butler/sessions/fresh", "/h/projects/repo",
  "/h/wt/feature", "/h/projects/repo/.git/worktrees/feature", "/elsewhere/repo/.git/worktrees/w", "/elsewhere/wt" }) do dir(path) end
local function eligible(path) return (chooser.trust_eligible(path, env)) end
check(eligible("/h/projects/po-x"), true, "project_home child")
check(eligible("/h/other"), false, "existing non-project dir")
check(eligible("/h"), false, "HOME")
check(eligible("/"), false, "root")
check(eligible("/h/projects"), false, "project_home itself")
check(eligible("/h/.local/share"), false, "data_home itself")
check(eligible("/h/.local/share/remuda/butler"), false, "butler root itself")
check(eligible("/h/projects/missing"), false, "missing dir")
check(eligible("h/projects/po-x"), false, "relative")
check(eligible("/h/projects/po-x/"), false, "trailing slash")
check(eligible("/h/projects/../other"), false, "dot-dot")
real["/h/projects/link"] = "/h/other"; dir("/h/projects/link")
check(eligible("/h/projects/link"), false, "symlink escaping project_home")
-- A linked worktree of a repo under project_home is allowed, wherever it sits.
files["/h/wt/feature/.git"] = "gitdir: /h/projects/repo/.git/worktrees/feature\n"
files["/h/projects/repo/.git/worktrees/feature/gitdir"] = "/h/wt/feature/.git\n"
check(eligible("/h/wt/feature"), true, "worktree of a repo under project_home")
files["/h/projects/repo/.git/worktrees/feature/gitdir"] = "/h/other/.git\n"
check(eligible("/h/wt/feature"), false, "worktree whose back pointer names another dir")
files["/h/projects/repo/.git/worktrees/feature/gitdir"] = "/h/wt/feature/.git\n"
files["/elsewhere/wt/.git"] = "gitdir: /elsewhere/repo/.git/worktrees/w\n"
files["/elsewhere/repo/.git/worktrees/w/gitdir"] = "/elsewhere/wt/.git\n"
check(eligible("/elsewhere/wt"), false, "worktree of a repo outside project_home")
files["/h/wt/feature/.git"] = "gitdir: /h/projects/repo/.git\n"
check(eligible("/h/wt/feature"), false, "gitdir that is not a worktree admin dir")

-- Review findings: broad project_home, prefix, below Butler roots, .git dir.
dir("/h/projects-evil"); dir("/h/wt/dirgit"); files["/h/wt/dirgit/.git"] = "dir"
dir("/h/.local/share/remuda/butler/sessions")
check(eligible("/h/projects-evil"), false, "prefix sibling of project_home")
check(eligible("/h/.local/share/remuda/butler/sessions"), false,
  "cwd below butler roots")
check(eligible("/h/.local/share/remuda/butler/sessions/fresh"), false,
  "cwd deep below butler roots")
check(eligible("/h/wt/dirgit"), false, ".git as a directory")
local saved = env.project_home
for _, broad in ipairs({ "/h", "/" }) do
  env.project_home = broad
  check(eligible("/h/other"), false, "project_home " .. broad .. " refused")
end
env.project_home = saved

-- 4. The launch chooser answers by text, once, and only when eligible --------
local function launch(kind, labels, selected, opts)
  opts = opts or {}
  local pressed, sessions, result = {}, 0, nil
  local cwd = opts.cwd or "/p/work"
  local screen_of = kind == "claude" and claude_screen or codex_screen
  local sel = selected
  local function paint()
    if sel == "done" then return "x\n❯" end
    if opts.fixture then
      return sel == 1 and opts.fixture or opts.fixture:gsub("❯ No, exit", "  No, exit"):gsub("   Yes, I trust this folder", "❯ Yes, I trust this folder")
    end
    return screen_of(labels, sel, opts.shown or cwd)
  end
  remuda.new = function(name) return name, "inst-" .. name end
  remuda.ls = function() return { { name = "m", alive = true } } end
  remuda.capture = paint
  remuda.close = noop
  remuda.cancel = noop
  remuda.key = function(_, key)
    pressed[#pressed + 1] = key
    if opts.keyfail then return false end
    if opts.stuck then return true end
    if key == "<down>" then sel = sel + 1 elseif key == "<up>" then sel = sel - 1
    elseif key == "RET" then sel = (labels[sel] == (kind == "claude" and YES or "Trust and continue")) and "done" or sel end
    return true
  end
  local tick
  remuda.schedule = function(spec) tick = spec.run; return 1 end
  chooser.choose({ kind }, {
    name = "m", cwd = cwd, argv = { kind }, auto_trust = opts.auto_trust, trust_eligible = opts.eligible,
    trust_real_cwd = opts.real,
    spec = function() return {} end, env = function() return {} end, timeout = 60,
  }, function(name, id, attempts) sessions = sessions + 1; result = { name = name, id = id, attempts = attempts } end)
  for _ = 1, 12 do if tick and sessions == 0 then tick() end end
  return table.concat(pressed, ","), result, sessions
end
local ASK = { "No, exit", YES }
local pressed, result = launch("claude", ASK, 1, { eligible = true })
check(pressed, "<down>,RET", "claude eligible: select by text then confirm")
check(result.attempts[1].trust_answered, true, "claude answered")
pressed = launch("claude", { YES, "No, exit" }, 2, { eligible = true })
check(pressed, "<up>,RET", "claude yes first: moves up, not down")
pressed = launch("claude", { "No, exit", "Maybe", YES }, 1, { eligible = true })
check(pressed, "<down>,<down>,RET", "claude yes third")
pressed = launch("claude", ASK, 2, { eligible = true })
check(pressed, "RET", "claude already on yes: confirm only")
bus.trusted_launch_dirs = { ["/p/work"] = true } -- what launch/topic set for a directory Butler just created
pressed = launch("claude", ASK, 1, { auto_trust = true })
bus.trusted_launch_dirs = { ["/p/work"] = true }
local captured = io.open("tests/fixtures/claude-trust-dialog.txt"):read("*a")
check(launch("claude", ASK, 1, { auto_trust = true, fixture = captured }), "<down>,RET", "the exact captured Claude dialog")
bus.trusted_launch_dirs = { ["/p/work"] = true }
bus.trusted_launch_dirs = nil
check(pressed, "<down>,RET", "fresh-dir path still works (auto_trust)")
pressed, result = launch("codex", { "Trust and continue", "Back to Agent Command Center" }, 1, { eligible = true })
check(pressed, "RET", "codex confirms the selected trust option, never '1'")
pressed = launch("codex", { "Back to Agent Command Center", "Trust and continue" }, 1, { eligible = true })
check(pressed, "<down>,RET", "codex selects by text when trust is second")
for _, kind in ipairs({ "claude", "codex" }) do
  local bad = kind == "claude" and { "No, exit", "Yes, trust it" } or { "Trust", "Back" }
  pressed, result = launch(kind, bad, 1, { eligible = true })
  check(pressed, "", kind .. " no exact match: no keys")
  check(result.attempts[1].reason:match("^waiting_for_human_trust") ~= nil, true, kind .. " no match waits for a human")
  check(select(3, launch(kind, bad, 1, { eligible = true })), 1, kind .. " one hand-off (alert) per dialog")
end
pressed, result = launch("claude", ASK, 1, {})
check(pressed, "", "not eligible (other Butler / not launched here): no keys")
check(result.attempts[1].reason:match("^waiting_for_human_trust") ~= nil, true, "not eligible waits for a human")
pressed = launch("claude", ASK, 1, { eligible = true, shown = "/somewhere/else" })
check(pressed, "", "shown path differs from launch cwd: no keys")
pressed = launch("codex", { "Trust and continue", "Back" }, 1, { eligible = true, shown = "/somewhere/else" })
check(pressed, "", "codex shown path differs: no keys")
-- Shown path: realpath accepted, trailing slash normalized (accepted).
pressed = launch("claude", ASK, 1, { eligible = true, shown = "/real/work",
  real = "/real/work" })
check(pressed, "<down>,RET", "shown path equal to trust_real_cwd")
pressed = launch("claude", ASK, 1, { eligible = true, shown = "/p/work/" })
check(pressed, "<down>,RET", "trailing slash on shown path is normalized")
-- Two markers: ambiguous, nothing pressed.
local two = claude_screen(ASK, 1):gsub("   Yes, I trust", " ❯ Yes, I trust")
for _, kind in ipairs({ "claude" }) do
  check(launch(kind, ASK, 1, { eligible = true, fixture = two }), "",
    "two markers: no keys")
end
-- Stale earlier header must not supply the path.
local function with_stale(shown, old)
  return " Accessing workspace:\n\n " .. old .. "\n\n" .. claude_screen(ASK, 1, shown)
end
check(launch("claude", ASK, 1, { eligible = true,
  fixture = with_stale("/somewhere/else", "/p/work") }), "",
  "stale matching block, last block differs: no keys")
check(launch("claude", ASK, 1, { eligible = true,
  fixture = with_stale("/p/work", "/somewhere/else") }), "<down>,RET",
  "last header wins")
-- Codex: a stale earlier "Folder access" block above the window is ignored.
local cx = {}
for i = 1, 14 do cx[i] = "history " .. i end
local cx_old = "  Folder access\n  /p/work\n" .. table.concat(cx, "\n")
check(chooser.trust_path_matches(codex, cx_old .. "\n"
  .. codex_screen({ "Trust and continue", "Back" }, 1, "/other"), "/p/work"),
  false, "codex stale header: no match")
-- Move cap and key failure: no RET.
pressed = launch("claude", ASK, 1, { eligible = true, stuck = true })
check(pressed:find("RET", 1, true), nil, "stuck marker: no RET")
check(select(2, pressed:gsub("<down>", "")) <= 3, true, "moves capped at 3")
pressed = launch("claude", ASK, 1, { eligible = true, keyfail = true })
check(pressed:find("RET", 1, true), nil, "key-send failure: no RET")
for _, digit in ipairs({ "1", "2", "3" }) do
  for _, kind in ipairs({ "claude", "codex" }) do
    local keys = launch(kind, kind == "claude" and ASK or { "Back", "Trust and continue" }, 1, { eligible = true })
    check(keys:find(digit, 1, true), nil, kind .. " never presses digit " .. digit)
  end
end

if failures > 0 then print(failures .. " failure(s)"); os.exit(1) end
print("ok")
