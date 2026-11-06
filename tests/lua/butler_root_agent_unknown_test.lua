-- An explicit unsupported root kind is a strict singleton, so the existing
-- chooser reports a visible launch failure and never falls back to another
-- agent. Spawn/process are stubbed: this proves the failure path, not a launch.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval([==[
remuda._butler_skip_relay = true
remuda._mod_launch_options = { butler = { agent = "frobnicate" } }
remuda.new = function() error("unexpected spawn") end
remuda.process.run = function() error("unexpected process") end
]==])
T.eval('return remuda.exec("butler")')

T.test("explicit unknown root kind fails visibly and never spawns", function()
  local result = T.eval('return tostring(remuda._butler_start_error or "")')
  T.expect(result:find("frobnicate", 1, true) ~= nil,
    "the failure names the requested kind: " .. result)
  T.expect(result:find("not installed", 1, true) ~= nil
    or result:find("not_found", 1, true) ~= nil
    or result:find("not registered", 1, true) ~= nil,
    "the failure is the existing not-found classification: " .. result)
  T.eq(T.eval('return tostring(remuda._butler_selected_agent)'), "nil",
    "no fallback agent was selected")
  T.eq(T.eval('return tostring(remuda._butler_bus.agents.butler ~= nil)'), "true",
    "the root record still exists for the visible failure")
end)
