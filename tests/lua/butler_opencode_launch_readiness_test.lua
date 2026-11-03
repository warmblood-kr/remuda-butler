-- Use an isolated harness Butler and a harmless process, never a real agent.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil'):match("true") ~= nil
end, 5, "isolated Butler startup")

local function probe(name, screen, expected)
  T.eval(string.format([[
    remuda._butler_agent_builders.opencode = function() return { "sh", "-c", "sleep 60" } end
    remuda._butler_test_force_launch_probe = remuda._butler_test_force_launch_probe or {}
    remuda._butler_test_force_launch_probe[%q] = true
    remuda.capture = function() return %q end
    remuda._qa_probe = nil
    remuda._butler_choose_async({ "opencode" }, {
      name = %q, cwd = os.getenv("XDG_DATA_HOME"), timeout = 1,
      spec = function() return {} end, env = function() return {} end,
    }, function(session, agent, attempts)
      remuda._qa_probe = { session = session, reason = attempts[1].reason }
    end)
  ]], name, screen, name))
  T.wait_until(function() return T.eval('return remuda._qa_probe ~= nil') == "true" end, 6, name)
  T.eq(T.eval('return remuda._qa_probe.reason'), expected, name .. " readiness decision")
  if expected == "ready" then
    T.eq(T.eval('return remuda._qa_probe.session'), name)
    T.eval(string.format('return remuda.close(%q)', name))
  else
    T.eq(T.eval('return tostring(remuda._qa_probe.session)'), "nil")
  end
end

T.test("OpenCode generic prompt glyphs cannot bypass its readiness parser", function()
  probe("qa-opencode-glyph", "initializing\n❯", "timeout")
  probe("qa-opencode-typed-glyph", "┃ >", "timeout")
  probe("qa-opencode-draft", "┃ Ask anything…\n┃ actual draft", "timeout")
end)

T.test("OpenCode captured suggestion reaches chooser readiness", function()
  probe("qa-opencode-ready", '┃ Ask anything… "Fix broken tests"', "ready")
end)
