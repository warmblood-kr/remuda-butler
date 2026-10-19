-- A real Claude composer paints a multi-word ghost word by word: the spaces between words are NOT
-- dim. The first task must still treat it as the empty prompt it is (live app-appendix: the task
-- sat deferred ~4 min because the ghost "Try \"how does ...\"" compared unequal to the raw text).
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
local function show_words(name, screen, row)
  T.eval(string.format([[remuda._t.screen[%q] = %q
    remuda._t.styled[%q] = { cursor = { row = %d }, rows = {} }
    local spans = { { text = "❯ " } }
    for i, word in ipairs({ 'Try', '"how', 'does', 'harness.lua', 'work?"' }) do
      if i > 1 then spans[#spans + 1] = { text = " " } end
      spans[#spans + 1] = { text = word, dim = true }
    end
    remuda._t.styled[%q].rows[%d] = spans]], name, screen, name, row, name, row))
end

local function types(name) return T.eval(string.format("return tostring(remuda._t.types[%q] or 0)", name)) end

T.test("first task is typed over a multi-word ghost whose spaces are undimmed", function()
  start_butler()
  local name = "t-words-claude"
  show_words(name, '────\n❯ Try "how does harness.lua work?"\n────\n  ⏵⏵ auto mode on', 2)
  T.eval(string.format("remuda._butler_topic_delegate(%q, 'do the thing', nil, 'claude', 'butler')", name))
  T.wait_until(function() return types(name) == "1" end, 8, "task typed over a multi-word ghost")
end)
