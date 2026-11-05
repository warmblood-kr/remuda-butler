T.test("commands-only rollback retains help without starting the service", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  local result = T.eval([[
    remuda._load_extension_command("butler", "butler")
    local handler = remuda._extension_commands.butler
    local path = os.getenv("XDG_DATA_HOME") .. "/remuda/mods/butler/packages/butler/commands.lua"
    local file = assert(io.open(path, "r")); local source = file:read("*a"); file:close()
    for attempt = 1, 2 do
      file = assert(io.open(path, "w")); file:write("error('commands-only broken helper')"); file:close()
      local ok, err = pcall(remuda._load_extension_command, "butler", "butler", true)
      assert(not ok and tostring(err):find("commands-only broken helper", 1, true))
      assert(remuda._extension_commands.butler == handler)
      assert(remuda._dispatch_extension_command("butler", {"doctor", "--help"}, {}):find("Usage:", 1, true))
      for _, row in ipairs(remuda.ls()) do assert(row.name ~= "butler", "commands-only refresh must not boot") end
    end
    file = assert(io.open(path, "w")); file:write((source:gsub("Check the Butler installation%.", "Inspect the Butler installation."))); file:close()
    remuda._load_extension_command("butler", "butler", true)
    assert(remuda._dispatch_extension_command("butler", {"doctor", "--help"}, {}):find("Inspect the Butler installation.", 1, true))
    for _, row in ipairs(remuda.ls()) do assert(row.name ~= "butler", "corrected commands-only retry must not boot") end
    return "preserved"
  ]])
  T.eq(result, "preserved")
end)

T.test("both sides of the resume capability boundary refuse before replacement", function()
  local result = T.eval([[
    local path = os.getenv("XDG_DATA_HOME") .. "/remuda/mods/butler/packages/butler/init.lua"
    local file = assert(io.open(path, "r")); local source = file:read("*a"); file:close()
    local first = assert(source:find("  resume = function(state)", 1, true))
    local last = assert(source:find("  stop = function(state)", first, true))
    file = assert(io.open(path, "w")); file:write(source:sub(1, first - 1) .. source:sub(last)); file:close()
    -- Explicit reload is the documented upgrade boundary; use commands-only
    -- activation directly so this fixture never starts a live service session.
    remuda._exec_commands("butler", true)
    file = assert(io.open(path, "w")); file:write(source); file:close()
    local handler = remuda._extension_commands.butler
    local ok, err = pcall(remuda._load_extension_command, "butler", "butler", true)
    assert(not ok and tostring(err):find("active mod lacks resume", 1, true), tostring(err))
    assert(remuda._extension_commands.butler == handler)
    remuda._butler_argv = {"sh", "-c", "sleep 60"}
    remuda._butler_skip_relay = true
    remuda._butler_readiness_timeout = 1
    remuda.reload("butler")
    -- An old core has no advertised resume capability. The new Butler must
    -- refuse its refresh even though that core accepts source_refresh_ready.
    remuda._module_resume_supported = nil
    file = assert(io.open(path, "a")); file:write("\n-- another edit\n"); file:close()
    handler = remuda._extension_commands.butler
    ok, err = pcall(remuda._load_extension_command, "butler", "butler", true)
    remuda._module_resume_supported = true
    assert(not ok and tostring(err):find("core lacks lifecycle resume", 1, true), tostring(err))
    assert(remuda._extension_commands.butler == handler)
    assert(remuda._dispatch_extension_command("butler", {"doctor", "--help"}, {}):find("Usage:", 1, true))
    return "deferred"
  ]])
  T.eq(result, "deferred")
end)

T.test("source refresh waits for native publication work", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1; remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil') == "true"
  end, 5, "root start")
  local result = T.eval([[
    local path = os.getenv("XDG_DATA_HOME") .. "/remuda/mods/butler/packages/butler/commands.lua"
    local file = assert(io.open(path, "a")); file:write("\n-- native refresh guard edit\n"); file:close()
    local function attempt()
      local ok, err = pcall(remuda._load_extension_command, "butler", "butler", true)
      return tostring(ok) .. "|" .. tostring(err)
    end
    remuda._butler_bus.notice_native_watchers = { lead = {} }
    local watcher = attempt()
    remuda._butler_bus.notice_native_watchers = nil
    remuda._butler_bus.notice_native_dispatching = { lead = true }
    local dispatching = attempt()
    remuda._butler_bus.notice_native_dispatching = nil
    return watcher .. "\n" .. dispatching
  ]])
  T.expect(result:find("false|", 1, true) ~= nil and
    result:find("native publication is waiting", 1, true) ~= nil, result)
  T.expect(result:find("native delivery is in flight", 1, true) ~= nil, result)
end)
