T.test("changed CLI source defers refresh without closing an in-flight launch", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1; remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus and remuda._butler_bus.agents.butler ~= nil') == "true"
  end, 5, "root start")
  T.eval([[
    remuda._butler_agent_builders.claude = function() return {"sh", "-c", "sleep 60"} end
    remuda._butler_test_force_launch_probe = { ["refresh-launch"] = true }
    remuda.capture = function() return "" end
    remuda._refresh_launch_done = false
    remuda._butler_choose_async({"claude"}, {
      name = "refresh-launch", cwd = os.getenv("XDG_DATA_HOME"), timeout = 60,
      spec = function() return {} end, env = function() return {} end,
    }, function() remuda._refresh_launch_done = true end)
  ]])
  T.wait_until(function()
    return T.eval('for _, row in ipairs(remuda.ls()) do if row.name == "refresh-launch" and row.alive then return true end end return false') == "true"
  end, 5, "not-ready launch")
  local result = T.eval([[
    local path = os.getenv("XDG_DATA_HOME") .. "/remuda/mods/butler/packages/butler/commands.lua"
    local file = assert(io.open(path, "a")); file:write("\n-- edited source\n"); file:close()
    local ok, err = pcall(remuda._load_extension_command, "butler", "butler", true)
    local live = false
    for _, row in ipairs(remuda.ls()) do if row.name == "refresh-launch" and row.alive then live = true end end
    return tostring(ok) .. "|" .. tostring(live) .. "|" .. tostring(remuda._refresh_launch_done) .. "|" .. tostring(err)
  ]])
  T.expect(result:find("false|true|false|", 1, true), result)
  T.expect(result:find("source refresh deferred: a launch chooser is active", 1, true), result)
  local normal = T.eval('remuda._load_extension_command("butler", "butler"); return remuda._dispatch_extension_command("butler", {"doctor", "--help"}, {})')
  T.expect(normal:find("Usage: remuda butler doctor", 1, true), normal)
end)
