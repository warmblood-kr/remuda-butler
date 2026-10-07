-- #372: the first-task delivery paths judge the composer with the same decision as the notice
-- policy: a dim ghost suggestion is idle (the task is typed), a real draft defers it. One
-- scenario per call site of remuda._butler_composer_decision in launch.lua: the Codex inline
-- path (pre-type gate, post-type confirm) and the shared prompt delivery used by Claude.
-- Mocks are keyed by session name so a pending delivery never reads another scenario's screen.
local function start_butler()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 5, "Butler root start")
  T.eval(string.format([[
    remuda.butler.project_home(%q)
    for _, kind in ipairs({ "codex", "claude" }) do
      remuda._butler_agent_builders[kind] = function() return { "sleep", "100" } end
      remuda._butler_agent_startup[kind] = { ready = function() return true end }
    end
    remuda._butler_notify_policy = function() return true end
    remuda._butler_task_poke_deferrals = 40
    remuda._t = { types = {}, busy = {}, screen = {}, styled = {} }
    remuda.capture = function(name) return remuda._t.screen[name] or "" end
    remuda.capture_styled = function(name) return remuda._t.styled[name] end
    remuda.session = function(name) return { is_busy = remuda._t.busy[name] == true } end
    remuda.key = function() end
    remuda.type_text = function(name)
      remuda._t.types[name] = (remuda._t.types[name] or 0) + 1
      remuda._t.busy[name] = true
    end
  ]], os.getenv("XDG_DATA_HOME") .. "/projects"))
end

-- Paint `name`'s composer: the cursor row is `prefix` then `text`, dim when it is a ghost.
local function show(name, screen, prefix, text, dim, row)
  T.eval(string.format([[remuda._t.screen[%q] = %q
    remuda._t.styled[%q] = { cursor = { row = %d }, rows = {} }
    local rows, index = remuda._t.styled[%q].rows, 0
    for line in (%q .. "\n"):gmatch("(.-)\n") do index = index + 1; rows[index] = { { text = line } } end
    rows[%d] = { { text = %q }, { text = %q, dim = %s } }]],
    name, screen, name, row, name, screen, row, prefix, text, tostring(dim)))
end

local function state(name)
  return T.eval(string.format("return tostring(remuda._butler_bus.first_task_delivery[%q].state)", name))
end

local function types(name) return T.eval(string.format("return tostring(remuda._t.types[%q] or 0)", name)) end

local function delegate(name, kind)
  T.eval(string.format("remuda._butler_topic_delegate(%q, 'do the thing', nil, %q, 'butler')", name, kind))
end

local function wait_ticks(seconds)
  local at = os.time() + seconds
  T.wait_until(function() return os.time() >= at end, seconds + 3, "settle")
end

-- A real draft is not a ghost: nothing is typed over it.
local function draft_defers(kind, screen, prefix, row)
  local name = "t-draft-" .. kind
  show(name, screen, prefix, "real draft", false, row)
  delegate(name, kind)
  T.wait_until(function() return state(name) ~= "nil" end, 5, "delivery record")
  wait_ticks(3) -- several 0.5s poke ticks
  T.eq(types(name), "0", kind .. ": the task was typed over a real draft")
  T.eq(state(name), "waiting", kind .. ": a draft must defer, not finish")
end

-- A dim ghost is idle: the task is typed, and counts as delivered once the agent turns busy.
local function ghost_delivers(kind, screen, prefix, row)
  local name = "t-ghost-" .. kind
  local ghost = kind == "claude" and 'Try "ghost suggestion"' or "ghost suggestion"
  show(name, screen, prefix, ghost, true, row)
  delegate(name, kind)
  T.wait_until(function() return types(name) == "1" end, 8, kind .. ": task typed over a dim ghost")
  T.wait_until(function() return state(name) == "delivered" end, 8,
    kind .. ": delivery confirmed past a dim ghost")
end

T.test("first-task delivery treats a dim ghost as idle and a draft as busy", function()
  start_butler()
  draft_defers("codex", "› real draft", "› ", 1)
  ghost_delivers("codex", "› ghost suggestion", "› ", 1)
  local claude = "────\n❯ %s\n────\n  ⏵⏵ auto mode on"
  draft_defers("claude", claude:format("real draft"), "❯ ", 2)
  ghost_delivers("claude", claude:format('Try "ghost suggestion"'), "❯ ", 2)
end)
