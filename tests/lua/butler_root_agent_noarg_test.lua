-- No root --agent keeps the configured order through the real main chooser.
-- Spawn/process are stubbed so this proves selection, not a launch.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval([==[
remuda._butler_skip_relay = true
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

T.test("no-arg fresh root captures the configured chooser order", function()
  T.wait_until(function()
    return T.eval('return tostring(remuda._qa_order ~= nil)') == "true"
  end, 5, "chooser capture")
  local order = T.eval('return remuda._qa_order')
  local configured = T.eval('return table.concat(remuda._butler_configured_agent_order(), ",")')
  T.ok(configured ~= "", "configured order is available")
  T.eq(order, configured, "no --agent must keep configured order")
end)
