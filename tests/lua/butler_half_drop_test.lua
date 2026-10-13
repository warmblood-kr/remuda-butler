-- The half-drop heuristic: nil -> value is not a drop; one re-show notice per
-- drop, re-armed only after the context rises again.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
    :match("^%s*true%s*$") ~= nil
end, 5, "Butler root start")

T.eval(string.format([[
  remuda.butler.project_home(%q)
  remuda._butler_agent_builders.codex = function() return { "sleep", "100" } end
  remuda._butler_launch("codex", "cx1")
  remuda._butler_inbox("cx1")
]], os.getenv("XDG_DATA_HOME") .. "/projects"))

-- Fake clock, context size and pane: the notices are typed into a recorder.
T.eval([[
  local state = { now = 0, busy = {}, typed = {}, ctx = {} }
  remuda._notice_test_state = state
  remuda._butler_notice_clock = function() return state.now end
  remuda.ls = function() return {
    { name = 'cx1', alive = true, attached = false },
    { name = 'butler', alive = true, attached = false },
  } end
  remuda.session = function(name) return { is_busy = state.busy[name] == true } end
  remuda.capture_styled = nil
  remuda._butler_notify_policy = function(name) return state.busy[name] ~= true end
  remuda._butler_telemetry_for = function(agent)
    return { context_used = state.ctx[agent and agent.alias or ''] }
  end
  remuda.capture = function() return state.screen or '> ' end
  remuda.type_text = function(_, text)
    state.typed[#state.typed + 1] = { at = state.now, text = text }
    state.screen = text .. '\n> '
    return true
  end
  remuda._rn_tick = function(now) state.now = now; remuda._butler_deliver_notices() end
]])

T.test("half_drop_heuristic_guards_and_rearms_after_a_rise", function()
  local id = T.eval([[
    local state = remuda._notice_test_state
    local id = remuda._butler_send('butler', 'cx1', 'guard task'):match('^queued (%S+)')
    remuda._rn_tick(0); remuda._rn_tick(2)
    remuda._butler_inbox('cx1')
    state.ctx.cx1 = nil
    remuda._rn_tick(3)
    state.ctx.cx1 = 60000
    for t = 4, 9 do remuda._rn_tick(t) end
    return id
  ]]):match("%S+")
  local function typed() return tonumber(T.eval("return #remuda._notice_test_state.typed")) end
  local function text(n)
    return T.eval("return tostring(remuda._notice_test_state.typed[" .. n .. "].text)")
  end
  T.eq(typed(), 1, "nil -> value must not count as a drop: only the arrival notice")

  T.eval([[
    local state = remuda._notice_test_state
    state.ctx.cx1 = 170000
    remuda._rn_tick(10)
    state.ctx.cx1 = 60000
    for t = 11, 20 do remuda._rn_tick(t) end
  ]])
  T.eq(typed(), 2, "a real drop re-shows the leader message once")
  T.ok(text(2):find("re-shown after compaction", 1, true), "drop notice is the re-show: " .. text(2))
  T.ok(text(2):find(id, 1, true), "re-show names the leader message")

  T.eval([[
    remuda._notice_test_state.ctx.cx1 = 25000
    for t = 21, 30 do remuda._rn_tick(t) end
  ]])
  T.eq(typed(), 2, "a further fall without a rise stays quiet")

  T.eval([[
    local state = remuda._notice_test_state
    state.ctx.cx1 = 180000
    remuda._rn_tick(31)
    state.ctx.cx1 = 50000
    for t = 32, 40 do remuda._rn_tick(t) end
  ]])
  T.eq(typed(), 3, "a rise re-arms: the next drop notices once more")
  T.ok(text(3):find("re-shown after compaction", 1, true), "re-armed notice is a re-show: " .. text(3))
end)
