T.test("failed helper refresh preserves old commands, session, registrations and audited input", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval([[
    remuda._butler_argv = {"sh", "-c", "sleep 60"}
    remuda._butler_skip_relay = true
    remuda._butler_readiness_timeout = 1
    remuda._rollback_writes = 0
    remuda.key = function() remuda._rollback_writes = remuda._rollback_writes + 1; return true end
    remuda.exec("butler")
  ]])
  T.wait_until(function()
    return T.eval('return remuda._butler_bus and remuda._butler_bus.agents.butler ~= nil') == "true"
  end, 5, "root start")
  local result = T.eval([[
    local path = os.getenv("XDG_DATA_HOME") .. "/remuda/mods/butler/packages/butler/commands.lua"
    local file = assert(io.open(path, "r")); local source = file:read("*a"); file:close()
    local function instance()
      for _, row in ipairs(remuda.ls()) do if row.name == "butler" and row.alive then return row.instance_id end end
    end
    local function registrations()
      local hooks, schedules = 0, 0
      for _, rows in pairs(remuda.hooks) do
        for _, hook in ipairs(rows) do
          if hook.owner == "butler" or hook.group == "remuda-module:butler" then hooks = hooks + 1 end
        end
      end
      for _, schedule in pairs(remuda.schedules) do if schedule.owner == "butler" and schedule.name ~= "butler-start-fallback" then schedules = schedules + 1 end end
      return hooks .. ":" .. schedules
    end
    local dialogs_path = path:gsub("commands.lua$", "dialogs.lua")
    file = assert(io.open(dialogs_path, "r")); local dialogs_source = file:read("*a"); file:close()
    local before, registered, handler = assert(instance()), registrations(), remuda._extension_commands.butler
    -- The fallback timer exists only to boot older cores without lifecycle
    -- start. This core has already booted; it must not be recreated on rollback.
    for _, failure in ipairs({
      {path, "this is invalid Lua"},
      {path, source .. "\nerror('failed after commands registered')"},
      {dialogs_path, "this is invalid Lua"},
      {dialogs_path, (dialogs_source:gsub("return M%s*$", "error('failed after dialogs created')\nreturn M"))},
    }) do
      file = assert(io.open(failure[1], "w")); file:write(failure[2]); file:close()
      local ok, err = pcall(remuda._load_extension_command, "butler", "butler", true)
      assert(not ok and tostring(err):find(".lua", 1, true), "helper must fail visibly: " .. tostring(err))
      assert(instance() == before, "failed refresh must preserve root instance")
      assert(remuda._extension_commands.butler == handler, "last working handler must be restored")
      assert(registrations() == registered, "rollback registrations " .. registered .. " -> " .. registrations())
      assert(remuda._dispatch_extension_command("butler", {"doctor", "--help"}, {}):find("Usage:", 1, true))
      remuda._butler_bus.agents.butler.kind = "claude"
      remuda.capture = function() return "Claude Code\n─\n❯ " end
      local audits = 0
      remuda.butler.guard_policy.append = function() audits = audits + 1; return true end
      local written = remuda._rollback_writes
      remuda.key("butler", "RET")
      assert(remuda._rollback_writes == written + 1, "synthetic input still works")
      assert(audits >= 2, "input retains before/after audits after failed refresh")
      file = assert(io.open(path, "w")); file:write(source); file:close()
      file = assert(io.open(dialogs_path, "w")); file:write(dialogs_source); file:close()
    end
    file = assert(io.open(path, "w")); file:write((source:gsub("Check the Butler installation%.", "Inspect the Butler installation."))); file:close()
    remuda._load_extension_command("butler", "butler", true)
    assert(remuda._dispatch_extension_command("butler", {"doctor", "--help"}, {}):find("Inspect the Butler installation.", 1, true))
    assert(instance() == before, "corrected retry preserves the live root")
    return "preserved"
  ]])
  T.eq(result, "preserved")
end)

T.test("failed input-gate resume refuses writes and a corrected activation recovers", function()
  local result = T.eval([[
    local before
    for _, row in ipairs(remuda.ls()) do if row.name == "butler" and row.alive then before = row.instance_id end end
    local path = os.getenv("XDG_DATA_HOME") .. "/remuda/mods/butler/packages/butler/commands.lua"
    local file = assert(io.open(path, "r")); local source = file:read("*a"); file:close()
    remuda.butler.dialogs.install = function() error("synthetic gate recovery failure") end
    file = assert(io.open(path, "w")); file:write("this is invalid Lua"); file:close()
    local ok, err = pcall(remuda._load_extension_command, "butler", "butler", true)
    assert(not ok and tostring(err):find("commands.lua", 1, true), "original helper error must remain visible")
    local written = remuda._rollback_writes
    for _, method in ipairs({"key", "type_text", "send"}) do
      if remuda[method] then
        local allowed, why = pcall(remuda[method], "butler", "RET")
        assert(not allowed and tostring(why):find("input gate recovery failed", 1, true), "failed resume must refuse " .. method)
      end
    end
    assert(remuda._rollback_writes == written, "failed resume must not reach raw input")
    assert(remuda._extension_commands.butler == nil, "failed resume leaves the module inactive")
    file = assert(io.open(path, "w")); file:write(source); file:close()
    remuda._load_extension_command("butler", "butler", true)
    assert(remuda._dispatch_extension_command("butler", {"doctor", "--help"}, {}):find("Usage:", 1, true))
    local after
    for _, row in ipairs(remuda.ls()) do if row.name == "butler" and row.alive then after = row.instance_id end end
    assert(after == before, "recovery preserves the existing root session")
    return "refused then recovered"
  ]])
  T.eq(result, "refused then recovered")
end)
