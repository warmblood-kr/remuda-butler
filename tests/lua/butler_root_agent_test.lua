-- Fresh root --agent is a strict singleton; an omitted flag, an existing root
-- and the default/env order keep configured_agent_order unchanged. This uses
-- the real main chooser, with spawn/process stubbed so it launches nothing.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval([==[
remuda._butler_skip_relay = true
remuda._mod_launch_options = { butler = { agent = "codex" } }
remuda.new = function() error("unexpected spawn") end
remuda.process.run = function() error("unexpected process") end
local real_exec = remuda.exec
remuda.exec = function(name, ...)
  local result = real_exec(name, ...)
  if name == "butler/agents_launch" then
    remuda._butler_chooser.choose = function(order, opts, done)
      remuda._qa_order = table.concat(order, ",")
      return {}
    end
  end
  return result
end
]==])
T.eval('return remuda.exec("butler")')

T.test("fresh explicit codex captures actual main chooser order", function()
  T.wait_until(function()
    return T.eval('return tostring(remuda._qa_order ~= nil)') == "true"
  end, 5, "chooser capture")
  local result = T.eval(
    'return "requested=codex|record=" .. tostring(remuda._butler_bus.agents.butler.kind)'
      .. ' .. "|order=" .. remuda._qa_order')
  T.eq(result, "requested=codex|record=codex|order=codex",
    "explicit CLI must be a strict singleton")
end)

-- Helper-level branches: the real-main capture above proves the explicit
-- fresh-root path. Actual adoption is not exercised here; the existing-root
-- branch is the same `fresh=false` decision plus main's early adoption return.
T.test("root_start_order keeps no-arg/existing decisions on configured order", function()
  local configured = T.eval('return table.concat(remuda._butler_configured_agent_order(), ",")')
  T.ok(configured ~= "", "configured order is available")
  T.eq(T.eval('return table.concat(remuda._butler_root_start_order(true, nil), ",")'),
    configured, "a no-arg fresh root keeps configured order")
  T.eq(T.eval('return table.concat(remuda._butler_root_start_order(false, "codex"), ",")'),
    configured, "the fresh=false decision keeps configured order")
  T.eq(T.eval('return table.concat(remuda._butler_root_start_order(true, "frobnicate"), ",")'),
    "frobnicate", "an explicit unknown kind stays strict, no fallback")
end)
