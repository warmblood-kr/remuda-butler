-- #383: a fresh TUI can leave the terminal cursor on its footer while the
-- composer itself is already empty. Use the full parsed pane as evidence.
T.test("fresh Claude empty composer delivers while cursor is on the footer", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil') == "true"
  end, 5, "Butler root ready")
  T.eq(T.eval([[
    remuda._butler_bus.agents.fresh = { kind = "claude" }
    local screen = "Claude Code startup banner\n────\n❯ \n────\n  ⏵⏵ auto mode on"
    local idle = math.huge
    remuda.ls = function() return {{ name = "fresh", alive = true, attached = true, human_idle = idle }} end
    remuda.capture = function() return screen end
    remuda.capture_styled = function()
      local rows = {}
      for line in (screen .. "\n"):gmatch("(.-)\n") do rows[#rows + 1] = {{ text = line }} end
      return { cursor = { row = #rows }, rows = rows }
    end
    assert(remuda._butler_composer_decision("claude", "fresh", screen) == "EMPTY")
    assert(remuda._butler_notify_policy("fresh"), "empty fresh composer deferred by footer cursor")
    idle = 0
    assert(not remuda._butler_notify_policy("fresh"), "active human ignored")
    idle = math.huge
    screen = "────\n❯ \nhuman continuation\n────\n  ⏵⏵ auto mode on"
    assert(not remuda._butler_notify_policy("fresh"), "human continuation treated as empty")
    screen = "Teach auto mode about your environment?\n────\n❯ \n────"
    assert(not remuda._butler_notify_policy("fresh"), "Teach modal typing guard bypassed")
    screen = "unknown startup screen"
    assert(not remuda._butler_notify_policy("fresh"), "unknown screen treated as empty")
    return "ok"
  ]]), "ok")
end)
