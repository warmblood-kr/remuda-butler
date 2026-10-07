-- ConPTY may join Claude's full-width composer border and prompt glyph on one
-- captured row, while leaving the first captured row blank.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1')
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
    :match("^%s*true%s*$") ~= nil
end, 5, "Butler root start")

T.test("Claude accepts a border and prompt joined by ConPTY", function()
  local fixture = "\n────❯ "
  T.eq(T.eval(string.format("return tostring(remuda._butler_agent_startup.claude.ready(%q))", fixture)),
    "true", "startup matcher should recognize the wrapped composer")
  T.eq(T.eval(string.format("local decision = remuda._butler_prompt_is_empty('claude', %q); return decision", fixture)),
    "EMPTY", "empty-composer matcher should recognize the wrapped composer")

  T.eval(string.format([[
    remuda._butler_agent_builders.claude = function() return { "sh", "-c", "sleep 60" } end
    remuda._butler_test_force_launch_probe = { ["conpty-wrapped"] = true }
    remuda.capture = function(name) if name == "conpty-wrapped" then return %q end return "" end
    remuda._conpty_result = nil
    remuda._butler_choose_async({ "claude" }, {
      name = "conpty-wrapped", cwd = os.getenv("XDG_DATA_HOME"), timeout = 2,
      spec = function() return {} end, env = function() return {} end,
    }, function(session, agent, attempts)
      remuda._conpty_result = { session = session, agent = agent, reason = attempts[1].reason }
    end)
  ]], fixture))
  T.wait_until(function()
    return T.eval("return tostring(remuda._conpty_result ~= nil)") == "true"
  end, 5, "wrapped composer readiness")
  T.eq(T.eval("return remuda._conpty_result.reason"), "ready",
    "a wrapped composer should deliver the first task through the normal ready path")
  T.eval('return remuda.close("conpty-wrapped")')
end)

T.test("a blank first row does not make a visible screen blank", function()
  T.eval([[
    remuda._butler_agent_builders.visible_probe = function() return { "sh", "-c", "sleep 60" } end
    remuda._butler_test_force_launch_probe["conpty-visible"] = true
    remuda.capture = function(name)
      if name == "conpty-visible" then return "\nClaude is still starting" end
      return ""
    end
    remuda._conpty_visible_result = nil
    remuda._butler_choose_async({ "visible_probe" }, {
      name = "conpty-visible", cwd = os.getenv("XDG_DATA_HOME"), timeout = 1,
      spec = function() return {} end, env = function() return {} end,
    }, function(session, agent, attempts)
      remuda._conpty_visible_result = { session = session, reason = attempts[1].reason }
    end)
  ]])
  T.wait_until(function()
    return T.eval("return tostring(remuda._conpty_visible_result ~= nil)") == "true"
  end, 5, "visible screen timeout")
  T.eq(T.eval("return remuda._conpty_visible_result.reason"), "timeout",
    "visible content after a blank first row must not be classified as blank")
end)
