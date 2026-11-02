T.test("healthy observed sessions permit source refresh without replacing the session", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1; remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus and remuda._butler_bus.agents.butler ~= nil') == "true"
  end, 5, "root start")
  local result = T.eval([[
    local before
    for _, row in ipairs(remuda.ls()) do if row.name == "butler" then before = row.instance_id end end
    remuda.capture = function() return "Claude Code\n────────────────────\n❯ " end
    remuda.butler.dialogs.tick()
    local state = assert(remuda._butler_bus.dialog_states.butler)
    assert(not state.blocked and not state.id, "test session must be healthy")
    local path = os.getenv("XDG_DATA_HOME") .. "/remuda/mods/butler/packages/butler/commands.lua"
    local file = assert(io.open(path, "r")); local source = file:read("*a"); file:close()
    source = source:gsub("Check the Butler installation%.", "Inspect the Butler installation.")
    file = assert(io.open(path, "w")); file:write(source); file:close()
    remuda._load_extension_command("butler", "butler", true)
    local after
    for _, row in ipairs(remuda.ls()) do if row.name == "butler" and row.alive then after = row.instance_id end end
    local help = remuda._dispatch_extension_command("butler", {"doctor", "--help"}, {})
    assert(before ~= nil and after == before, "source refresh must retain the live root instance")
    assert(help:find("Inspect the Butler installation.", 1, true), "fresh command code was not applied")
    return "refreshed"
  ]])
  T.eq(result, "refreshed")
end)
